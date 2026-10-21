defmodule Totem.Link do
  @moduledoc """
  Totem dialing out to a server that runs the app, such as Peon: a Unix
  socket named by `TOTEM_LINK` (or `config :totem, link: path`). Nothing
  listens inside the app; the server's side of the socket decides who may
  reach it. One JSON object per frame (4-byte length):

      server -> Totem  {"id": n, "cmd": "current" | "apply" | ..., ...args}   (`Totem.Commands`)
      Totem -> server  {"reply": n, "ok": true, "result": ...}
                       {"reply": n, "ok": false, "error": {...}}
                       {"event": "connected", "protocol": 1, "totem": vsn, "node": ...,
                        "ready": bool, "current": version}
                       {"event": "ready"}                 the app has started
                       {"event": "error", ...}            the app logged an error (`Totem.Monitor`)
                       {"event": "stats", "stats": ...}   every 10 seconds once ready

  When the socket closes (the server restarted) it dials again every 2 seconds.
  """

  use GenServer

  require Logger

  alias Totem.{Commands, Monitor}

  @protocol 1
  @redial 2_000
  @stats_every 10_000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    case opts[:path] || Application.get_env(:totem, :link) || System.get_env("TOTEM_LINK") do
      path when is_binary(path) and path != "" ->
        ready? = Monitor.subscribe()
        :timer.send_interval(@stats_every, :stats)
        send(self(), :dial)
        {:ok, %{path: path, conn: nil, ready?: ready?}}

      _ ->
        :ignore
    end
  end

  @impl true
  def handle_info(:dial, %{conn: nil} = state) do
    case :gen_tcp.connect({:local, state.path}, 0, [:binary, packet: 4, active: true]) do
      {:ok, conn} ->
        state = %{state | conn: conn}

        emit(state, %{
          "event" => "connected",
          "protocol" => @protocol,
          "totem" => to_string(Application.spec(:totem, :vsn)),
          "node" => to_string(node()),
          "ready" => state.ready?,
          "current" => current()
        })

        if state.ready?, do: send(self(), :stats)
        {:noreply, state}

      {:error, _} ->
        Process.send_after(self(), :dial, @redial)
        {:noreply, state}
    end
  end

  def handle_info({:tcp, conn, data}, %{conn: conn} = state) do
    with {:ok, %{"id" => id, "cmd" => cmd} = request} <- JSON.decode(data) do
      link = self()

      # Each request in its own process; changes queue in Totem.Server.
      spawn(fn ->
        reply =
          try do
            case Commands.run(cmd, request) do
              {:ok, result} -> %{"reply" => id, "ok" => true, "result" => result}
              {:error, error} -> %{"reply" => id, "ok" => false, "error" => error}
            end
          rescue
            e ->
              message = Exception.format(:error, e, __STACKTRACE__)

              %{
                "reply" => id,
                "ok" => false,
                "error" => %{"error" => "crashed", "detail" => message}
              }
          end

        send(link, {:emit, reply})
      end)
    end

    {:noreply, state}
  end

  def handle_info({:tcp_closed, conn}, %{conn: conn} = state), do: {:noreply, redial(state)}

  def handle_info({:tcp_error, conn, _reason}, %{conn: conn} = state) do
    :gen_tcp.close(conn)
    {:noreply, redial(state)}
  end

  def handle_info({:emit, map}, state) do
    emit(state, map)
    {:noreply, state}
  end

  def handle_info({:totem, :ready}, state) do
    emit(state, %{"event" => "ready"})
    send(self(), :stats)
    {:noreply, %{state | ready?: true}}
  end

  def handle_info({:totem, :error, error}, state) do
    emit(state, Map.put(error, "event", "error"))
    {:noreply, state}
  end

  def handle_info(:stats, %{conn: conn, ready?: true} = state) when conn != nil do
    link = self()
    spawn(fn -> send(link, {:emit, %{"event" => "stats", "stats" => Monitor.stats()}}) end)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp redial(state) do
    Process.send_after(self(), :dial, @redial)
    %{state | conn: nil}
  end

  defp emit(%{conn: nil}, _map), do: :ok
  defp emit(%{conn: conn}, map), do: :gen_tcp.send(conn, JSON.encode!(map))

  defp current do
    Commands.version(Totem.current())
  rescue
    e ->
      Logger.warning("Totem: could not read the current version: #{Exception.message(e)}")
      nil
  end
end
