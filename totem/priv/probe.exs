# Peon's probe. Peon loads it into a deployed app's own node when the
# environment's container starts (`elixir -r /peon/probe.exs -S mix
# phx.server`), so nothing runs beside the app and the app's code stays
# untouched. Once the app's endpoint is up it forwards errors with their
# stacktraces (a :logger handler), counts requests and visitors (a :telemetry
# handler), and dials Peon on the Unix socket Peon mounts into the container
# (PEON_PROBE_SOCKET). Over it, one JSON object per frame (4-byte length):
#
#   Peon -> probe   {"id": n, "cmd": "deploy" | "stats" | "processes" | "upgrade", ...}
#   probe -> Peon   {"reply": n, "ok": true, "result": ...}
#                   {"event": "connected" | "error" | "stats", ...}
#
# "connected" carries the probe's version; a Peon with a newer probe sends
# it ("upgrade") and the probe reloads itself. When the socket closes (Peon
# restarted) the probe dials again.

defmodule PeonProbe do
  @moduledoc false

  @version 1
  @error_cap 100

  def version, do: @version

  @doc "Starts the probe for the app in PEON_OTP_APP with endpoint PEON_ENDPOINT."
  def start do
    with socket when is_binary(socket) <- System.get_env("PEON_PROBE_SOCKET"),
         otp_app when is_binary(otp_app) <- System.get_env("PEON_OTP_APP"),
         endpoint when is_binary(endpoint) <- System.get_env("PEON_ENDPOINT") do
      state = %{
        socket: socket,
        otp_app: String.to_atom(otp_app),
        endpoint: Module.concat([endpoint]),
        conn: nil,
        errors: 0
      }

      pid = spawn(fn -> await_app(state) end)
      Process.register(pid, __MODULE__)
      :ok
    end
  end

  # Waits for the app's endpoint, then installs the handlers and dials Peon.
  defp await_app(state) do
    if Process.whereis(state.endpoint) do
      install(state.otp_app)
      :timer.send_interval(10_000, :stats)
      :timer.send_interval(10_000, :reset_cap)
      PeonProbe.dial(state)
    else
      Process.sleep(500)
      await_app(state)
    end
  end

  @doc false
  # Fully qualified calls from here on, so an upgrade takes over at once.
  def dial(state) do
    case :gen_tcp.connect({:local, state.socket}, 0, [:binary, packet: 4, active: true]) do
      {:ok, conn} ->
        state = %{state | conn: conn}
        emit(state, %{"event" => "connected", "version" => @version, "node" => node()})
        send(self(), :stats)
        PeonProbe.loop(state)

      {:error, _} ->
        Process.sleep(2_000)
        PeonProbe.dial(state)
    end
  end

  @doc false
  def loop(state) do
    receive do
      {:tcp, conn, data} when conn == state.conn ->
        request = JSON.decode!(data)

        if request["cmd"] == "upgrade" do
          upgrade(state, request)
        else
          spawn(fn -> reply(state, request["id"], run(request, state)) end)
          PeonProbe.loop(state)
        end

      {:tcp_closed, conn} when conn == state.conn ->
        PeonProbe.dial(%{state | conn: nil})

      {:tcp_error, conn, _} when conn == state.conn ->
        :gen_tcp.close(conn)
        PeonProbe.dial(%{state | conn: nil})

      {:probe_error, error} ->
        if state.errors < @error_cap, do: emit(state, Map.put(error, "event", "error"))
        PeonProbe.loop(%{state | errors: state.errors + 1})

      :reset_cap ->
        PeonProbe.loop(%{state | errors: 0})

      :stats ->
        spawn(fn ->
          case run(%{"cmd" => "stats"}, state) do
            {:ok, stats} -> emit(state, %{"event" => "stats", "stats" => stats})
            _ -> :ok
          end
        end)

        PeonProbe.loop(state)

      {:reply, map} ->
        emit(state, map)
        PeonProbe.loop(state)

      _ ->
        PeonProbe.loop(state)
    end
  end

  # Peon's newer probe replaces this one; it says hello again on a new connection.
  defp upgrade(state, %{"id" => id, "source" => source}) do
    emit(state, %{"reply" => id, "ok" => true, "result" => %{"from" => @version}})
    :gen_tcp.close(state.conn)
    Code.compile_string(source, "probe.exs")
    PeonProbe.dial(%{state | conn: nil})
  end

  defp run(request, state) do
    result =
      case request["cmd"] do
        "deploy" ->
          deploy(Map.merge(request, %{"otp_app" => state.otp_app, "endpoint" => state.endpoint}))

        "stats" ->
          stats()

        "processes" ->
          processes(request["sort"] || "memory", request["limit"] || 15)
      end

    {:ok, result}
  catch
    kind, reason -> {:error, Exception.format(kind, reason) |> String.slice(0, 4000)}
  end

  # Replies come from their own processes; the loop owns the socket.
  defp reply(_state, id, {:ok, result}),
    do: send(__MODULE__, {:reply, %{"reply" => id, "ok" => true, "result" => result}})

  defp reply(_state, id, {:error, message}),
    do: send(__MODULE__, {:reply, %{"reply" => id, "ok" => false, "error" => message}})

  defp emit(%{conn: nil}, _map), do: :ok

  defp emit(%{conn: conn}, map) do
    if self() == Process.whereis(__MODULE__),
      do: :gen_tcp.send(conn, JSON.encode!(map)),
      else: send(__MODULE__, {:reply, map})
  end

  @stats ~w(uptime run_queue process_count process_limit port_count atom_count ets_count
            total processes binary ets code atom schedulers_online io_input io_output)a

  # The app is up: forward its errors and count its requests.
  defp install(otp_app) do
    :logger.remove_handler(:peon_probe)

    :logger.add_handler(:peon_probe, __MODULE__, %{
      level: :error,
      config: %{sink: __MODULE__, otp_app: otp_app}
    })

    install_usage()
  end

  # Requests since the last stats (count and durations) and today's
  # visitors, in tables owned by a process of their own: they outlive the
  # connection, so a reconnect keeps today's visitors.
  defp install_usage do
    if :ets.whereis(:peon_usage) == :undefined do
      me = self()

      spawn(fn ->
        :ets.new(:peon_usage, [:named_table, :public, :duplicate_bag])
        :ets.new(:peon_visitors, [:named_table, :public, :set])
        send(me, :usage_ready)
        Process.sleep(:infinity)
      end)

      receive do
        :usage_ready -> :ok
      after
        5_000 -> :ok
      end
    end

    :telemetry.detach(:peon_usage)
    :telemetry.attach(:peon_usage, [:phoenix, :endpoint, :stop], &__MODULE__.request/4, nil)
  end

  # :telemetry handler: runs in the request's process, never raises. Peon's
  # own health checks don't count.
  def request(_event, %{duration: duration}, %{conn: %{request_path: path} = conn}, _config)
      when path != "/health" do
    :ets.insert(:peon_usage, {:ms, System.convert_time_unit(duration, :native, :millisecond)})
    :ets.insert(:peon_visitors, {{Date.utc_today(), visitor(conn)}})
  rescue
    _ -> :ok
  end

  def request(_event, _measurements, _metadata, _config), do: :ok

  # The signed-in user when the app has accounts, else the browser.
  defp visitor(conn) do
    case conn.assigns[:current_scope] do
      %{user: %{id: id}} ->
        {:user, id}

      _ ->
        agent = conn |> Plug.Conn.get_req_header("user-agent") |> List.first("")
        {:anon, :erlang.phash2({conn.remote_ip, agent})}
    end
  end

  @doc """
  Requests since the last call with their p95 in ms, LiveView sessions
  connected now, and visitors today.
  """
  def usage do
    ms = if :ets.whereis(:peon_usage) == :undefined, do: [], else: :ets.take(:peon_usage, :ms)
    today = Date.utc_today()

    visitors =
      if :ets.whereis(:peon_visitors) == :undefined do
        0
      else
        :ets.select_delete(:peon_visitors, [{{{:"$1", :_}}, [{:"/=", :"$1", {:const, today}}], [true]}])
        :ets.info(:peon_visitors, :size)
      end

    %{
      "requests" => length(ms),
      "p95" => p95(Enum.map(ms, &elem(&1, 1))),
      "sessions" => live_views(),
      "visitors" => visitors
    }
  end

  defp p95([]), do: nil

  defp p95(ms) do
    sorted = Enum.sort(ms)
    Enum.at(sorted, min(length(sorted) - 1, trunc(length(sorted) * 0.95)))
  end

  # Each connected LiveView is a process whose initial call is its mount/3.
  defp live_views do
    Enum.count(Process.list(), fn pid ->
      match?({:dictionary, %{"$initial_call": {_, :mount, 3}}}, dictionary(pid))
    end)
  end

  defp dictionary(pid) do
    case Process.info(pid, :dictionary) do
      {:dictionary, dict} -> {:dictionary, Map.new(dict)}
      nil -> nil
    end
  end

  # :logger handler callback. Runs in the process that logged: cheap, never raises.
  def log(%{msg: msg, meta: meta}, %{config: %{sink: sink, otp_app: otp_app}}) do
    if pid = Process.whereis(sink), do: send(pid, {:probe_error, describe(msg, meta, otp_app)})
  rescue
    _ -> :ok
  end

  defp describe(msg, meta, otp_app) do
    {kind, reason, stack} =
      case meta[:crash_reason] do
        {%{__exception__: true} = e, stack} when is_list(stack) ->
          {inspect(e.__struct__), Exception.message(e), stack}

        {reason, stack} when is_list(stack) ->
          {"exit", inspect(reason, limit: 20, printable_limit: 500), stack}

        _ ->
          {nil, nil, []}
      end

    text = message(msg, meta)

    %{
      "kind" => kind,
      "message" => String.slice(reason || first_line(text), 0, 500),
      "text" => String.slice(text, 0, 4000),
      "stacktrace" =>
        stack |> Enum.take(25) |> Exception.format_stacktrace() |> String.slice(0, 4000),
      "frame" => frame(stack, otp_app),
      "request_id" => meta[:request_id]
    }
  end

  defp message({:string, chardata}, _meta), do: IO.chardata_to_string(chardata)

  defp message({:report, report}, meta) do
    case meta[:report_cb] do
      cb when is_function(cb, 1) ->
        {format, args} = cb.(report)
        format |> :io_lib.format(args) |> IO.chardata_to_string()

      cb when is_function(cb, 2) ->
        report |> cb.(%{}) |> IO.chardata_to_string()

      _ ->
        inspect(report, limit: 30, printable_limit: 1000)
    end
  end

  defp message({format, args}, _meta), do: format |> :io_lib.format(args) |> IO.chardata_to_string()

  defp first_line(text), do: text |> String.split("\n", parts: 2) |> hd()

  # The first frame in the app's own code, skipping line-1 frames: those are
  # generated by `use` macros (the endpoint's and router's plug pipelines).
  defp frame(stack, otp_app) do
    frames = Enum.flat_map(stack, &List.wrap(app_frame(&1, otp_app)))
    Enum.find(frames, &(not String.ends_with?(&1, ":1"))) || List.first(frames)
  end

  defp app_frame({mod, _fun, _arity, location}, otp_app) do
    if :application.get_application(mod) == {:ok, otp_app} and location[:file],
      do: "#{location[:file]}:#{location[:line]}"
  end

  defp app_frame(_, _), do: nil

  @doc "Loads changed code, then rebuilds assets and migrates when asked."
  def deploy(opts) do
    {:ok, io} = StringIO.open("")
    Process.group_leader(self(), io)
    compile = IEx.Helpers.recompile()
    ok? = compile != :error

    assets = if ok? and opts["assets"], do: assets(opts["otp_app"], opts["endpoint"])
    migrated = if ok? and opts["migrate"], do: migrate(opts["otp_app"]), else: []
    {_, output} = StringIO.contents(io)

    %{
      "compile" => compile,
      "assets" => assets,
      "migrated" => migrated,
      "output" => String.slice(output, -6000, 6000)
    }
  end

  defp assets(otp_app, endpoint) do
    Mix.Task.rerun("tailwind", [to_string(otp_app), "--minify"])
    Mix.Task.rerun("esbuild", [to_string(otp_app), "--minify"])
    Mix.Task.rerun("phx.digest", [])
    Mix.Task.rerun("phx.digest.clean", [])
    # Reloads the static manifest, so pages link the new digests.
    endpoint.config_change([], [])
    :ok
  end

  defp migrate(otp_app) do
    for repo <- Application.get_env(otp_app, :ecto_repos, []),
        version <- Ecto.Migrator.run(repo, :up, all: true),
        do: version
  end

  @doc "System figures, the ones observer shows on its first tab, and `usage/0`."
  def stats do
    info = :observer_backend.sys_info()
    @stats |> Map.new(&{&1, info[&1]}) |> Map.put(:usage, usage())
  end

  @doc "The top `limit` processes by memory, reductions or message queue length."
  def processes(sort, limit) do
    key =
      case sort do
        "reductions" -> :reductions
        "message_queue_len" -> :message_queue_len
        _ -> :memory
      end

    keys = [:registered_name, :memory, :reductions, :message_queue_len, :current_function]

    Process.list()
    |> Enum.flat_map(fn pid ->
      case Process.info(pid, [:dictionary, :initial_call | keys]) do
        nil -> []
        info -> [{pid, info}]
      end
    end)
    |> Enum.sort_by(fn {_pid, info} -> info[key] end, :desc)
    |> Enum.take(limit)
    |> Enum.map(fn {pid, info} ->
      %{
        "pid" => inspect(pid),
        "name" => name(info),
        "memory" => info[:memory],
        "reductions" => info[:reductions],
        "message_queue_len" => info[:message_queue_len],
        "current" => mfa(info[:current_function])
      }
    end)
  end

  defp name(info) do
    cond do
      info[:registered_name] not in [nil, []] -> inspect(info[:registered_name])
      call = info[:dictionary][:"$initial_call"] -> mfa(call)
      true -> mfa(info[:initial_call])
    end
  end

  defp mfa({m, f, a}), do: Exception.format_mfa(m, f, a)
  defp mfa(_), do: nil
end

# Started once, with the app; an upgrade only reloads the module. A probe
# that fails must not keep the app from starting.
try do
  unless Process.whereis(PeonProbe), do: PeonProbe.start()
rescue
  e -> IO.warn("Peon's probe did not start: " <> Exception.message(e))
end
