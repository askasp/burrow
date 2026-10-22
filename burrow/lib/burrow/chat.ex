defmodule Burrow.Chat do
  @moduledoc """
  The process behind one chat. It owns, on a private Docker network:

    * the workspace: a checkout of main the agent edits (`Burrow.Workspace`)
    * the preview container: the app in dev mode on the workspace, reachable by
      the agent as http://preview:4000 and by the user on a local port
    * the agent container: `opencode serve` on the workspace, with the
      owner's opencode login, Peon's instructions and Peon's MCP tools
      (`Burrow.Agent.Tools`)

  The conversation lives in the chat's opencode session. While the agent
  works, this process polls the session and broadcasts on the project's
  topic `"chat:<id>"`:

    * `{:messages, messages}` - the whole conversation, normalized
    * `{:status, status}` - see `info/1`

  Containers stop after `@idle_timeout` without activity, unless the chat is
  kept running (`Burrow.Chats.keep_running/2`) or its change is on main and
  not live yet (`Burrow.Activity.unshipped?/2`: its preview stays to look
  into); the next use starts them again. At most `:max_running_chats` chats of a project run at once (see
  `make_room/2`). A chat that stops broadcasts `{:stopped, reason}`:
  `:idle`, `:room`, `:deleted` or `:exited`.

  In a repo project (`Burrow.GitRepo`) the workspace is a git checkout
  instead, and the preview is the repo's preview pack run on the host
  (`Burrow.GitRepo.HostPreview`), up once its framed port answers.
  """

  use GenServer, restart: :temporary

  require Logger

  alias Burrow.{BuildCache, Chats, GitRepo, Incidents, Projects, Sandbox, Secrets, Workspace}
  alias Burrow.Agent.{MCP, Prompt}
  alias Burrow.GitRepo.{HostPreview, PreviewPack}
  alias Burrow.OpenCode.Client

  @registry Burrow.ChatRegistry
  @idle_timeout :timer.minutes(30)
  @boot_timeout :timer.seconds(90)
  @poll_interval 1_500
  @log_lines 400
  @probe_interval 2_000
  # How long a detached preview (its start command exited 0) gets to answer.
  @detached_timeout :timer.minutes(5)

  ## API

  @doc "Starts the chat's containers if needed and waits until the agent is ready."
  def ensure_started(project, id) do
    unless whereis(id), do: make_room(project, id)

    case DynamicSupervisor.start_child(Burrow.ChatSupervisor, {__MODULE__, {project, id}}) do
      {:ok, pid} ->
        GenServer.call(pid, :await_ready, @boot_timeout + 5_000)

      {:error, {:already_started, pid}} ->
        GenServer.call(pid, :await_ready, @boot_timeout + 5_000)

      # e.g. :no_free_preview_port when every preview port is in use
      {:error, reason} ->
        {:error, reason}
    end
  end

  def send_message(project, id, text) do
    with {:ok, _info} <- ensure_started(project, id), do: call(id, {:prompt, text})
  end

  @doc """
  `%{preview_url, preview_status, agent_status, busy?, attach, messages}`;
  `agent_status` is `:starting`, `:ready` or `{:error, reason}`.
  """
  def info(id), do: call(id, :info)

  def interrupt(id), do: call(id, :interrupt)

  @doc """
  What a message can start with: `/name` for one of opencode's commands or
  skills, its own or the workspace's. `[%{name, description, kind}]`, kind
  `:command` or `:skill`.
  """
  def slash_commands(id), do: call(id, :slash_commands)

  def restart_preview(id), do: call(id, :restart_preview)

  @doc "A repo chat's preview pack and its commands' environment: `{:ok, pack, env}`."
  def preview_pack(id), do: call(id, :preview_pack)

  @doc "Records a repo chat's pull request and shows it."
  def pr_opened(id, url), do: call(id, {:pr_opened, url})

  def logs(id), do: call(id, :logs)

  def subscribe(project_id, id), do: Projects.subscribe(project_id, "chat:#{id}")

  def unsubscribe(project_id, id), do: Projects.unsubscribe(project_id, "chat:#{id}")

  def workspace_dir(project, id), do: Path.join(base_dir(project, id), "workspace")

  @doc "The agent's container, where the chat's checks run (`Burrow.Ship`)."
  def agent_name(project, id), do: "peon-agent-#{project.slug}-#{id}"

  defp base_dir(project, id), do: Path.join([Projects.dir(project), "chats", id])

  @doc """
  Deletes a chat: its opencode session (when it runs), its containers, its
  files, its draft and its row. A repo chat's pull request stays open.
  """
  def delete(project, chat) do
    Chats.delete(chat)
    Incidents.chat_deleted(project.id, chat.id)

    if pid = whereis(chat.id) do
      ref = Process.monitor(pid)

      try do
        GenServer.call(pid, :delete, 30_000)
      catch
        :exit, _ -> :ok
      end

      # A repo preview's stop command (e.g. `docker compose down`) can take a while.
      receive do
        {:DOWN, ^ref, :process, _, _} -> :ok
      after
        :timer.minutes(3) -> :ok
      end
    end

    if repo = !Projects.Project.repo?(project) && Projects.repo_dir(project),
      do: Totem.Repo.delete_draft(repo, chat.id)

    File.rm_rf(base_dir(project, chat.id))
    :ok
  end

  @doc "Stops every chat of the project, e.g. when its owner changed."
  def stop_all(project_id) do
    for {_id, pid} <- running(project_id), do: GenServer.stop(pid, :normal, :timer.minutes(3))
    :ok
  end

  @doc "Starts the chats kept running, e.g. after Burrow restarted."
  def start_kept_running(project) do
    for chat <- Chats.list_kept_running(project.id),
        do:
          Task.Supervisor.start_child(Burrow.TaskSupervisor, fn ->
            ensure_started(project, chat.id)
          end)

    :ok
  end

  @doc """
  Runs the stop command (e.g. `docker compose down`) of every repo preview a
  previous run of Burrow left behind; its containers outlive Burrow.
  """
  def stop_left_behind(project) do
    case File.ls(Path.join(Projects.dir(project), "chats")) do
      {:ok, ids} ->
        ids
        |> Task.async_stream(&stop_left_behind(project, &1),
          timeout: :infinity,
          max_concurrency: 4
        )
        |> Stream.run()

      {:error, _} ->
        :ok
    end
  end

  defp stop_left_behind(project, id) do
    dir = workspace_dir(project, id)

    with {:ok, %PreviewPack{stop: stop} = pack} when is_binary(stop) <- PreviewPack.load(dir) do
      ports = Map.new(pack.ports ++ pack.local_ports, &{&1, 0})
      name = "peon-preview-#{project.slug}-#{id}"

      env =
        Map.merge(
          Secrets.env(project.id),
          PreviewPack.env(pack, ports, &Burrow.Ports.url/1, name)
        )

      HostPreview.run(dir, stop, env, :timer.minutes(2))
    end
  end

  # At most `:max_running_chats` chats of a project run at once: starting
  # another stops the one used longest ago. Busy chats and chats kept running
  # are never stopped for room, so with only those running the cap is
  # exceeded rather than refusing the chat.
  defp make_room(project, id) do
    max = Application.get_env(:burrow, :max_running_chats, 4)
    running = for {other, pid} <- running(project.id), other != id, do: pid

    if length(running) >= max do
      running
      |> Enum.flat_map(fn pid ->
        case activity(pid) do
          %{stoppable?: true, used_at: used_at} -> [{used_at, pid}]
          _ -> []
        end
      end)
      |> Enum.sort()
      |> Enum.take(length(running) - max + 1)
      |> Enum.each(fn {_, pid} -> send(pid, :make_room) end)
    end
  end

  @doc "The project's chats whose agent is working right now."
  def busy_ids(project_id) do
    Registry.select(@registry, [{{{project_id, :"$1"}, :_, %{busy?: true}}, [], [:"$1"]}])
    |> MapSet.new()
  end

  defp activity(pid) do
    GenServer.call(pid, :activity, 5_000)
  catch
    :exit, _ -> nil
  end

  # The project's running chats: `[{id, pid}]`.
  defp running(project_id),
    do: Registry.select(@registry, [{{{project_id, :"$1"}, :"$2", :_}, [], [{{:"$1", :"$2"}}]}])

  defp whereis(id) do
    case Registry.select(@registry, [{{{:_, id}, :"$1", :_}, [], [:"$1"]}]) do
      [pid] -> pid
      [] -> nil
    end
  end

  defp call(id, msg) do
    case whereis(id) do
      nil -> {:error, :not_running}
      pid -> GenServer.call(pid, msg, 30_000)
    end
  end

  def child_spec({project, id}),
    do: %{
      id: {__MODULE__, id},
      start: {__MODULE__, :start_link, [project, id]},
      restart: :temporary
    }

  def start_link(project, id),
    do:
      GenServer.start_link(__MODULE__, {project, id},
        name: {:via, Registry, {@registry, {project.id, id}, %{ports: [], busy?: false}}}
      )

  ## Server

  @impl true
  def init({project, id}) do
    Process.flag(:trap_exit, true)
    Secrets.subscribe(project.id)
    repo? = Projects.Project.repo?(project)

    # A repo chat claims its ports once its checkout says how many (load_pack/1).
    with {:ok, preview_port} <- if(repo?, do: {:ok, nil}, else: claim_preview_ports(project, 1)) do
      slug = project.slug
      base = base_dir(project, id)

      state = %{
        id: id,
        project: project,
        dir: workspace_dir(project, id),
        base: base,
        repo: repo?,
        network: "peon-#{slug}-#{id}",
        preview: %{
          name: "peon-preview-#{slug}-#{id}",
          port: preview_port && hd(preview_port),
          container: nil,
          status: :starting,
          secrets: nil,
          # repo chats: the preview pack, its ports by name, its env
          pack: nil,
          ports: %{},
          env: %{},
          probe: nil,
          exited_at: nil,
          restart: nil
        },
        agent: %{
          name: agent_name(project, id),
          port: free_port(),
          password: :crypto.strong_rand_bytes(24) |> Base.url_encode64(padding: false),
          container: nil,
          status: :starting
        },
        logs: :queue.new(),
        log_count: 0,
        session_id: nil,
        pr_url: if(chat = Chats.get(id), do: chat.pr_url),
        busy_since: nil,
        busy?: false,
        # What `{:chat_busy, id, busy?}` on "chats" last said
        told_busy?: false,
        prompted_at: 0,
        # A command's message is its expanded template; the chat shows what
        # was typed instead: `label` until the message appears, then `labels`.
        label: nil,
        labels: %{},
        messages: [],
        waiting: [],
        booted_at: System.monotonic_time(:millisecond),
        idle_ref: nil,
        used_at: System.monotonic_time(:millisecond),
        # Why the chat stops, for `{:stopped, reason}`
        stopped: :exited
      }

      {:ok, state, {:continue, :boot}}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  @impl true
  def handle_continue(:boot, %{repo: true} = state) do
    with :ok <-
           if(GitRepo.checked_out?(state.dir),
             do: :ok,
             else: GitRepo.checkout(state.project, state.dir, state.id)
           ),
         {:ok, state} <- load_pack(state) do
      Sandbox.create_network(state.project.slug, state.network)
      state = state |> start_preview() |> start_agent() |> touch()
      send(self(), :wait_agent)
      {:noreply, state}
    else
      {:error, reason} -> fail_boot(state, reason)
    end
  end

  def handle_continue(:boot, state) do
    unless Workspace.checked_out?(state.dir) do
      repo = Projects.repo_dir(state.project)
      Workspace.reset(repo, state.dir, Totem.Repo.ref(repo, "main"))
    end

    BuildCache.seed(state.dir)
    Sandbox.create_network(state.project.slug, state.network)
    state = state |> start_preview() |> start_agent() |> touch()
    send(self(), :wait_agent)
    {:noreply, state}
  end

  @impl true
  def handle_call(:await_ready, from, %{agent: %{status: :starting}} = state),
    do: {:noreply, %{state | waiting: [from | state.waiting]}}

  def handle_call(:await_ready, _from, state), do: {:reply, ready_reply(state), touch(state)}

  def handle_call({:prompt, text}, _from, state) do
    prompted_at = System.system_time(:millisecond)
    {picked, effort} = model(state)
    model = Burrow.OpenCode.usable(picked, Client.model_ids(conn(state)))
    effort = if model == picked, do: effort

    # The model and thinking level picked last go with this message.
    with :ok <- Client.set_model(conn(state), state.session_id, model, effort),
         {:ok, label} <- run_prompt(state, text) do
      if chat = Chats.get(state.id), do: Chats.started(chat, text)
      state = %{state | busy?: true, prompted_at: prompted_at, label: label}
      send(self(), :poll)
      {:reply, :ok, state |> broadcast_status() |> touch()}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  def handle_call(:activity, _from, state) do
    stoppable? = not state.busy? and not kept?(state)

    {:reply, %{used_at: state.used_at, stoppable?: stoppable?, busy?: state.busy?}, state}
  end

  def handle_call(:delete, _from, state) do
    if state.session_id && state.agent.status == :ready,
      do: Client.delete_session(conn(state), state.session_id)

    {:stop, :normal, :ok, %{state | stopped: :deleted}}
  end

  def handle_call(:slash_commands, _from, state),
    do: {:reply, {:ok, slash_commands_of(state)}, state}

  def handle_call(:info, _from, state), do: {:reply, {:ok, info_map(state)}, state}

  def handle_call(:interrupt, _from, state) do
    Client.interrupt(conn(state), state.session_id)
    {:reply, :ok, state}
  end

  def handle_call(:restart_preview, _from, %{repo: true} = state),
    do: {:reply, :ok, state |> restart_repo_preview() |> broadcast_status()}

  def handle_call(:restart_preview, _from, state) do
    Sandbox.stop(state.preview.name)
    {:reply, :ok, state |> start_preview() |> broadcast_status()}
  end

  def handle_call(:preview_pack, _from, state),
    do: {:reply, {:ok, state.preview.pack, state.preview.env}, state}

  def handle_call({:pr_opened, url}, _from, state) do
    Chats.set(%Chats.Chat{id: state.id}, pr_url: url)
    {:reply, :ok, broadcast_status(%{state | pr_url: url})}
  end

  def handle_call(:logs, _from, state),
    do: {:reply, {:ok, state.logs |> :queue.to_list() |> Enum.join("\n")}, state}

  @impl true
  def handle_info(:wait_agent, state) do
    cond do
      Client.ready?(conn(state)) ->
        case ensure_session(state) do
          {:ok, state} ->
            send(self(), :poll)
            state = put_in(state.agent.status, :ready)
            Enum.each(state.waiting, &GenServer.reply(&1, ready_reply(state)))
            {:noreply, broadcast_status(%{state | waiting: []})}

          {:error, reason} ->
            fail_boot(state, {:session, reason})
        end

      System.monotonic_time(:millisecond) - state.booted_at > @boot_timeout ->
        fail_boot(state, :agent_boot_timeout)

      true ->
        Process.send_after(self(), :wait_agent, 500)
        {:noreply, state}
    end
  end

  def handle_info(:poll, %{agent: %{status: :ready}} = state) do
    state =
      case Client.messages(conn(state), state.session_id) do
        {:ok, raw} ->
          state = claim_label(state, raw)
          messages = raw |> Enum.flat_map(&normalize/1) |> relabel(state.labels)
          busy? = state.busy? and not finished?(raw, state.prompted_at)

          state =
            if messages != state.messages,
              do: broadcast(%{state | messages: messages}, {:messages, messages}),
              else: state

          if busy? != state.busy?, do: turn_over(state, messages)
          if busy? != state.busy?, do: broadcast_status(%{state | busy?: busy?}), else: state

        {:error, reason} ->
          Logger.warning("polling chat #{state.id} failed: #{inspect(reason)}")
          state
      end

    if state.busy?, do: Process.send_after(self(), :poll, @poll_interval)
    {:noreply, state}
  end

  def handle_info(:poll, state), do: {:noreply, state}

  def handle_info({port, {:data, data}}, %{repo: true, preview: %{container: port}} = state) do
    File.write(preview_log(state), data, [:append])
    {:noreply, append_logs(state, data)}
  end

  # A start command that exits 0 has detached (e.g. `docker compose up -d`).
  def handle_info(
        {port, {:exit_status, code}},
        %{repo: true, preview: %{container: port}} = state
      ) do
    preview = %{
      state.preview
      | container: nil,
        exited_at: System.monotonic_time(:millisecond),
        status: if(code == 0, do: state.preview.status, else: {:crashed, code})
    }

    {:noreply, broadcast_status(%{state | preview: preview})}
  end

  def handle_info({:probe, ref}, %{preview: %{probe: ref, status: :starting} = preview} = state) do
    cond do
      HostPreview.up?(preview.port, preview.pack.ready) ->
        {:noreply, broadcast_status(put_in(state.preview.status, :running))}

      preview.exited_at &&
          System.monotonic_time(:millisecond) - preview.exited_at > @detached_timeout ->
        {:noreply, broadcast_status(put_in(state.preview.status, {:crashed, 0}))}

      true ->
        Process.send_after(self(), {:probe, ref}, @probe_interval)
        {:noreply, state}
    end
  end

  def handle_info({:probe, _ref}, state), do: {:noreply, state}

  def handle_info({container, {:data, data}}, %{preview: %{container: container}} = state) do
    state = append_logs(state, data)

    if state.preview.status == :starting and data =~ "Access " and data =~ "Endpoint at",
      do: {:noreply, broadcast_status(put_in(state.preview.status, :running))},
      else: {:noreply, state}
  end

  def handle_info({container, {:exit_status, code}}, %{preview: %{container: container}} = state) do
    preview = %{state.preview | container: nil, status: {:crashed, code}}
    {:noreply, broadcast_status(%{state | preview: preview})}
  end

  def handle_info({container, {:data, data}}, %{agent: %{container: container}} = state) do
    Logger.debug("agent #{state.id}: #{String.trim(data)}")
    {:noreply, state}
  end

  def handle_info({container, {:exit_status, code}}, %{agent: %{container: container}} = state) do
    Logger.warning("agent for chat #{state.id} exited with #{code}")
    {:stop, :normal, put_in(state.agent.container, nil)}
  end

  # The preview gets secrets as env vars when it starts, so new values restart it.
  def handle_info({:secrets, _list}, %{repo: true, preview: %{pack: %PreviewPack{}}} = state) do
    if state.preview.secrets == Secrets.fingerprint(Secrets.env(state.project.id)),
      do: {:noreply, state},
      else: {:noreply, state |> restart_repo_preview() |> broadcast_status()}
  end

  def handle_info({ref, output}, %{preview: %{restart: ref}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, restarted(state, output)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{preview: %{restart: ref}} = state),
    do: {:noreply, restarted(state, "stop failed: #{inspect(reason)}")}

  def handle_info({:secrets, _list}, %{preview: %{container: container} = preview} = state)
      when container != nil do
    if preview.secrets == Secrets.fingerprint(Secrets.env(state.project.id)) do
      {:noreply, state}
    else
      Sandbox.stop(preview.name)
      {:noreply, state |> start_preview() |> broadcast_status()}
    end
  end

  def handle_info(:idle, %{busy?: true} = state), do: {:noreply, touch(state)}

  def handle_info(:idle, state) do
    if kept?(state),
      do: {:noreply, touch(state)},
      else: {:stop, :normal, %{state | stopped: :idle}}
  end

  # Another chat is starting and this one was used longest ago (make_room/1).
  def handle_info(:make_room, %{busy?: true} = state), do: {:noreply, state}
  def handle_info(:make_room, state), do: {:stop, :normal, %{state | stopped: :room}}

  def handle_info(_msg, state), do: {:noreply, state}

  defp kept?(state),
    do:
      Chats.kept_running?(Chats.get(state.id)) or
        Burrow.Activity.unshipped?(state.project, state.id)

  @impl true
  def terminate(_reason, %{repo: true} = state) do
    broadcast(state, {:stopped, state.stopped})
    tell_busy(%{state | busy?: false})
    Sandbox.stop(state.agent.name)
    stop_preview(state)
    Sandbox.remove_network(state.network)
  end

  def terminate(_reason, state) do
    broadcast(state, {:stopped, state.stopped})
    tell_busy(%{state | busy?: false})
    Sandbox.stop(state.agent.name)
    Sandbox.stop(state.preview.name)
    Sandbox.remove_network(state.network)
  end

  ## Containers

  defp start_preview(%{repo: true, preview: %{pack: %PreviewPack{} = pack}} = state) do
    env =
      Map.merge(
        Secrets.env(state.project.id),
        PreviewPack.env(pack, state.preview.ports, &Burrow.Ports.url/1, state.preview.name)
      )

    File.write(preview_log(state), "\n[peon] $ #{pack.start}\n", [:append])
    port = HostPreview.start(state.dir, pack.start, env)
    ref = make_ref()
    send(self(), {:probe, ref})

    preview = %{
      state.preview
      | container: port,
        status: :starting,
        env: env,
        probe: ref,
        exited_at: nil,
        secrets: Secrets.fingerprint(Secrets.env(state.project.id))
    }

    %{state | preview: preview}
  end

  # No pack, or one that doesn't parse: the chat works, the pane says why.
  defp start_preview(%{repo: true} = state) do
    status =
      case state.preview.pack do
        {:error, message} -> {:pack_error, message}
        _ -> :no_pack
      end

    put_in(state.preview.status, status)
  end

  defp start_preview(state) do
    script =
      "mkdir -p .peon && " <>
        Sandbox.unlock_deps() <>
        "mix do deps.get + ecto.migrate + phx.server 2>&1 | tee -a .peon/preview.log"

    # Secrets go to the preview only, never to the agent's container.
    secrets = Secrets.env(state.project.id)

    container =
      Sandbox.start(state.dir, script,
        project: state.project.slug,
        name: state.preview.name,
        network: state.network,
        alias: "preview",
        env:
          Map.merge(secrets, %{"MIX_ENV" => "dev", "PREVIEW_BIND" => "0.0.0.0", "PORT" => "4000"}),
        ports: [{state.preview.port, 4000}]
      )

    preview = %{
      state.preview
      | container: container,
        status: :starting,
        secrets: Secrets.fingerprint(secrets)
    }

    %{state | preview: preview}
  end

  defp start_agent(state) do
    config_dir = Path.join(state.base, "opencode-config")
    write_agent_config(state, config_dir)

    data_dir = Burrow.OpenCode.data_dir(state.project.user_id)
    File.mkdir_p!(data_dir)

    bin =
      System.find_executable(Application.get_env(:burrow, :opencode_bin) || "opencode") ||
        raise "opencode not found"

    container =
      Sandbox.start(state.dir, "exec opencode serve --hostname 0.0.0.0 --port 4096",
        project: state.project.slug,
        name: state.agent.name,
        network: state.network,
        env: %{
          "MIX_ENV" => "test",
          "XDG_CONFIG_HOME" => "/opencode/config",
          "XDG_DATA_HOME" => "/opencode/data",
          "OPENCODE_SERVER_PASSWORD" => state.agent.password
        },
        mounts:
          [
            {Path.expand(bin) |> resolve_link(), "/usr/local/bin/opencode", :ro},
            {config_dir, "/opencode/config", :ro},
            {data_dir, "/opencode/data", :rw},
            {MCP.socket_path(), "/peon/mcp.sock", :rw},
            {Application.app_dir(:burrow, "priv/mcp_bridge.exs"), "/peon/mcp_bridge.exs", :ro}
          ] ++ repo_mounts(state),
        hosts: if(state.repo, do: [{"host.docker.internal", "host-gateway"}], else: []),
        ports: [{state.agent.port, 4096}]
      )

    %{state | agent: %{state.agent | container: container, status: :starting}}
  end

  # The agent may use its own tools freely (it runs in the sandbox), but not
  # leave /app or ask questions nobody can answer.
  defp write_agent_config(state, config_dir) do
    dir = Path.join(config_dir, "opencode")
    File.mkdir_p!(dir)
    instructions = write_instructions(state, dir)

    allow = ~w(read edit glob grep list bash task todowrite webfetch websearch lsp skill)
    {model, _effort} = model(state)

    config = %{
      "$schema" => "https://opencode.ai/config.json",
      "model" => model,
      "autoupdate" => false,
      "share" => "disabled",
      "instructions" => [instructions],
      "permission" =>
        allow
        |> Map.new(&{&1, "allow"})
        |> Map.merge(%{
          "external_directory" => "deny",
          "question" => "deny",
          "doom_loop" => "deny"
        }),
      # Peon's tools, over the mounted Unix socket (see Burrow.Agent.MCP.Plug).
      "mcp" => %{
        "peon" => %{
          "type" => "local",
          "command" => ["elixir", "/peon/mcp_bridge.exs"],
          "environment" => %{"PEON_MCP_TOKEN" => MCP.token(state.project.id, state.id)},
          # submit_changeset waits for checks, which can take minutes.
          "timeout" => :timer.minutes(20)
        }
      }
    }

    File.write!(Path.join(dir, "opencode.json"), Jason.encode!(config, pretty: true))
  end

  # Peon's instructions as a file opencode reads: in the workspace's own .peon
  # for the template app, next to the opencode config for a repo, whose .peon
  # is the repo's.
  defp write_instructions(%{repo: true} = state, config_dir) do
    File.write!(
      Path.join(config_dir, "peon.md"),
      Prompt.repo_instructions(state.project, prompt_facts(state))
    )

    "/opencode/config/opencode/peon.md"
  end

  defp write_instructions(state, _config_dir) do
    File.mkdir_p!(Path.join(state.dir, ".peon"))

    File.write!(
      Path.join([state.dir, ".peon", "instructions.md"]),
      Prompt.instructions(state.project, with(%{follows: id} <- Chats.get(state.id), do: id))
    )

    ".peon/instructions.md"
  end

  defp prompt_facts(state) do
    %{
      branch: "peon/#{state.id}",
      pack: state.preview.pack,
      ports: state.preview.ports,
      url: &Burrow.Ports.url/1
    }
  end

  # The repo's preview log, readable by the agent at /peon/preview.log.
  defp repo_mounts(%{repo: true} = state) do
    File.mkdir_p!(state.base)
    File.touch!(preview_log(state))
    [{preview_log(state), "/peon/preview.log", :ro}]
  end

  defp repo_mounts(_state), do: []

  defp preview_log(state), do: Path.join(state.base, "preview.log")

  # Loads the checkout's preview pack and claims the ports it names: its
  # tunneled `ports` from the project's range, `local_ports` anywhere.
  defp load_pack(state) do
    case PreviewPack.load(state.dir) do
      {:ok, pack} ->
        with {:ok, claimed} <- claim_preview_ports(state.project, PreviewPack.port_count(pack)) do
          tunneled = Enum.zip(pack.ports, claimed) |> Map.new()
          local = Map.new(pack.local_ports, &{&1, free_port()})

          preview = %{
            state.preview
            | pack: pack,
              ports: Map.merge(tunneled, local),
              port: tunneled[pack.frame]
          }

          {:ok, %{state | preview: preview}}
        end

      other ->
        {:ok, %{state | preview: %{state.preview | pack: other, ports: %{}, port: nil}}}
    end
  end

  defp stop_preview(%{preview: %{pack: %PreviewPack{} = pack} = preview} = state) do
    output = HostPreview.stop(state.dir, preview.container, pack.stop, preview.env)
    if output, do: File.write(preview_log(state), "[peon] $ #{pack.stop}\n#{output}", [:append])
    %{state | preview: %{preview | container: nil, status: :stopped, probe: nil}}
  end

  defp stop_preview(state), do: state

  # Stopping can take a while (e.g. `docker compose down`), so a restart stops
  # the preview in a task and starts it again when that is done (restarted/2).
  defp restart_repo_preview(%{preview: %{restart: ref}} = state) when ref != nil, do: state

  defp restart_repo_preview(%{preview: preview} = state) do
    %{dir: dir} = state

    task =
      Task.Supervisor.async_nolink(Burrow.TaskSupervisor, fn ->
        with %PreviewPack{} = pack <- preview.pack,
             do: HostPreview.stop(dir, preview.container, pack.stop, preview.env)
      end)

    %{
      state
      | preview: %{preview | container: nil, status: :starting, probe: nil, restart: task.ref}
    }
  end

  defp restarted(state, output) do
    if is_binary(output),
      do: File.write(preview_log(state), "[peon] stopped\n#{output}", [:append])

    state = put_in(state.preview.restart, nil)

    case load_pack(state) do
      {:ok, state} ->
        state |> start_preview() |> broadcast_status()

      {:error, :no_free_preview_port} ->
        message = "every preview port is in use by other chats"
        broadcast_status(put_in(state.preview.status, {:pack_error, message}))
    end
  end

  # The chat's model (provider/model, else its owner's) and effort (the
  # model's opencode variant, nil for its default).
  defp model(state) do
    chat = Chats.get(state.id)
    {(chat && chat.model) || Burrow.OpenCode.model(state.project.user_id), chat && chat.effort}
  end

  defp ensure_session(state) do
    chat = Chats.get(state.id)

    if chat.session_id && Client.session_exists?(conn(state), chat.session_id) do
      {:ok, %{state | session_id: chat.session_id}}
    else
      with {:ok, session_id} <- Client.create_session(conn(state), chat.title) do
        Chats.set(chat, session_id: session_id)
        {:ok, %{state | session_id: session_id}}
      end
    end
  end

  # A turn that ended in an error hands any incident this chat was fixing
  # back to the user (`Burrow.Incidents.chat_failed/3`).
  defp turn_over(state, messages) do
    case List.last(messages) do
      %{role: :error} ->
        errors = messages |> Enum.take(-3) |> Enum.filter(&(&1.role == :error))
        Incidents.chat_failed(state.project.id, state.id, Enum.map_join(errors, "; ", & &1.text))

      _ ->
        :ok
    end
  end

  defp fail_boot(state, reason) do
    Logger.error("chat #{state.id} could not start its agent: #{inspect(reason)}")

    Incidents.chat_failed(
      state.project.id,
      state.id,
      "the agent could not start: #{inspect(reason)}"
    )

    state = put_in(state.agent.status, {:error, reason})
    Enum.each(state.waiting, &GenServer.reply(&1, ready_reply(state)))
    {:stop, :normal, %{state | waiting: []}}
  end

  ## Helpers

  defp conn(state),
    do: %{base_url: "http://127.0.0.1:#{state.agent.port}", password: state.agent.password}

  defp ready_reply(%{agent: %{status: :ready}} = state), do: {:ok, info_map(state)}
  defp ready_reply(%{agent: %{status: {:error, reason}}}), do: {:error, reason}

  defp info_map(state) do
    %{
      preview_url: state.preview.port && Burrow.Ports.url(state.preview.port),
      preview_links: preview_links(state),
      preview_status: state.preview.status,
      pr_url: state.pr_url,
      agent_status: state.agent.status,
      busy?: state.busy?,
      attach:
        "OPENCODE_SERVER_PASSWORD=#{state.agent.password} opencode --server http://127.0.0.1:#{state.agent.port} --session #{state.session_id}",
      messages: state.messages
    }
  end

  # A repo preview's other public ports, by name, for links next to the frame.
  defp preview_links(%{preview: %{pack: %PreviewPack{} = pack, ports: ports}}) do
    for name <- pack.ports, name != pack.frame, do: {name, Burrow.Ports.url(ports[name])}
  end

  defp preview_links(_state), do: []

  defp broadcast(state, message) do
    Projects.broadcast(state.project.id, "chat:#{state.id}", message)
    state
  end

  defp broadcast_status(state),
    do: state |> broadcast({:status, Map.delete(info_map(state), :messages)}) |> tell_busy()

  # Every chat's tab shows whether its agent works (`busy_ids/0` at first).
  defp tell_busy(%{busy?: busy?, told_busy?: busy?} = state), do: state

  defp tell_busy(state) do
    busy? = state.busy?
    Registry.update_value(@registry, {state.project.id, state.id}, &%{&1 | busy?: busy?})
    Projects.broadcast(state.project.id, "chats", {:chat_busy, state.id, busy?})
    %{state | told_busy?: state.busy?}
  end

  defp touch(state) do
    if state.idle_ref, do: Process.cancel_timer(state.idle_ref)

    %{
      state
      | idle_ref: Process.send_after(self(), :idle, @idle_timeout),
        used_at: System.monotonic_time(:millisecond)
    }
  end

  # "/name args" runs an opencode command or loads a skill with the message;
  # anything else, or an unknown name, is sent as written. Returns the label
  # for a command's message.
  defp run_prompt(state, text) do
    {name, args} =
      case Regex.run(~r{\A/(\S+)\s*(.*)\z}s, text) do
        [_, name, args] -> {name, args}
        nil -> {nil, nil}
      end

    case name && Enum.find(slash_commands_of(state), &(&1.name == name)) do
      %{kind: :command} ->
        with :ok <- Client.command(conn(state), state.session_id, name, args), do: {:ok, text}

      %{kind: :skill} ->
        text = if args == "", do: text, else: args

        with {:ok, _} <- Client.prompt(conn(state), state.session_id, text, [name]),
             do: {:ok, nil}

      nil ->
        with {:ok, _} <- Client.prompt(conn(state), state.session_id, text), do: {:ok, nil}
    end
  end

  # Commands win over skills of the same name, as in opencode's own UI.
  defp slash_commands_of(state) do
    commands = with({:ok, list} <- Client.commands(conn(state)), do: list, else: (_ -> []))
    skills = with({:ok, list} <- Client.skills(conn(state)), do: list, else: (_ -> []))
    taken = MapSet.new(commands, & &1.name)

    Enum.map(commands, &Map.put(&1, :kind, :command)) ++
      for skill <- skills,
          not MapSet.member?(taken, skill.name),
          do: Map.put(skill, :kind, :skill)
  end

  defp claim_label(%{label: nil} = state, _raw), do: state

  defp claim_label(state, raw) do
    case Enum.find(
           raw,
           &(&1["type"] == "user" and get_in(&1, ["time", "created"]) >= state.prompted_at)
         ) do
      nil -> state
      message -> %{state | label: nil, labels: Map.put(state.labels, message["id"], state.label)}
    end
  end

  defp relabel(messages, labels) when labels == %{}, do: messages

  defp relabel(messages, labels) do
    Enum.map(messages, fn
      %{role: :user, id: id} = m when is_map_key(labels, id) -> %{m | text: labels[id]}
      m -> m
    end)
  end

  # The turn is over when opencode reports the session idle after our prompt.
  defp finished?(raw, prompted_at) do
    Enum.any?(raw, &(&1["type"] == "idle" and get_in(&1, ["time", "created"]) >= prompted_at))
  end

  @doc false
  # opencode session messages -> what the chat UI shows.
  def normalize(%{"type" => "user"} = m) do
    text = m["text"] || get_in(m, ["payload", "text"]) || ""
    skills = m["skills"] || get_in(m, ["payload", "skills"]) || []
    [%{id: m["id"], role: :user, text: with_skills(text, skills)}]
  end

  def normalize(%{"type" => "assistant", "content" => content} = m) when is_list(content) do
    content
    |> Enum.with_index()
    |> Enum.flat_map(fn {part, i} -> normalize_part(part, "#{m["id"]}-#{i}") end)
    |> then(fn parts ->
      if m["error"],
        do: parts ++ [%{id: "#{m["id"]}-error", role: :error, text: error_text(m["error"])}],
        else: parts
    end)
  end

  def normalize(%{"type" => "idle", "outcome" => outcome} = m) when outcome != "succeeded",
    do: [%{id: m["id"], role: :error, text: "The agent stopped: #{outcome}"}]

  def normalize(_), do: []

  # A message sent with skills shows them as typed: "/skill text".
  defp with_skills(text, []), do: text
  defp with_skills("/" <> _ = text, _skills), do: text
  defp with_skills(text, skills), do: Enum.map_join(skills, "", &"/#{&1["id"]} ") <> text

  defp error_text(%{"message" => message}) when is_binary(message), do: message
  defp error_text(%{"data" => %{"message" => message}}) when is_binary(message), do: message
  defp error_text(error), do: inspect(error)

  defp normalize_part(%{"type" => "text", "text" => text}, id) when text != "",
    do: [%{id: id, role: :assistant, text: text}]

  defp normalize_part(%{"type" => "reasoning"}, _id), do: []

  defp normalize_part(%{"type" => type} = part, id)
       when type in ["tool", "tool-call", "tool_call"] do
    name = part["name"] || part["tool"] || get_in(part, ["call", "name"]) || "tool"
    input = part["input"] || part["arguments"] || get_in(part, ["state", "input"]) || %{}
    status = get_in(part, ["state", "status"]) || part["status"]
    output = tool_output(part)

    case get_in(part, ["state", "metadata", "toolCalls"]) do
      # Code mode: MCP tools (Peon's) are called from inside a generic "execute".
      [_ | _] = calls ->
        text = Enum.map_join(calls, ", ", &"#{&1["tool"]} #{summarize(&1["input"])}")
        peon? = Enum.any?(calls, &String.starts_with?(to_string(&1["tool"]), "peon"))
        [%{id: id, role: :tool, text: text, status: status, detail: output, peon?: peon?}]

      _ ->
        peon? = String.starts_with?(name, "peon")
        detail = if peon? or status == "error", do: output

        [
          %{
            id: id,
            role: :tool,
            text: "#{name} #{summarize(input)}",
            status: status,
            detail: detail,
            peon?: peon?
          }
        ]
    end
  end

  defp normalize_part(%{"type" => type}, id)
       when type not in ["text", "step-start", "step-finish"],
       do: [%{id: id, role: :tool, text: type, status: nil}]

  defp normalize_part(_part, _id), do: []

  # A tool's text output, from opencode's state.content (or older output fields).
  defp tool_output(part) do
    case get_in(part, ["state", "content"]) || get_in(part, ["state", "output"]) || part["output"] do
      text when is_binary(text) ->
        String.slice(text, 0, 4000)

      [_ | _] = content ->
        content
        |> Enum.map_join("\n", &(&1["text"] || ""))
        |> String.trim()
        |> String.slice(0, 4000)

      _ ->
        nil
    end
  end

  # A patch is shown by the files it touches.
  defp summarize(%{"patchText" => patch}) when is_binary(patch) do
    ~r/^\*\*\* (?:Update|Add|Delete) File: (.+)$/m
    |> Regex.scan(patch, capture: :all_but_first)
    |> List.flatten()
    |> Enum.join(" ")
    |> String.slice(0, 160)
  end

  defp summarize(input) when is_map(input) do
    input
    |> Map.take(["filePath", "path", "command", "pattern", "url", "intent", "description"])
    |> Map.values()
    |> Enum.map_join(" ", &to_string/1)
    |> String.slice(0, 160)
  end

  defp summarize(_), do: ""

  defp append_logs(state, data) do
    data
    |> String.split(["\r\n", "\n"], trim: true)
    |> Enum.reduce(state, fn line, state ->
      logs = :queue.in(line, state.logs)

      if state.log_count >= @log_lines,
        do: %{state | logs: :queue.drop(logs)},
        else: %{state | logs: logs, log_count: state.log_count + 1}
    end)
  end

  # Preview ports come from the project's range; the registry value marks
  # them as taken, so two chats never share one. A repo chat's preview may
  # need several.
  defp claim_preview_ports(project, count) do
    me = self()
    Registry.update_value(@registry, {project.id, key_id()}, &%{&1 | ports: []})

    used =
      Registry.select(@registry, [{{{project.id, :_}, :"$1", :"$2"}, [], [{{:"$1", :"$2"}}]}])
      |> Enum.flat_map(fn {pid, value} -> if pid == me, do: [], else: value.ports end)
      |> MapSet.new()

    {previews, _envs} = Burrow.Cell.ports(project)

    free =
      previews
      |> Enum.filter(&(Burrow.Ports.browser_safe?(&1) and not MapSet.member?(used, &1)))
      |> Enum.take(count)

    if length(free) == count do
      Registry.update_value(@registry, {project.id, key_id()}, &%{&1 | ports: free})
      {:ok, free}
    else
      {:error, :no_free_preview_port}
    end
  end

  # This process's chat id, from its registry key.
  defp key_id do
    [{_project, id}] = Registry.keys(@registry, self())
    id
  end

  defp free_port do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :gen_tcp.close(socket)
    port
  end

  defp resolve_link(path) do
    case File.read_link(path) do
      {:ok, target} -> target |> Path.expand(Path.dirname(path)) |> resolve_link()
      {:error, _} -> path
    end
  end
end
