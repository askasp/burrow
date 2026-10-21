defmodule Totem.Monitor do
  @moduledoc """
  Watches the app from inside its node, from boot on:

    * errors it logs, with their stacktraces (a :logger handler), kept and
      sent to subscribers (`Totem.Link`)
    * requests and visitors, once the app runs (a :telemetry handler on
      Phoenix's endpoint, when the app has Phoenix)
    * the figures observer shows on its first tab (`stats/0`) and the top
      processes (`processes/2`)

  Subscribers get `{:totem, :ready}` once the app has started, and
  `{:totem, :error, map}` for each error (at most #{100} per 10 seconds).
  """

  use GenServer

  # Phoenix apps have :telemetry; it's only called when it's there.
  @compile {:no_warn_undefined, :telemetry}

  @error_cap 100
  @kept 50
  @stats ~w(uptime run_queue process_count process_limit port_count atom_count ets_count
            total processes binary ets code atom schedulers_online io_input io_output)a

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Sends this process the monitor's events. Returns whether the app runs already."
  @spec subscribe() :: boolean()
  def subscribe, do: GenServer.call(__MODULE__, {:subscribe, self()})

  @doc "The errors logged lately, newest first."
  @spec errors() :: [map()]
  def errors, do: GenServer.call(__MODULE__, :errors)

  @doc "True once the app has started."
  @spec ready?() :: boolean()
  def ready?, do: GenServer.call(__MODULE__, :ready?)

  @impl true
  def init(opts) do
    otp_app = opts[:otp_app] || Application.get_env(:totem, :otp_app) || mix_app()
    :logger.remove_handler(:totem)

    :logger.add_handler(:totem, __MODULE__, %{
      level: :error,
      config: %{sink: __MODULE__, otp_app: otp_app}
    })

    # Request counts and today's visitors outlive the app restarting (warm loads).
    :ets.new(:totem_usage, [:named_table, :public, :duplicate_bag])
    :ets.new(:totem_visitors, [:named_table, :public, :set])
    :timer.send_interval(10_000, :reset_cap)
    send(self(), :await_app)

    {:ok, %{otp_app: otp_app, ready?: false, subscribers: [], errors: [], count: 0}}
  end

  @impl true
  def handle_call({:subscribe, pid}, _from, state) do
    Process.monitor(pid)
    {:reply, state.ready?, %{state | subscribers: Enum.uniq([pid | state.subscribers])}}
  end

  def handle_call(:errors, _from, state), do: {:reply, state.errors, state}
  def handle_call(:ready?, _from, state), do: {:reply, state.ready?, state}

  @impl true
  def handle_info(:await_app, %{ready?: false} = state) do
    if started?(state.otp_app) do
      install_usage()
      notify(state, {:totem, :ready})
      {:noreply, %{state | ready?: true}}
    else
      Process.send_after(self(), :await_app, 300)
      {:noreply, state}
    end
  end

  def handle_info({:error, error}, state) do
    if state.count < @error_cap, do: notify(state, {:totem, :error, error})

    {:noreply,
     %{state | errors: Enum.take([error | state.errors], @kept), count: state.count + 1}}
  end

  def handle_info(:reset_cap, state), do: {:noreply, %{state | count: 0}}

  def handle_info({:DOWN, _ref, :process, pid, _}, state),
    do: {:noreply, %{state | subscribers: List.delete(state.subscribers, pid)}}

  def handle_info(_msg, state), do: {:noreply, state}

  defp notify(state, message), do: Enum.each(state.subscribers, &send(&1, message))

  # With no app to wait for (a bare node), it counts as started.
  defp started?(nil), do: true
  defp started?(app), do: List.keymember?(Application.started_applications(), app, 0)

  defp install_usage do
    if Code.ensure_loaded?(:telemetry) do
      :telemetry.detach(:totem_usage)

      :telemetry.attach(
        :totem_usage,
        [:phoenix, :endpoint, :stop],
        &__MODULE__.request/4,
        nil
      )
    end
  end

  @doc false
  # :telemetry handler: runs in the request's process, never raises. Health
  # checks don't count.
  def request(_event, %{duration: duration}, %{conn: %{request_path: path} = conn}, _config)
      when path != "/health" do
    :ets.insert(:totem_usage, {:ms, System.convert_time_unit(duration, :native, :millisecond)})
    :ets.insert(:totem_visitors, {{Date.utc_today(), visitor(conn)}})
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
        agent =
          case List.keyfind(conn.req_headers, "user-agent", 0) do
            {_, agent} -> agent
            nil -> ""
          end

        {:anon, :erlang.phash2({conn.remote_ip, agent})}
    end
  end

  @doc "System figures, the ones observer shows on its first tab, and `usage/0`."
  @spec stats() :: map()
  def stats do
    info = :observer_backend.sys_info()
    @stats |> Map.new(&{&1, info[&1]}) |> Map.put(:usage, usage())
  end

  @doc """
  Requests since the last call with their p95 in ms, LiveView sessions
  connected now, and visitors today.
  """
  @spec usage() :: map()
  def usage do
    ms = :ets.take(:totem_usage, :ms)
    today = Date.utc_today()

    :ets.select_delete(:totem_visitors, [
      {{{:"$1", :_}}, [{:"/=", :"$1", {:const, today}}], [true]}
    ])

    %{
      "requests" => length(ms),
      "p95" => p95(Enum.map(ms, &elem(&1, 1))),
      "sessions" => live_views(),
      "visitors" => :ets.info(:totem_visitors, :size)
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
      case Process.info(pid, :dictionary) do
        {:dictionary, dict} -> match?({_, :mount, 3}, dict[:"$initial_call"])
        nil -> false
      end
    end)
  end

  @doc "The top `limit` processes by `\"memory\"`, `\"reductions\"` or `\"message_queue_len\"`."
  @spec processes(String.t(), pos_integer()) :: [map()]
  def processes(sort \\ "memory", limit \\ 15) do
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

  @doc false
  # :logger handler callback. Runs in the process that logged: cheap, never raises.
  def log(%{msg: msg, meta: meta}, %{config: %{sink: sink, otp_app: otp_app}}) do
    if pid = Process.whereis(sink), do: send(pid, {:error, describe(msg, meta, otp_app)})
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
      "request_id" => meta[:request_id],
      "at" => DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
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

  defp message({format, args}, _meta),
    do: format |> :io_lib.format(args) |> IO.chardata_to_string()

  defp first_line(text), do: text |> String.split("\n", parts: 2) |> hd()

  # The first frame in the app's own code, skipping line-1 frames: those are
  # generated by `use` macros (the endpoint's and router's plug pipelines).
  defp frame(stack, otp_app) do
    frames = Enum.flat_map(stack, &List.wrap(app_frame(&1, otp_app)))
    Enum.find(frames, &(not String.ends_with?(&1, ":1"))) || List.first(frames)
  end

  defp app_frame({mod, _fun, _arity, location}, otp_app) do
    if (otp_app && :application.get_application(mod) == {:ok, otp_app}) and location[:file],
      do: "#{location[:file]}:#{location[:line]}"
  end

  defp app_frame(_, _), do: nil

  defp mix_app do
    if Totem.Loader.available?(), do: Mix.Project.config()[:app]
  end
end
