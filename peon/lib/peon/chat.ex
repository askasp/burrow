defmodule Peon.Chat do
  @moduledoc """
  The process behind one chat. It owns, on a private Docker network:

    * the workspace: a checkout of the app the agent edits (`Peon.Workspace`)
    * the preview container: the app in dev mode on the workspace, reachable by
      the agent as http://preview:4000 and by the user on a local port
    * the agent container: `opencode serve` on the workspace, with the user's
      opencode login, Peon's instructions and Peon's MCP tools

  The conversation lives in the chat's opencode session. While the agent
  works, this process polls the session and broadcasts on topic `"chat:<id>"`:

    * `{:messages, messages}` - the whole conversation, normalized
    * `{:status, status}` - see `info/1`
    * `{:conflicts, paths}` - files changed both in the workspace and on main

  When main moves, the workspace is rebased onto it. Containers stop after
  `@idle_timeout` without activity; the next use starts them again.

  In a repo project (`Peon.Source`) the workspace is a git checkout instead
  (`Peon.Git`), and the preview is the repo's preview pack run on the host
  (`Peon.HostPreview`), up once its framed port answers.
  """

  use GenServer, restart: :temporary

  require Logger

  alias Peon.{Chats, Git, HostPreview, Incidents, PreviewPack, Sandbox, Secrets, Source, Store}
  alias Peon.Workspace
  alias Peon.Agent.{MCP, Prompt}
  alias Peon.OpenCode.Client

  @registry Peon.ChatRegistry
  @idle_timeout :timer.minutes(30)
  @boot_timeout :timer.seconds(90)
  @poll_interval 1_500
  @log_lines 400
  @probe_interval 2_000
  # How long a detached preview (its start command exited 0) gets to answer.
  @detached_timeout :timer.minutes(5)

  ## API

  @doc "Starts the chat's containers if needed and waits until the agent is ready."
  def ensure_started(id) do
    case DynamicSupervisor.start_child(Peon.ChatSupervisor, {__MODULE__, id}) do
      {:ok, pid} ->
        GenServer.call(pid, :await_ready, @boot_timeout + 5_000)

      {:error, {:already_started, pid}} ->
        GenServer.call(pid, :await_ready, @boot_timeout + 5_000)

      # e.g. :no_free_preview_port when every preview port is in use
      {:error, reason} ->
        {:error, reason}
    end
  end

  def send_message(id, text) do
    with {:ok, _info} <- ensure_started(id), do: call(id, {:prompt, text})
  end

  @doc """
  `%{preview_url, preview_status, agent_status, busy?, attach, conflicts, messages}`;
  `agent_status` is `:starting`, `:ready` or `{:error, reason}`.
  """
  def info(id), do: call(id, :info)

  def interrupt(id), do: call(id, :interrupt)

  def restart_preview(id), do: call(id, :restart_preview)

  @doc "A repo chat's preview pack and its commands' environment: `{:ok, pack, env}`."
  def preview_pack(id), do: call(id, :preview_pack)

  @doc "Records a repo chat's pull request and shows it."
  def pr_opened(id, url), do: call(id, {:pr_opened, url})

  def logs(id), do: call(id, :logs)

  def subscribe(id), do: Phoenix.PubSub.subscribe(Peon.PubSub, "chat:#{id}")

  def workspace_dir(id),
    do: Path.join([Application.fetch_env!(:peon, :data_dir), "chats", id, "workspace"])

  defp call(id, msg) do
    case GenServer.whereis({:via, Registry, {@registry, id}}) do
      nil -> {:error, :not_running}
      pid -> GenServer.call(pid, msg, 30_000)
    end
  end

  def child_spec(id),
    do: %{id: {__MODULE__, id}, start: {__MODULE__, :start_link, [id]}, restart: :temporary}

  def start_link(id),
    do: GenServer.start_link(__MODULE__, id, name: {:via, Registry, {@registry, id}})

  ## Server

  @impl true
  def init(id) do
    Process.flag(:trap_exit, true)
    Store.subscribe()
    Secrets.subscribe()

    # A repo chat claims its ports once its checkout says how many (load_pack/1).
    with {:ok, preview_port} <- if(Source.repo?(), do: {:ok, nil}, else: claim_preview_port(id)) do
      slug = Application.fetch_env!(:peon, :project_slug)
      base = Path.join([Application.fetch_env!(:peon, :data_dir), "chats", id])

      state = %{
        id: id,
        dir: workspace_dir(id),
        base: base,
        repo: Source.repo?(),
        network: "peon-#{slug}-#{id}",
        preview: %{
          name: "peon-preview-#{slug}-#{id}",
          port: preview_port,
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
          name: "peon-agent-#{slug}-#{id}",
          port: free_port(),
          password: :crypto.strong_rand_bytes(24) |> Base.url_encode64(padding: false),
          container: nil,
          status: :starting
        },
        logs: :queue.new(),
        log_count: 0,
        session_id: nil,
        pr_url: if(chat = Chats.get(id), do: chat.pr_url),
        busy?: false,
        prompted_at: 0,
        messages: [],
        conflicts: [],
        waiting: [],
        booted_at: System.monotonic_time(:millisecond),
        idle_ref: nil
      }

      {:ok, state, {:continue, :boot}}
    end
  end

  @impl true
  def handle_continue(:boot, %{repo: true} = state) do
    with :ok <- if(Git.checked_out?(state.dir), do: :ok, else: Git.checkout(state.dir, state.id)),
         {:ok, state} <- load_pack(state) do
      Sandbox.create_network(state.network)
      state = state |> start_preview() |> start_agent() |> touch()
      send(self(), :wait_agent)
      {:noreply, state}
    else
      {:error, reason} -> fail_boot(state, reason)
    end
  end

  def handle_continue(:boot, state) do
    unless Workspace.checked_out?(state.dir) do
      File.mkdir_p!(state.dir)
      Workspace.checkout(state.dir, Peon.Code.ref("main").changeset_id)
    end

    Sandbox.create_network(state.network)
    state = state |> start_preview() |> start_agent() |> touch()
    send(self(), :wait_agent)
    {:noreply, state}
  end

  @impl true
  def handle_call(:await_ready, from, %{agent: %{status: :starting}} = state),
    do: {:noreply, %{state | waiting: [from | state.waiting]}}

  def handle_call(:await_ready, _from, state), do: {:reply, ready_reply(state), touch(state)}

  def handle_call({:prompt, text}, _from, state) do
    case Client.prompt(conn(state), state.session_id, text) do
      {:ok, _} ->
        state = %{state | busy?: true, prompted_at: System.system_time(:millisecond)}
        send(self(), :poll)
        {:reply, :ok, state |> broadcast_status() |> touch()}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

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
    Chats.set_pr_url(state.id, url)
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
          messages = Enum.flat_map(raw, &normalize/1)
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

  def handle_info({:ref_moved, "main", changeset_id, _version}, state) do
    conflicts = Workspace.rebase(state.dir, changeset_id)
    {:noreply, broadcast(%{state | conflicts: conflicts}, {:conflicts, conflicts})}
  end

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
    if state.preview.secrets == Secrets.fingerprint(),
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
    if preview.secrets == Secrets.fingerprint() do
      {:noreply, state}
    else
      Sandbox.stop(preview.name)
      {:noreply, state |> start_preview() |> broadcast_status()}
    end
  end

  def handle_info(:idle, %{busy?: true} = state), do: {:noreply, touch(state)}

  # The inline chat's preview is the dev version Burrow shows while its
  # changeset is open, so it stays up until that is merged or discarded.
  def handle_info(:idle, state) do
    if Peon.Inline.keep_alive?(state.id),
      do: {:noreply, touch(state)},
      else: {:stop, :normal, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{repo: true} = state) do
    Sandbox.stop(state.agent.name)
    stop_preview(state)
    Sandbox.remove_network(state.network)
  end

  def terminate(_reason, state) do
    Sandbox.stop(state.agent.name)
    Sandbox.stop(state.preview.name)
    Sandbox.remove_network(state.network)
  end

  ## Containers

  defp start_preview(%{repo: true, preview: %{pack: %PreviewPack{} = pack}} = state) do
    env =
      Map.merge(
        Secrets.env(),
        PreviewPack.env(pack, state.preview.ports, &Peon.Ports.url/1, state.preview.name)
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
        secrets: Secrets.fingerprint()
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
        "(mix deps.get && mix ecto.migrate && mix phx.server) 2>&1 | tee -a .peon/preview.log"

    # Secrets go to the preview only, never to the agent's container.
    secrets = Secrets.env()

    container =
      Sandbox.start(state.dir, script,
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
    opencode = Application.fetch_env!(:peon, :opencode)
    data_dir = opencode[:data_dir]
    File.mkdir_p!(data_dir)
    bin = System.find_executable(opencode[:bin] || "opencode") || raise "opencode not found"

    container =
      Sandbox.start(state.dir, "exec opencode serve --hostname 0.0.0.0 --port 4096",
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
            {Application.app_dir(:peon, "priv/mcp_bridge.exs"), "/peon/mcp_bridge.exs", :ro}
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
    chat = Chats.get(state.id)
    model = (chat && chat.model) || Application.fetch_env!(:peon, :opencode)[:model]

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
      # Peon's tools, over the mounted Unix socket (see PeonWeb.MCPPlug).
      "mcp" => %{
        "peon" => %{
          "type" => "local",
          "command" => ["elixir", "/peon/mcp_bridge.exs"],
          "environment" => %{"PEON_MCP_TOKEN" => MCP.token(state.id)},
          # submit_changeset waits for checks, which can take minutes.
          "timeout" => :timer.minutes(20)
        }
      }
    }

    config = Map.merge(config, effort_config(model, chat && chat.effort))
    File.write!(Path.join(dir, "opencode.json"), Jason.encode!(config, pretty: true))
  end

  # Peon's instructions as a file opencode reads: in the workspace's own .peon
  # for the template app, next to the opencode config for a repo, whose .peon
  # is the repo's.
  defp write_instructions(%{repo: true} = state, config_dir) do
    File.write!(Path.join(config_dir, "peon.md"), Prompt.repo_instructions(prompt_facts(state)))
    "/opencode/config/opencode/peon.md"
  end

  defp write_instructions(state, _config_dir) do
    File.write!(Path.join([state.dir, ".peon", "instructions.md"]), Prompt.instructions())
    ".peon/instructions.md"
  end

  defp prompt_facts(state) do
    %{
      branch: "peon/#{state.id}",
      pack: state.preview.pack,
      ports: state.preview.ports,
      url: &Peon.Ports.url/1
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
        with {:ok, claimed} <- claim_preview_ports(state.id, PreviewPack.port_count(pack)) do
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
      Task.Supervisor.async_nolink(Peon.TaskSupervisor, fn ->
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

  @doc false
  # The chat's effort as the provider's model options. Medium (or none) keeps
  # the model's defaults; providers without such an option ignore it.
  def effort_config(model, effort) when effort in ["low", "high"] do
    case String.split(model || "", "/", parts: 2) do
      ["openai", id] ->
        %{
          "provider" => %{
            "openai" => %{"models" => %{id => %{"options" => %{"reasoningEffort" => effort}}}}
          }
        }

      ["anthropic", id] when effort == "high" ->
        thinking = %{"type" => "enabled", "budgetTokens" => 16_000}

        %{
          "provider" => %{
            "anthropic" => %{"models" => %{id => %{"options" => %{"thinking" => thinking}}}}
          }
        }

      _ ->
        %{}
    end
  end

  def effort_config(_model, _effort), do: %{}

  defp ensure_session(state) do
    chat = Chats.get(state.id)

    if chat.session_id && Client.session_exists?(conn(state), chat.session_id) do
      {:ok, %{state | session_id: chat.session_id}}
    else
      with {:ok, session_id} <- Client.create_session(conn(state), chat.title) do
        Chats.set_session(state.id, session_id)
        {:ok, %{state | session_id: session_id}}
      end
    end
  end

  # A turn that ended in an error hands any incident this chat was fixing
  # back to the user (`Peon.Incidents.chat_failed/2`).
  defp turn_over(state, messages) do
    case List.last(messages) do
      %{role: :error} ->
        errors = messages |> Enum.take(-3) |> Enum.filter(&(&1.role == :error))
        Incidents.chat_failed(state.id, Enum.map_join(errors, "; ", & &1.text))

      _ ->
        :ok
    end
  end

  defp fail_boot(state, reason) do
    Logger.error("chat #{state.id} could not start its agent: #{inspect(reason)}")
    Incidents.chat_failed(state.id, "the agent could not start: #{inspect(reason)}")
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
      preview_url: state.preview.port && Peon.Ports.url(state.preview.port),
      preview_links: preview_links(state),
      preview_status: state.preview.status,
      pr_url: state.pr_url,
      agent_status: state.agent.status,
      busy?: state.busy?,
      attach:
        "OPENCODE_SERVER_PASSWORD=#{state.agent.password} opencode --server http://127.0.0.1:#{state.agent.port} --session #{state.session_id}",
      conflicts: state.conflicts,
      messages: state.messages
    }
  end

  # A repo preview's other public ports, by name, for links next to the frame.
  defp preview_links(%{preview: %{pack: %PreviewPack{} = pack, ports: ports}}) do
    for name <- pack.ports, name != pack.frame, do: {name, Peon.Ports.url(ports[name])}
  end

  defp preview_links(_state), do: []

  defp broadcast(state, message) do
    Phoenix.PubSub.broadcast(Peon.PubSub, "chat:#{state.id}", message)
    state
  end

  defp broadcast_status(state),
    do: broadcast(state, {:status, Map.delete(info_map(state), :messages)})

  defp touch(state) do
    if state.idle_ref, do: Process.cancel_timer(state.idle_ref)
    %{state | idle_ref: Process.send_after(self(), :idle, @idle_timeout)}
  end

  # The turn is over when opencode reports the session idle after our prompt.
  defp finished?(raw, prompted_at) do
    Enum.any?(raw, &(&1["type"] == "idle" and get_in(&1, ["time", "created"]) >= prompted_at))
  end

  @doc false
  # opencode session messages -> what the chat UI shows.
  def normalize(%{"type" => "user"} = m),
    do: [%{id: m["id"], role: :user, text: m["text"] || get_in(m, ["payload", "text"]) || ""}]

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

  # Preview ports come from the configured range; the registry value marks a
  # port as taken, so two chats never share one.
  defp claim_preview_port(id) do
    used = used_ports()

    free = &(Peon.Ports.browser_safe?(&1) and not MapSet.member?(used, &1))

    case Enum.find(Application.fetch_env!(:peon, :preview_ports), free) do
      nil ->
        {:stop, :no_free_preview_port}

      port ->
        Registry.update_value(@registry, id, fn _ -> port end)
        {:ok, port}
    end
  end

  # A repo chat's preview may need several ports; it holds them as a list.
  defp claim_preview_ports(id, count) do
    Registry.update_value(@registry, id, fn _ -> [] end)
    used = used_ports()

    free =
      Application.fetch_env!(:peon, :preview_ports)
      |> Enum.filter(&(Peon.Ports.browser_safe?(&1) and not MapSet.member?(used, &1)))
      |> Enum.take(count)

    if length(free) == count do
      Registry.update_value(@registry, id, fn _ -> free end)
      {:ok, free}
    else
      {:error, :no_free_preview_port}
    end
  end

  defp used_ports do
    Registry.select(@registry, [{{:_, :_, :"$1"}, [], [:"$1"]}])
    |> List.flatten()
    |> MapSet.new()
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
