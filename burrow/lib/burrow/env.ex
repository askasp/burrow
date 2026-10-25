defmodule Burrow.Env do
  @moduledoc """
  A running environment of a project's app: "staging" or "prod". A long-lived container runs the app in prod mode; the app
  has Totem (a dependency in the template), which dials this process on a
  Unix socket mounted into the container (`TOTEM_LINK`). Nothing runs beside
  the app.

  The env's ref in the project's history is what it should run. When it
  moves:

    * the app runs and is linked: Burrow sends the files that changed (only
      contents Totem lacks), each with the hash it has now. Totem loads them
      hot or warm and watches for new errors, putting the old code back by
      itself if any appear; or it says it needs a restart (mix.exs)
    * otherwise, or when loading failed: the container restarts on the new
      code, which must come up and answer /health without a new error

  A failed deploy records an incident and moves the ref back to the last
  healthy change, which deploys that again. Errors the app logs at any time
  become incidents (`Burrow.Incidents`). Containers outlive Burrow restarts
  and are adopted when they still run the ref's change.

  Broadcasts `{:env, name, info}` on the project's `"envs"` topic.
  """

  use GenServer

  require Logger

  alias Burrow.{BuildCache, Incidents, Projects, Runs, Sandbox, Secrets, Ship, Workspace}
  alias Burrow.Env.Usage
  alias Totem.{Repo, Tree}

  @boot_timeout :timer.minutes(15)
  @revive_after :timer.seconds(10)
  @log_lines 400

  ## API

  @doc "The project's environments, staging first."
  def names(project),
    do: if(Projects.Project.repo?(project), do: [], else: ["staging", "prod"])

  def subscribe(project_id), do: Projects.subscribe(project_id, "envs")

  def start_link({project, name}),
    do:
      GenServer.start_link(__MODULE__, {project, name},
        name: Burrow.Cell.via(project.id, {__MODULE__, name})
      )

  def child_spec({project, name}),
    do: %{id: {__MODULE__, name}, start: {__MODULE__, :start_link, [{project, name}]}}

  @doc "Status for the UI, or nil when the env isn't running."
  def info(project, name), do: call(project, name, :info, nil)

  def logs(project, name), do: call(project, name, :logs, "")

  @doc "Restarts the env's container on what it runs."
  def restart(project, name), do: call(project, name, :restart, {:error, :not_running})

  @doc """
  Looks into the running app for the agent: `"overview"` (status, system
  stats, recent errors) or `"processes"` (top processes; `"sort"`, `"limit"`).
  """
  def runtime(project, name, what, opts \\ %{}),
    do: call(project, name, {:runtime, what, opts}, {:error, :not_running}, 20_000)

  defp call(project, name, msg, default, timeout \\ 5_000) do
    case GenServer.whereis(Burrow.Cell.via(project.id, {__MODULE__, name})) do
      nil -> default
      pid -> GenServer.call(pid, msg, timeout)
    end
  end

  @doc """
  The origins that may show the app in a frame: Burrow's own site, and
  nobody else.
  """
  def frame_ancestors do
    Application.get_env(:burrow, :frame_ancestors, [])
    |> Enum.map(fn url ->
      uri = URI.parse(url)
      default? = {uri.scheme, uri.port} in [{"https", 443}, {"http", 80}]

      "#{uri.scheme}://#{uri.host}" <>
        if(default? or uri.port == nil, do: "", else: ":#{uri.port}")
    end)
    |> Enum.uniq()
    |> Enum.join(" ")
  end

  ## Server

  @impl true
  def init({project, name}) do
    base = Path.join([Projects.dir(project), "envs", name])
    Enum.each(["app", "data"], &File.mkdir_p!(Path.join(base, &1)))
    Projects.subscribe(project.id, "refs")
    Secrets.subscribe(project.id)
    {_previews, ports} = Burrow.Cell.ports(project)

    state = %{
      project: project,
      name: name,
      repo: Projects.repo_dir(project),
      base: base,
      dir: Path.join(base, "app"),
      otp_app: Burrow.Template.otp_app(project.slug),
      container: "peon-env-#{project.slug}-#{name}",
      port: Map.fetch!(ports, name),
      cookie: secret(base, "cookie", 24),
      secret_key_base: secret(base, "secret_key_base", 48),
      app: nil,
      app_status: :stopped,
      sock: Sandbox.socket_dir(Path.join(base, "sock")),
      link: nil,
      linked?: false,
      totem: nil,
      requests: %{},
      next_id: 1,
      deployed: read_deployed(base),
      secrets: nil,
      good: nil,
      deploy: nil,
      queued: nil,
      logs: :queue.new(),
      log_count: 0,
      stats: nil,
      errors: [],
      usage: Usage.new()
    }

    {:ok, listen(state), {:continue, :boot}}
  end

  @impl true
  def handle_continue(:boot, state) do
    case Repo.ref(state.repo, state.name) do
      nil -> {:noreply, state}
      id -> {:noreply, adopt(state, id) || start_deploy(state, id, [])}
    end
  end

  # A container that outlived Burrow, still on this change, its host, its secrets.
  defp adopt(state, id) do
    env = Sandbox.running?(state.container) && Sandbox.env(state.container)
    secrets = Secrets.fingerprint(Secrets.env(state.project.id))

    if ((state.deployed == id and env) && env["PHX_HOST"] == Burrow.Ports.host(state.port)) and
         env["TOTEM_LINK"] != nil and env["PEON_SECRETS"] == secrets do
      Logger.info("#{state.project.slug} #{state.name}: adopting the running container at ##{id}")

      broadcast(%{
        state
        | app: Sandbox.follow_logs(state.container),
          app_status: :running,
          good: id,
          secrets: secrets
      })
    end
  end

  @impl true
  def handle_call(:info, _from, state), do: {:reply, info_map(state), state}

  def handle_call(:logs, _from, state),
    do: {:reply, state.logs |> :queue.to_list() |> Enum.join("\n"), state}

  def handle_call(:restart, _from, %{deploy: nil, deployed: id} = state) when id != nil,
    do: {:reply, :ok, start_deploy(state, id, cold: true)}

  def handle_call(:restart, _from, state), do: {:reply, {:error, :busy}, state}

  def handle_call({:runtime, "overview", _opts}, _from, state),
    do:
      {:reply,
       {:ok,
        Map.take(info_map(state), [:name, :status, :deployed, :good, :stats, :errors, :deploy])},
       state}

  def handle_call({:runtime, "processes", opts}, from, state),
    do:
      {:noreply,
       request(
         state,
         %{"cmd" => "processes", "sort" => opts["sort"], "limit" => opts["limit"] || 15},
         {:call, from}
       )}

  def handle_call({:runtime, what, _opts}, _from, state),
    do: {:reply, {:error, "unknown: #{inspect(what)}"}, state}

  @impl true
  def handle_info({:ref_moved, name, id}, %{name: name} = state) do
    cond do
      state.deploy -> {:noreply, %{state | queued: id}}
      id == state.deployed and state.app_status == :running -> {:noreply, state}
      true -> {:noreply, start_deploy(state, id, [])}
    end
  end

  # New secret values need a container restart.
  def handle_info({:secrets, _}, state), do: {:noreply, maybe_restart_for_secrets(state)}

  def handle_info({port, {:data, data}}, %{app: port} = state) do
    state = append_logs(state, data)
    booted? = state.app_status == :booting and data =~ "Running " and data =~ "Endpoint with"
    {:noreply, if(booted?, do: broadcast(%{state | app_status: :running}), else: state)}
  end

  def handle_info({port, {:exit_status, code}}, %{app: port} = state) do
    state = drop_link(%{state | app: nil, app_status: {:crashed, code}})
    reason = "the app exited with status #{code}:\n\n#{log_tail(state, 40)}"

    if state.deploy do
      {:noreply, fail(state, reason)}
    else
      event = %{
        "fingerprint" => "exit:#{state.name}",
        "message" => "The app exited",
        "text" => reason
      }

      Incidents.report(state.project, state.name, event, state.deployed)
      Process.send_after(self(), :revive, @revive_after)
      {:noreply, broadcast(state)}
    end
  end

  def handle_info(:revive, %{deploy: nil, app_status: {:crashed, _}, deployed: id} = state)
      when id != nil,
      do: {:noreply, start_deploy(state, id, cold: true)}

  def handle_info({:link, conn}, state) do
    state = drop_link(state)
    :ok = :inet.setopts(conn, active: true)
    {:noreply, %{state | link: conn}}
  end

  def handle_info({:tcp, conn, data}, %{link: conn} = state) do
    case Jason.decode(data) do
      {:ok, message} -> {:noreply, link_message(state, message)}
      {:error, _} -> {:noreply, state}
    end
  end

  def handle_info({closed, conn}, %{link: conn} = state) when closed in [:tcp_closed, :tcp_error],
    do: {:noreply, broadcast(drop_link(state))}

  def handle_info({:tcp_error, conn, _}, %{link: conn} = state),
    do: {:noreply, broadcast(drop_link(state))}

  def handle_info({:watched, id}, %{deploy: %{run: %{id: id}, phase: :watching}} = state) do
    if healthy?(state),
      do: {:noreply, succeed(state)},
      else: {:noreply, fail(state, "/health or / did not answer")}
  end

  def handle_info({:boot_timeout, id}, %{deploy: %{run: %{id: id}, phase: :booting}} = state),
    do: {:noreply, fail(state, "the app did not start within #{div(@boot_timeout, 60_000)} min")}

  def handle_info(_msg, state), do: {:noreply, state}

  ## Deploying

  defp start_deploy(state, target, opts) do
    totem? =
      opts[:cold] != true and state.app_status == :running and state.linked? and
        state.totem != nil

    run =
      Runs.start(state.project.id, "deploy", state.name, target,
        status: "deploying",
        mode: if(totem?, do: "hot", else: "cold")
      )

    File.write!(Path.join(state.base, "deployed"), to_string(target))

    state = %{
      state
      | deployed: target,
        queued: nil,
        deploy: %{run: run, target: target, phase: nil, known: known(state)}
    }

    Logger.info("#{state.project.slug} #{state.name}: deploying ##{target} (#{run.mode})")
    broadcast(if totem?, do: send_change(phase(state, :loading)), else: boot(state))
  end

  # Only what Totem lacks: which contents it misses, then those, then the
  # change, each file with the hash it must have now. Paths the history
  # doesn't keep (`.peonignore`, files the app writes) stay as they are.
  defp send_change(%{deploy: deploy, totem: totem} = state) do
    ignore? = Workspace.ignore(state.dir)
    theirs = Map.reject(totem["tree"], fn {path, _} -> ignore?.(path) end)
    changes = Tree.changes(theirs, Repo.tree(state.repo, deploy.target))
    hashes = for {_path, hash} <- changes, hash != :deleted, uniq: true, do: hash

    if changes == [],
      do: loaded(state, %{"mode" => "hot"}),
      else:
        request(
          state,
          %{"cmd" => "missing", "hashes" => hashes},
          {:deploy, :missing, {theirs, changes}}
        )
  end

  defp send_blobs(state, [], change), do: send_apply(state, change)

  defp send_blobs(state, missing, change) do
    contents = Enum.map(missing, &Totem.Commands.content(Repo.blob(state.repo, &1)))
    request(state, %{"cmd" => "blobs", "contents" => contents}, {:deploy, :blobs, change})
  end

  defp send_apply(state, {theirs, changes} = change) do
    files =
      for {path, hash} <- changes do
        file = %{"path" => path, "from" => theirs[path]}
        if hash == :deleted, do: Map.put(file, "deleted", true), else: Map.put(file, "blob", hash)
      end

    payload = %{
      "cmd" => "apply",
      "files" => files,
      "label" => "##{state.deploy.target}",
      "watch" => Application.get_env(:burrow, :health_window, :timer.seconds(30))
    }

    request(state, payload, {:deploy, :apply, change})
  end

  # Totem loaded it and watched it: healthy, or a restart it asked for.
  defp loaded(%{deploy: deploy} = state, result) do
    Workspace.mark(state.repo, state.dir, deploy.target)
    state = append_logs(state, result["output"] || "")
    run = Runs.finish(deploy.run, mode: result["mode"])
    state = %{state | deploy: %{deploy | run: run}}
    if result["mode"] == "cold", do: boot(state), else: succeed(state)
  end

  defp boot(state) do
    Workspace.reset(state.repo, state.dir, state.deploy.target)
    BuildCache.seed(state.dir)
    state = drop_link(state)
    secrets = Secrets.env(state.project.id)

    script =
      Sandbox.unlock_deps() <>
        "mix do deps.get --only prod + compile + assets.setup + assets.deploy + ecto.migrate && " <>
        ~s(exec elixir --sname app --cookie "$PEON_COOKIE" -S mix phx.server)

    app =
      Sandbox.start(state.dir, script,
        project: state.project.slug,
        name: state.container,
        hostname: "app",
        outlive: true,
        label: "burrow.env=#{state.project.slug}",
        env:
          Map.merge(secrets, %{
            "MIX_ENV" => "prod",
            "DATABASE_PATH" => "/data/app.db",
            "SECRET_KEY_BASE" => state.secret_key_base,
            "PHX_HOST" => Burrow.Ports.host(state.port),
            "PORT" => "4000",
            "PEON_COOKIE" => state.cookie,
            "PEON_SECRETS" => Secrets.fingerprint(secrets),
            "FRAME_ANCESTORS" => frame_ancestors(),
            "TOTEM_LINK" => "/peon/sock/p",
            # Burrow's own files in the app's directory are not the app's code.
            "TOTEM_IGNORE" => ".peon/**,.opencode/**"
          }),
        mounts: [{Path.join(state.base, "data"), "/data", :rw}, {state.sock, "/peon/sock", :rw}],
        ports: [{state.port, 4000}]
      )

    Process.send_after(self(), {:boot_timeout, state.deploy.run.id}, @boot_timeout)
    run = Runs.finish(state.deploy.run, mode: "cold")
    deploy = %{state.deploy | run: run, phase: :booting}

    %{
      state
      | app: app,
        app_status: :booting,
        linked?: false,
        deploy: deploy,
        secrets: Secrets.fingerprint(secrets)
    }
  end

  # Loading through Totem didn't work: restart the container instead.
  defp cold(%{deploy: %{phase: :loading}} = state, reason) do
    Logger.warning("#{state.project.slug} #{state.name}: loading failed, restarting: #{reason}")
    boot(state)
  end

  defp cold(state, _reason), do: state

  # Booted and linked: watch it for the health window.
  defp app_ready(%{deploy: %{phase: :booting}} = state) do
    Process.send_after(
      self(),
      {:watched, state.deploy.run.id},
      Application.get_env(:burrow, :health_window, :timer.seconds(30))
    )

    broadcast(phase(%{state | app_status: :running}, :watching))
  end

  defp app_ready(state), do: broadcast(state)

  defp healthy?(state) do
    base = "http://127.0.0.1:#{state.port}"
    opts = [retry: false, receive_timeout: 3_000, redirect: false]

    with {:ok, %{status: 200}} <- Req.get(base <> "/health", opts),
         {:ok, %{status: status}} when status < 500 <- Req.get(base <> "/", opts),
         do: true,
         else: (_ -> false)
  end

  defp succeed(%{deploy: deploy} = state) do
    Runs.finish(deploy.run, status: "healthy")
    Logger.info("#{state.project.slug} #{state.name}: ##{deploy.target} is healthy")
    Incidents.deployed(state.project, state.name, deploy.target)
    Ship.healthy(state.project, state.name, deploy.target)
    state = broadcast(%{state | deploy: nil, good: deploy.target})

    if state.queued && state.queued != deploy.target,
      do: start_deploy(state, state.queued, []),
      else: maybe_restart_for_secrets(state)
  end

  defp fail(%{deploy: deploy} = state, reason) do
    Runs.finish(deploy.run, status: "failed", detail: reason)

    Logger.warning(
      "#{state.project.slug} #{state.name}: deploying ##{deploy.target} failed: #{reason}"
    )

    event = %{
      "fingerprint" => "deploy:#{state.name}:#{deploy.target}",
      "kind" => "deploy",
      "message" => "Deploying ##{deploy.target} to #{state.name} failed",
      "text" => reason
    }

    Incidents.report(state.project, state.name, event, deploy.target)
    state = %{state | deploy: nil}

    cond do
      state.queued && state.queued != deploy.target ->
        start_deploy(state, state.queued, [])

      state.good in [nil, deploy.target] ->
        broadcast(state)

      true ->
        # Back to the last healthy change; the ref moving deploys it.
        with :ok <- Repo.move_ref(state.repo, state.name, state.good, deploy.target),
             do:
               Projects.broadcast(state.project.id, "refs", {:ref_moved, state.name, state.good})

        broadcast(state)
    end
  end

  defp maybe_restart_for_secrets(%{deploy: nil, deployed: id, app: app} = state)
       when id != nil and app != nil do
    if state.secrets == Secrets.fingerprint(Secrets.env(state.project.id)),
      do: state,
      else: start_deploy(state, id, cold: true)
  end

  defp maybe_restart_for_secrets(state), do: state

  # Incidents already open: a new error among them doesn't fail a deploy.
  defp known(state),
    do:
      for(
        i <- Incidents.list(state.project.id, 100),
        i.status != "resolved",
        into: MapSet.new(),
        do: i.fingerprint
      )

  defp phase(%{deploy: deploy} = state, phase), do: %{state | deploy: %{deploy | phase: phase}}

  ## Totem's link

  # The socket Totem dials is in a directory mounted into the container: the
  # directory, not the file, so a socket made again after a restart is the
  # one the container sees.
  defp listen(state) do
    File.mkdir_p!(state.sock)
    path = Path.join(state.sock, "p")
    File.rm(path)

    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, ifaddr: {:local, path}, packet: 4, active: false])

    env = self()
    Task.start_link(fn -> accept(listener, env) end)
    state
  end

  defp accept(listener, env) do
    with {:ok, conn} <- :gen_tcp.accept(listener) do
      :ok = :gen_tcp.controlling_process(conn, env)
      send(env, {:link, conn})
      accept(listener, env)
    end
  end

  defp drop_link(%{link: nil} = state), do: state

  defp drop_link(state) do
    :gen_tcp.close(state.link)

    Enum.reduce(state.requests, %{state | link: nil, linked?: false, requests: %{}}, fn {_id, tag},
                                                                                        state ->
      reply_to(state, tag, %{"ok" => false, "error" => "Totem disconnected"})
    end)
  end

  defp link_message(state, %{"event" => "connected"} = hello) do
    state = %{state | linked?: true, totem: hello["current"]}
    if hello["ready"], do: app_ready(state), else: broadcast(state)
  end

  defp link_message(state, %{"event" => "ready"}), do: app_ready(state)

  defp link_message(state, %{"event" => "stats", "stats" => stats}) do
    usage = Usage.add(state.usage, stats["usage"] || %{}, System.os_time(:second))
    broadcast(%{state | stats: Map.delete(stats, "usage"), usage: usage})
  end

  defp link_message(state, %{"event" => "error"} = error) do
    error = Map.put(error, "at", DateTime.utc_now(:second))

    state = %{
      state
      | errors: Enum.take([error | state.errors], 20),
        usage: Usage.error(state.usage, System.os_time(:second))
    }

    Incidents.report(state.project, state.name, error, state.deployed)

    case state.deploy do
      %{phase: :watching, known: known} ->
        if MapSet.member?(known, error["fingerprint"]),
          do: broadcast(state),
          else:
            fail(state, "it logged a new error:\n\n#{error["message"]}\n#{error["stacktrace"]}")

      _ ->
        broadcast(state)
    end
  end

  defp link_message(state, %{"reply" => id} = reply) do
    {tag, requests} = Map.pop(state.requests, id)
    reply_to(%{state | requests: requests}, tag, reply)
  end

  defp link_message(state, _message), do: state

  defp reply_to(state, {:deploy, step, change}, %{"ok" => true, "result" => result}) do
    case step do
      :missing -> send_blobs(state, result["missing"], change)
      :blobs -> send_apply(state, change)
      :apply -> loaded(state, result)
    end
  end

  # Totem put the old code back after a new error: a failed deploy. Anything
  # else (a file changed under it, a compile error): restart instead.
  defp reply_to(state, {:deploy, _step, _change}, %{"error" => %{"error" => "reverted"} = error}) do
    errors =
      Enum.map_join(error["errors"] || [], "\n\n", &"#{&1["message"]}\n#{&1["stacktrace"]}")

    fail(state, "it logged a new error, so Totem put the previous code back:\n\n" <> errors)
  end

  defp reply_to(state, {:deploy, _step, _change}, reply) do
    output =
      case reply["error"] do
        %{"output" => output} -> output
        error -> inspect(error)
      end

    state
    |> append_logs(output)
    |> cold("loading failed:\n\n" <> String.slice(output, -2000, 2000))
  end

  defp reply_to(state, {:call, from}, %{"ok" => true, "result" => result}) do
    GenServer.reply(from, {:ok, result})
    state
  end

  defp reply_to(state, {:call, from}, reply) do
    GenServer.reply(from, {:error, reply["error"]})
    state
  end

  defp reply_to(state, nil, _reply), do: state

  defp request(%{link: nil} = state, _payload, tag),
    do: reply_to(state, tag, %{"ok" => false, "error" => "Totem is not connected"})

  defp request(state, payload, tag) do
    id = state.next_id
    :gen_tcp.send(state.link, Jason.encode!(Map.put(payload, "id", id)))
    %{state | next_id: id + 1, requests: Map.put(state.requests, id, tag)}
  end

  ## Helpers

  defp info_map(state) do
    %{
      name: state.name,
      url: Burrow.Ports.url(state.port),
      status: status(state),
      deployed: state.deployed,
      good: state.good,
      deploy:
        state.deploy &&
          %{target: state.deploy.target, mode: state.deploy.run.mode, phase: state.deploy.phase},
      stats: state.stats,
      usage: Usage.summary(state.usage, System.os_time(:second)),
      errors: Enum.take(state.errors, 10),
      attach:
        "docker exec -it #{state.container} iex --sname debug --cookie #{state.cookie} --remsh app@app"
    }
  end

  defp status(%{deploy: %{phase: phase}}) when phase != nil, do: phase
  defp status(%{app_status: :running, linked?: true}), do: :running
  defp status(%{app_status: :running}), do: :attaching
  defp status(%{app_status: status}), do: status

  defp broadcast(state) do
    Projects.broadcast(state.project.id, "envs", {:env, state.name, info_map(state)})
    state
  end

  defp read_deployed(base) do
    case File.read(Path.join(base, "deployed")) do
      {:ok, id} -> String.to_integer(String.trim(id))
      _ -> nil
    end
  end

  defp secret(base, name, bytes) do
    path = Path.join(base, name)

    with {:error, _} <- File.read(path) do
      secret = :crypto.strong_rand_bytes(bytes) |> Base.url_encode64(padding: false)
      File.write!(path, secret)
      File.chmod!(path, 0o600)
      secret
    else
      {:ok, secret} -> secret
    end
  end

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

  defp log_tail(state, n), do: state.logs |> :queue.to_list() |> Enum.take(-n) |> Enum.join("\n")
end
