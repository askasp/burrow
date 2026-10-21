defmodule Peon.Env do
  @moduledoc """
  A running environment of the app, "staging" or "prod": a long-lived
  container running the app in prod mode. The app has Totem (`totem/`, a
  dependency in the template), which dials this process on a Unix socket
  mounted into the container (`TOTEM_LINK`); nothing runs beside the app.

  The env's ref is the desired state. When it moves, the env deploys it:

    * through Totem when the app runs and is linked: Peon sends the files
      that changed (only contents Totem doesn't have), and Totem loads them
      hot (processes, sockets and LiveView sessions survive), warm (config
      or application.ex: the app restarts inside its node) or tells Peon it
      needs a restart. Totem runs new migrations and rebuilds assets itself.
    * cold (container restart) when Totem asks for it (mix.exs), the app
      isn't running or linked, or loading failed

  Then it watches a health window (`:health_window`): /health and / must
  answer and the app must not log an error that isn't already an open
  incident. A failed window records an incident and moves the ref back to the
  last healthy changeset, which redeploys it. Migrations are additive (policy),
  so rolling code back never needs a database rollback. Prod moves when a
  human promotes a healthy staging changeset, or by itself when a human set
  the project's `"auto_promote"` to true.

  Errors the app logs at any time arrive over the link and become incidents
  (`Peon.Incidents`). The container outlives Peon restarts: a new Peon adopts
  it when it still runs the ref's changeset, and Totem dials the new Peon.
  An app without Totem still deploys, by restarting, and is watched by its
  /health alone.

  Totem also reports the app's usage: requests, LiveView sessions and
  visitors (`Peon.Env.Usage`).

  Broadcasts `{:env, name, info}` on topic `"envs"`.
  """

  use GenServer

  require Logger

  import Ecto.Query

  alias Peon.{Code, Incidents, Project, Repo, Sandbox, Secrets, Store, Template, Workspace}
  alias Peon.Env.{Deploy, Usage}
  alias Peon.Incidents.Incident
  alias Totem.Tree

  @boot_timeout :timer.minutes(15)
  @health_every :timer.seconds(5)
  @revive_after :timer.seconds(10)
  @log_lines 400
  # How long a booted app may take to dial in before it counts as one without Totem.
  @link_wait :timer.seconds(20)

  ## API

  @doc "The configured environments, staging first."
  def names(instance \\ Peon.Instance.current!()),
    do: Enum.filter(["staging", "prod"], &Map.has_key?(instance.env_ports, &1))

  def child_spec({instance, name}),
    do: %{id: {__MODULE__, name}, start: {__MODULE__, :start_link, [instance, name]}}

  def start_link(instance, name),
    do:
      GenServer.start_link(__MODULE__, {instance, name},
        name: Peon.Instance.via(instance, {__MODULE__, name})
      )

  def subscribe, do: Peon.Instance.subscribe("envs")

  @doc "Status for the UI, or nil when the env isn't running."
  def info(name), do: call(name, :info, nil)

  def logs(name), do: call(name, :logs, "")

  @doc "Restarts the env's container with what is deployed."
  def restart(name), do: call(name, :restart, {:error, :not_running})

  @doc """
  Looks into the running app for the agent: `"overview"` (status, system
  stats, recent errors) or `"processes"` (top processes; opts `"sort"`,
  `"limit"`). Returns `{:ok, map | list}` or `{:error, reason}`.
  """
  def runtime(name, what, opts \\ %{}),
    do: call(name, {:runtime, what, opts}, {:error, :not_running}, 20_000)

  def failed_deploy?(env, changeset_id) do
    Repo.exists?(
      from d in Deploy,
        where: d.env == ^env and d.changeset_id == ^changeset_id and d.status == "failed"
    )
  end

  def deploys(env, limit \\ 10),
    do: Repo.all(from d in Deploy, where: d.env == ^env, order_by: [desc: d.id], limit: ^limit)

  defp call(name, msg, default, timeout \\ 5_000) do
    case Peon.Instance.whereis({__MODULE__, name}) do
      nil -> default
      pid -> GenServer.call(pid, msg, timeout)
    end
  end

  ## Server

  @impl true
  def init({instance, name}) do
    Peon.Instance.put(instance)
    slug = Peon.Instance.fetch!(:slug)
    otp_app = Template.otp_app(slug)
    base = Path.join([Peon.Instance.fetch!(:data_dir), "envs", name])
    Enum.each(["app", "data"], &File.mkdir_p!(Path.join(base, &1)))
    Store.subscribe()
    Secrets.subscribe()

    state = %{
      name: name,
      slug: slug,
      base: base,
      dir: Path.join(base, "app"),
      otp_app: otp_app,
      endpoint: Macro.camelize(otp_app) <> "Web.Endpoint",
      container: "peon-env-#{slug}-#{name}",
      port: Map.fetch!(Peon.Instance.fetch!(:env_ports), name),
      cookie: secret(base, "cookie", 24),
      secret_key_base: secret(base, "secret_key_base", 48),
      app: nil,
      app_status: :stopped,
      # Totem's connection from inside the app, on the socket in `sock`
      sock: sock_dir(base),
      listener: nil,
      link: nil,
      linked?: false,
      # The app runs without Totem: deploys restart it
      linkless?: false,
      # Totem's current version, %{"version" => n, "tree" => tree}
      totem: nil,
      requests: %{},
      next_id: 1,
      deployed: read_deployed(base),
      # Secrets.fingerprint/0 of the values the container was started with
      secrets: nil,
      good: nil,
      deploy: nil,
      queued: nil,
      rollback_to: nil,
      logs: :queue.new(),
      log_count: 0,
      stats: nil,
      errors: [],
      usage: Peon.Env.Usage.new()
    }

    {:ok, listen(state), {:continue, :boot}}
  end

  @impl true
  def handle_continue(:boot, state) do
    case Code.ref(state.name) do
      nil ->
        {:noreply, state}

      %{changeset_id: id} ->
        # Not when its public address changed: the app only accepts its own host.
        # Nor when the secrets changed: env vars are set when the container starts.
        # Containers from before secrets existed have none.
        env = Sandbox.running?(state.container) && Sandbox.env(state.container)
        secrets = env && (env["PEON_SECRETS"] || Secrets.fingerprint(%{}))

        # Nor one started before Totem was (with Peon's old probe instead).
        stale =
          cond do
            state.deployed != id -> "it runs ##{inspect(state.deployed)}"
            env == false -> "it isn't running"
            env["PHX_HOST"] != Peon.Ports.host(state.port) -> "its host changed"
            env["TOTEM_LINK"] == nil -> "it has no Totem link"
            secrets != Secrets.fingerprint() -> "its secrets changed"
            true -> nil
          end

        if stale == nil do
          Logger.info("#{state.name}: adopting the running container at ##{id}")
          app = Sandbox.follow_logs(state.container)

          state = %{
            state
            | app: app,
              app_status: :running,
              good: id,
              secrets: secrets
          }

          {:noreply, broadcast(state)}
        else
          Logger.info("#{state.name}: not adopting the container, #{stale}")
          {:noreply, start_deploy(state, id, [])}
        end
    end
  end

  @impl true
  def handle_call(:info, _from, state), do: {:reply, info_map(state), state}

  def handle_call(:logs, _from, state),
    do: {:reply, state.logs |> :queue.to_list() |> Enum.join("\n"), state}

  def handle_call(:restart, _from, %{deploy: nil, deployed: id} = state) when id != nil,
    do: {:reply, :ok, start_deploy(state, id, cold: true)}

  def handle_call(:restart, _from, state), do: {:reply, {:error, :busy}, state}

  def handle_call({:runtime, "overview", _opts}, _from, state) do
    overview =
      state
      |> info_map()
      |> Map.take([:name, :status, :deployed, :good, :stats, :errors])
      |> Map.put(:deploy, state.deploy && Map.take(state.deploy, [:target, :mode, :phase]))

    {:reply, {:ok, overview}, state}
  end

  def handle_call({:runtime, "processes", opts}, from, state) do
    payload = %{"cmd" => "processes", "sort" => opts["sort"], "limit" => opts["limit"] || 15}
    {:noreply, request(state, payload, {:call, from})}
  end

  def handle_call({:runtime, what, _opts}, _from, state),
    do: {:reply, {:error, "unknown: #{inspect(what)}"}, state}

  @impl true
  def handle_info({:ref_moved, name, id, _version}, %{name: name} = state) do
    cond do
      state.deploy -> {:noreply, %{state | queued: id}}
      id == state.deployed and state.app_status == :running -> {:noreply, state}
      true -> {:noreply, start_deploy(state, id, rollback: id == state.rollback_to)}
    end
  end

  # New secret values need a container restart; a deploy in flight picks them
  # up when it ends (`succeed/1`).
  def handle_info({:secrets, _list}, state), do: {:noreply, maybe_restart_for_secrets(state)}

  # The app container's output (from `docker run`, or `docker logs` when adopted).
  def handle_info({port, {:data, data}}, %{app: port} = state) do
    state = append_logs(state, data)

    if state.app_status == :booting and data =~ "Running " and data =~ "Endpoint with" do
      if state.deploy,
        do: Process.send_after(self(), {:link_wait, state.deploy.record.id}, @link_wait)

      {:noreply, broadcast(%{state | app_status: :running})}
    else
      {:noreply, state}
    end
  end

  def handle_info({port, {:exit_status, code}}, %{app: port} = state) do
    state = drop_link(%{state | app: nil, app_status: {:crashed, code}})
    reason = "the app exited with status #{code}:\n\n#{log_tail(state, 40)}"

    if state.deploy do
      {:noreply, fail(state, reason)}
    else
      Incidents.report(
        state.name,
        %{"fingerprint" => "exit:#{state.name}", "message" => "The app exited", "text" => reason},
        state.deployed
      )

      Process.send_after(self(), :revive, @revive_after)
      {:noreply, broadcast(state)}
    end
  end

  def handle_info(:revive, %{deploy: nil, app_status: {:crashed, _}, deployed: id} = state)
      when id != nil,
      do: {:noreply, start_deploy(state, id, [])}

  def handle_info(:revive, state), do: {:noreply, state}

  # Totem dialed in (`accept/2`); a new connection replaces an old one.
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

  def handle_info({:tcp_closed, conn}, %{link: conn} = state),
    do: {:noreply, broadcast(drop_link(state))}

  def handle_info({:tcp_error, conn, _reason}, %{link: conn} = state),
    do: {:noreply, broadcast(drop_link(state))}

  # Up, and no Totem dialed in: an app without it, watched by /health alone.
  def handle_info(
        {:link_wait, id},
        %{deploy: %{record: %{id: id}, phase: :booting}, linked?: false} = state
      ) do
    Logger.info("#{state.name}: the app has no Totem link; deploys restart it")
    {:noreply, watch(%{state | linkless?: true})}
  end

  def handle_info({:health, id}, %{deploy: %{record: %{id: id}, phase: :watching}} = state),
    do: {:noreply, health_check(state)}

  def handle_info({:boot_timeout, id}, %{deploy: %{record: %{id: id}, phase: :booting}} = state),
    do: {:noreply, fail(state, "the app did not start within #{div(@boot_timeout, 60_000)} min")}

  def handle_info(_msg, state), do: {:noreply, state}

  @doc """
  The origins that may show the app in a frame: the host's site, where the
  workspace is (`:frame_ancestors`, URLs), and nobody else.
  """
  def frame_ancestors do
    Application.get_env(:peon, :frame_ancestors, [])
    |> Enum.map(&origin/1)
    |> Enum.uniq()
    |> Enum.join(" ")
  end

  defp origin(url) do
    uri = URI.parse(url)
    default? = {uri.scheme, uri.port} in [{"https", 443}, {"http", 80}]
    "#{uri.scheme}://#{uri.host}" <> if(default? or uri.port == nil, do: "", else: ":#{uri.port}")
  end

  ## Deploying

  defp start_deploy(state, target, opts) do
    # Through Totem when the running app has it: it loads the change in place
    # (hot or warm), or says that it needs a restart.
    totem? =
      opts[:cold] != true and state.app_status == :running and state.linked? and state.totem != nil

    mode = if totem?, do: "hot", else: "cold"

    record =
      Repo.insert!(%Deploy{
        env: state.name,
        changeset_id: target,
        from_id: state.deployed,
        mode: mode,
        status: "deploying",
        detail: opts[:detail]
      })

    File.write!(Path.join(state.base, "deployed"), to_string(target))

    deploy = %{
      record: record,
      target: target,
      mode: mode,
      rollback?: opts[:rollback] == true,
      phase: nil,
      until: nil,
      known: MapSet.new(),
      health_failures: 0
    }

    state = %{state | deployed: target, deploy: deploy, queued: nil, rollback_to: nil}
    Logger.info("#{state.name}: deploying ##{target} (#{mode})")
    state = if totem?, do: send_change(phase(state, :loading)), else: boot(state)
    broadcast(state)
  end

  # Only what Totem doesn't have: which contents it misses, then those, then
  # the change itself (`reply_to/3` takes it from one step to the next).
  # Paths Peon doesn't keep (`.peonignore`, files the app writes) stay as they are.
  defp send_change(%{deploy: deploy, totem: totem} = state) do
    ignore? = Peon.Ignore.matcher(state.dir)
    theirs = Map.reject(totem["tree"], fn {path, _} -> ignore?.(path) end)
    changes = Tree.changes(theirs, Code.tree(deploy.target))
    hashes = for {_path, hash} <- changes, hash != :deleted, uniq: true, do: hash

    if changes == [],
      do: loaded(state, %{"mode" => "hot", "version" => totem["version"]}, []),
      else:
        request(state, %{"cmd" => "missing", "hashes" => hashes}, {:deploy, :missing, changes})
  end

  defp send_blobs(state, [], changes), do: send_apply(state, changes)

  defp send_blobs(state, missing, changes) do
    contents = Enum.map(missing, &Totem.Commands.content(Code.blob(&1)))
    request(state, %{"cmd" => "blobs", "contents" => contents}, {:deploy, :blobs, changes})
  end

  defp send_apply(state, changes) do
    files =
      for {path, hash} <- changes do
        if hash == :deleted,
          do: %{"path" => path, "deleted" => true},
          else: %{"path" => path, "blob" => hash}
      end

    payload = %{
      "cmd" => "apply",
      "base" => state.totem["version"],
      "files" => files,
      "source" => "peon ##{state.deploy.target}"
    }

    request(state, payload, {:deploy, :apply, changes})
  end

  # Totem has the change: watch it, or restart the container when Totem asks.
  defp loaded(%{deploy: deploy} = state, result, changes) do
    tree = Tree.apply_changes(state.totem["tree"], changes)
    state = %{state | totem: %{"version" => result["version"], "tree" => tree}}
    Workspace.mark(state.dir, deploy.target)
    state = append_logs(state, result["output"] || "")
    mode = if result["mode"] == "cold", do: "cold", else: result["mode"]
    record = Repo.update!(Ecto.Changeset.change(deploy.record, mode: mode))
    state = %{state | deploy: %{deploy | record: record, mode: mode}}

    if mode == "cold", do: boot(state), else: watch(state)
  end

  defp boot(state) do
    Workspace.reset(state.dir, state.deploy.target)
    state = drop_link(state)

    secrets = Secrets.env()

    # Totem comes in with the app (a dependency), and dials TOTEM_LINK.
    script =
      Sandbox.unlock_deps() <>
        "mix deps.get --only prod && mix compile && mix assets.setup && mix assets.deploy && " <>
        "mix ecto.migrate && " <>
        ~s(exec elixir --sname app --cookie "$PEON_COOKIE" -S mix phx.server)

    app =
      Sandbox.start(state.dir, script,
        name: state.container,
        hostname: "app",
        outlive: true,
        label: "peon.env=#{state.slug}",
        env:
          Map.merge(secrets, %{
            "MIX_ENV" => "prod",
            "DATABASE_PATH" => "/data/app.db",
            "SECRET_KEY_BASE" => state.secret_key_base,
            "PHX_HOST" => Peon.Ports.host(state.port),
            "PORT" => "4000",
            "PEON_COOKIE" => state.cookie,
            "PEON_SECRETS" => Secrets.fingerprint(secrets),
            "FRAME_ANCESTORS" => frame_ancestors(),
            "TOTEM_LINK" => "/peon/sock/p",
            # Peon's own files in the app's directory are not the app's code.
            "TOTEM_IGNORE" => ".peon/**,.opencode/**"
          }),
        mounts: [
          {Path.join(state.base, "data"), "/data", :rw},
          {state.sock, "/peon/sock", :rw}
        ],
        ports: [{state.port, 4000}]
      )

    Process.send_after(self(), {:boot_timeout, state.deploy.record.id}, @boot_timeout)

    phase(
      %{
        state
        | app: app,
          app_status: :booting,
          linked?: false,
          linkless?: false,
          secrets: Secrets.fingerprint(secrets)
      },
      :booting
    )
  end

  # Hot loading didn't work; restart the container instead.
  defp hot_failed(%{deploy: %{phase: :loading} = deploy} = state, reason) do
    Logger.warning("#{state.name}: loading through Totem failed, restarting: #{reason}")
    record = Repo.update!(Ecto.Changeset.change(deploy.record, mode: "cold", detail: reason))
    boot(%{state | deploy: %{deploy | record: record, mode: "cold"}})
  end

  defp hot_failed(state, _reason), do: state

  defp watch(%{deploy: deploy} = state) do
    known =
      Repo.all(
        from i in Incident,
          where: i.env == ^state.name and i.status != "resolved",
          select: i.fingerprint
      )

    window = Application.get_env(:peon, :health_window, :timer.seconds(60))
    record = Repo.update!(Ecto.Changeset.change(deploy.record, status: "watching"))
    Process.send_after(self(), {:health, record.id}, 1_000)

    deploy = %{
      deploy
      | record: record,
        known: MapSet.new(known),
        until: System.monotonic_time(:millisecond) + window
    }

    broadcast(phase(%{state | deploy: deploy}, :watching))
  end

  defp health_check(%{deploy: deploy} = state) do
    failures = if healthy?(state), do: 0, else: deploy.health_failures + 1
    state = %{state | deploy: %{deploy | health_failures: failures}}

    cond do
      failures >= 2 ->
        fail(state, "/health or / did not answer twice in a row")

      System.monotonic_time(:millisecond) >= deploy.until ->
        succeed(state)

      true ->
        Process.send_after(self(), {:health, deploy.record.id}, @health_every)
        state
    end
  end

  defp healthy?(state) do
    base = "http://127.0.0.1:#{state.port}"
    opts = [retry: false, receive_timeout: 3_000, redirect: false]

    with {:ok, %{status: 200}} <- Req.get(base <> "/health", opts),
         {:ok, %{status: status}} when status < 500 <- Req.get(base <> "/", opts) do
      true
    else
      _ -> false
    end
  end

  defp succeed(%{deploy: deploy} = state) do
    Repo.update!(Ecto.Changeset.change(deploy.record, status: "healthy"))
    Logger.info("#{state.name}: ##{deploy.target} is healthy")
    Incidents.deployed(state.name, deploy.target)
    state = broadcast(%{state | deploy: nil, good: deploy.target})
    if state.name == "staging", do: promote(deploy.target)

    if state.queued && state.queued != deploy.target,
      do: start_deploy(state, state.queued, []),
      else: maybe_restart_for_secrets(state)
  end

  defp maybe_restart_for_secrets(%{deploy: nil, deployed: id, app: app} = state)
       when id != nil and app != nil do
    if state.secrets == Secrets.fingerprint(),
      do: state,
      else: start_deploy(state, id, cold: true, detail: "secrets changed")
  end

  defp maybe_restart_for_secrets(state), do: state

  defp fail(%{deploy: deploy} = state, reason) do
    Repo.update!(Ecto.Changeset.change(deploy.record, status: "failed", detail: reason))
    Logger.warning("#{state.name}: deploying ##{deploy.target} failed: #{reason}")

    Incidents.report(
      state.name,
      %{
        "fingerprint" => "deploy:#{state.name}:#{deploy.target}",
        "kind" => "deploy",
        "message" => "Deploying ##{deploy.target} to #{state.name} failed",
        "text" => reason <> "\n\n" <> describe_range(state.good, deploy.target)
      },
      deploy.target
    )

    state = %{state | deploy: nil}

    cond do
      # Something newer is wanted already, perhaps the fix: deploy that instead.
      state.queued && state.queued != deploy.target ->
        start_deploy(state, state.queued, [])

      deploy.rollback? or state.good in [nil, deploy.target] ->
        broadcast(state)

      true ->
        rollback(state, state.good)
    end
  end

  defp rollback(state, to) do
    ref = Code.ref(state.name)

    case Store.move_ref(state.name, to, ref.version, "peon", approved_by: "rollback") do
      {:ok, _} ->
        broadcast(%{state | rollback_to: to})

      error ->
        Logger.error("#{state.name}: could not roll back to ##{to}: #{inspect(error)}")
        broadcast(state)
    end
  end

  # Healthy on staging moves prod too when a human turned that on for the
  # project ("auto_promote": true), unless prod already failed with it.
  defp promote(id) do
    prod = Code.ref("prod")

    cond do
      "prod" not in names() ->
        :ok

      Project.settings()["auto_promote"] != true ->
        :ok

      prod && prod.changeset_id == id ->
        :ok

      failed_deploy?("prod", id) ->
        :ok

      true ->
        # The approval is the human who turned auto-promote on.
        approved_by = "auto-promote, turned on by #{Project.settings()["auto_promote_by"]}"

        Store.move_ref("prod", id, (prod && prod.version) || 0, "peon", approved_by: approved_by)
    end
  end

  # The changesets a deploy brought in, for whoever fixes it.
  defp describe_range(from, to) do
    lines =
      Stream.unfold(to, fn
        nil ->
          nil

        ^from ->
          nil

        id ->
          case Code.changeset(id) do
            {:ok, cs} -> {cs, cs.parent_id}
            _ -> nil
          end
      end)
      |> Enum.take(20)
      |> Enum.map_join("\n", &"- ##{&1.id} #{&1.intent}")

    "Changesets in this deploy:\n" <> lines
  end

  defp phase(%{deploy: deploy} = state, phase), do: %{state | deploy: %{deploy | phase: phase}}

  ## Totem's link

  # The socket Totem dials, in a directory mounted into the container: the
  # directory, not the file, so a socket made again after a Peon restart is
  # the one the container sees.
  defp sock_dir(base), do: Peon.Instance.socket_dir(Path.join(base, "sock"))

  defp listen(state) do
    File.mkdir_p!(state.sock)
    path = Path.join(state.sock, "p")
    File.rm(path)

    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, ifaddr: {:local, path}, packet: 4, active: false])

    env = self()
    Task.start_link(fn -> accept(listener, env) end)
    %{state | listener: listener}
  end

  defp accept(listener, env) do
    case :gen_tcp.accept(listener) do
      {:ok, conn} ->
        :ok = :gen_tcp.controlling_process(conn, env)
        send(env, {:link, conn})
        accept(listener, env)

      {:error, :closed} ->
        :ok
    end
  end

  defp drop_link(%{link: nil} = state), do: state

  defp drop_link(state) do
    :gen_tcp.close(state.link)
    fail_requests(%{state | link: nil, linked?: false})
  end

  defp link_message(state, %{"event" => "connected"} = hello) do
    state = %{state | linked?: true, linkless?: false, totem: hello["current"]}
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

    fingerprint = Incidents.fingerprint(error)

    case state.deploy do
      %{phase: :watching, known: known} ->
        if MapSet.member?(known, fingerprint) do
          Incidents.report(state.name, error, state.deployed)
          broadcast(state)
        else
          fail(state, "it logged a new error:\n\n#{error["message"]}\n#{error["stacktrace"]}")
        end

      _ ->
        Incidents.report(state.name, error, state.deployed)
        broadcast(state)
    end
  end

  defp link_message(state, %{"reply" => id} = reply) do
    {tag, requests} = Map.pop(state.requests, id)
    reply_to(%{state | requests: requests}, tag, reply)
  end

  defp link_message(state, _message), do: state

  # The app has started (with Totem in it): a boot is done.
  defp app_ready(state) do
    state = if state.app_status == :booting, do: %{state | app_status: :running}, else: state

    case state.deploy do
      %{phase: :booting} -> watch(state)
      _ -> broadcast(state)
    end
  end

  defp reply_to(state, {:deploy, step, changes}, %{"ok" => true, "result" => result}) do
    case step do
      :missing -> send_blobs(state, result["missing"], changes)
      :blobs -> send_apply(state, changes)
      :apply -> loaded(state, result, changes)
    end
  end

  defp reply_to(state, {:deploy, _step, _changes}, reply) do
    output =
      case reply["error"] do
        %{"error" => "load_failed", "output" => output} -> output
        %{"error" => "conflict"} -> "the app's files changed since Peon last saw them"
        error -> inspect(error)
      end

    state
    |> append_logs(output)
    |> hot_failed("loading through Totem failed:\n\n" <> String.slice(output, -2000, 2000))
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

  defp fail_requests(state) do
    Enum.reduce(state.requests, %{state | requests: %{}}, fn {_id, tag}, state ->
      reply_to(state, tag, %{"ok" => false, "error" => "Totem disconnected"})
    end)
  end

  ## Helpers

  defp info_map(state) do
    %{
      name: state.name,
      url: Peon.Ports.url(state.port),
      status: status(state),
      deployed: state.deployed,
      good: state.good,
      deploy: state.deploy && Map.take(state.deploy, [:target, :mode, :phase]),
      stats: state.stats,
      usage: Usage.summary(state.usage, System.os_time(:second)),
      errors: Enum.take(state.errors, 10),
      attach:
        "docker exec -it #{state.container} iex --sname debug --cookie #{state.cookie} --remsh app@app"
    }
  end

  defp status(%{deploy: %{phase: phase}}), do: phase
  defp status(%{app_status: :running, linked?: true}), do: :running
  defp status(%{app_status: :running, linkless?: true}), do: :running
  defp status(%{app_status: :running}), do: :attaching
  defp status(%{app_status: status}), do: status

  defp broadcast(state) do
    Peon.Instance.broadcast("envs", {:env, state.name, info_map(state)})
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

    case File.read(path) do
      {:ok, secret} ->
        secret

      _ ->
        secret = :crypto.strong_rand_bytes(bytes) |> Base.url_encode64(padding: false)
        File.write!(path, secret)
        File.chmod!(path, 0o600)
        secret
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
