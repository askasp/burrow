defmodule BurrowWeb.PeonProxy.Socket do
  @moduledoc """
  A workspace's WebSocket (its LiveView socket) through Burrow
  (`BurrowWeb.PeonProxy`): one connection to the browser, one to the Peon,
  frames passed both ways. Frames from the browser wait until the Peon's
  side is open.
  """

  @behaviour WebSock

  require Logger

  @impl true
  def init(%{port: port, path: path, headers: headers}) do
    with {:ok, conn} <- Mint.HTTP.connect(:http, "127.0.0.1", port, protocols: [:http1]),
         {:ok, conn, ref} <- Mint.WebSocket.upgrade(:ws, conn, path, headers) do
      {:ok, %{conn: conn, ref: ref, ws: nil, status: nil, headers: [], waiting: []}}
    else
      {:error, reason} -> stop(reason)
      {:error, _conn, reason} -> stop(reason)
    end
  end

  defp stop(reason) do
    Logger.info("workspace socket: the Peon did not answer (#{inspect(reason)})")
    {:stop, :normal, %{conn: nil}}
  end

  @impl true
  def handle_in({data, opcode: opcode}, %{ws: nil} = state),
    do: {:ok, %{state | waiting: [{opcode, data} | state.waiting]}}

  def handle_in({data, opcode: opcode}, state), do: send_frames(state, [{opcode, data}])

  @impl true
  def handle_info(message, %{conn: conn} = state) when conn != nil do
    case Mint.WebSocket.stream(conn, message) do
      {:ok, conn, responses} -> handle_responses(responses, %{state | conn: conn}, [])
      {:error, conn, _reason, _responses} -> {:stop, :normal, %{state | conn: conn}}
      :unknown -> {:ok, state}
    end
  end

  def handle_info(_message, state), do: {:ok, state}

  defp handle_responses([], state, []), do: {:ok, state}
  defp handle_responses([], state, frames), do: {:push, Enum.reverse(frames), state}

  defp handle_responses([{:status, ref, status} | rest], %{ref: ref} = state, frames),
    do: handle_responses(rest, %{state | status: status}, frames)

  defp handle_responses([{:headers, ref, headers} | rest], %{ref: ref} = state, frames),
    do: handle_responses(rest, %{state | headers: headers}, frames)

  defp handle_responses([{:done, ref} | rest], %{ref: ref, ws: nil} = state, frames) do
    case Mint.WebSocket.new(state.conn, ref, state.status, state.headers) do
      {:ok, conn, ws} ->
        state = %{state | conn: conn, ws: ws}

        case send_frames(state, Enum.reverse(state.waiting)) do
          {:ok, state} -> handle_responses(rest, %{state | waiting: []}, frames)
          stop -> stop
        end

      {:error, conn, reason} ->
        Logger.info("workspace socket: the Peon refused it (#{inspect(reason)})")
        {:stop, :normal, %{state | conn: conn}}
    end
  end

  defp handle_responses([{:data, ref, data} | rest], %{ref: ref, ws: ws} = state, frames)
       when ws != nil do
    case Mint.WebSocket.decode(ws, data) do
      {:ok, ws, decoded} ->
        state = %{state | ws: ws}

        Enum.reduce_while(decoded, {:ok, state, frames}, fn
          {:text, text}, {:ok, state, frames} -> {:cont, {:ok, state, [{:text, text} | frames]}}
          {:binary, bin}, {:ok, state, frames} -> {:cont, {:ok, state, [{:binary, bin} | frames]}}
          {:ping, data}, {:ok, state, frames} -> {:cont, pong(state, data, frames)}
          {:close, _code, _reason}, {:ok, state, _frames} -> {:halt, {:close, state}}
          _other, acc -> {:cont, acc}
        end)
        |> case do
          {:ok, state, frames} -> handle_responses(rest, state, frames)
          {:close, state} -> {:stop, :normal, state}
          {:stop, state} -> {:stop, :normal, state}
        end

      {:error, ws, _reason} ->
        {:stop, :normal, %{state | ws: ws}}
    end
  end

  defp handle_responses([_other | rest], state, frames), do: handle_responses(rest, state, frames)

  defp pong(state, data, frames) do
    case send_frames(state, [{:pong, data}]) do
      {:ok, state} -> {:ok, state, frames}
      {:stop, :normal, state} -> {:stop, state}
    end
  end

  defp send_frames(state, frames) do
    Enum.reduce_while(frames, {:ok, state}, fn frame, {:ok, state} ->
      with {:ok, ws, data} <- Mint.WebSocket.encode(state.ws, frame),
           {:ok, conn} <- Mint.WebSocket.stream_request_body(state.conn, state.ref, data) do
        {:cont, {:ok, %{state | ws: ws, conn: conn}}}
      else
        _ -> {:halt, {:stop, :normal, state}}
      end
    end)
  end

  @impl true
  def terminate(_reason, %{conn: conn}) when conn != nil do
    Mint.HTTP.close(conn)
    :ok
  end

  def terminate(_reason, _state), do: :ok
end
