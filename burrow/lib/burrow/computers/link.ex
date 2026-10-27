defmodule Burrow.Computers.Link do
  @moduledoc """
  One computer's websocket (`WebSock`), opened by its Burrow Bridge and
  registered in `Burrow.ComputerRegistry` under the computer's id, where
  `Burrow.Computers.call/4` finds it.

  The bridge says `{"type": "hello", os, arch, version, folders, pick}`
  first, and `{"type": "folders", folders}` whenever what it shares
  changes. Calls go out as `{"type": "call", id, method, params}`; the
  bridge answers each with `{"type": "reply", id, result | error}`, in any
  order, since it runs them side by side.
  """

  @behaviour WebSock

  require Logger

  alias Burrow.Computers

  @registry Burrow.ComputerRegistry

  @impl true
  def init(computer) do
    take_over(computer.id)

    {:ok, %{id: computer.id, computer: computer, next: 1, calls: %{}, hello?: false}}
  end

  # A bridge that reconnects may find its old link still registered (the
  # old one hasn't noticed the network went): the new link replaces it.
  defp take_over(id) do
    case Registry.register(@registry, id, nil) do
      {:ok, _} ->
        :ok

      {:error, {:already_registered, old}} ->
        ref = Process.monitor(old)
        send(old, :replaced)

        receive do
          {:DOWN, ^ref, _, _, _} -> :ok
        after
          5_000 -> Process.exit(old, :kill)
        end

        take_over(id)
    end
  end

  @impl true
  def handle_in({text, opcode: :text}, state) do
    case Jason.decode(text) do
      {:ok, %{"type" => "reply", "id" => id} = reply} -> {:ok, answer(state, id, reply)}
      {:ok, %{"type" => "hello"} = hello} -> {:ok, hello(state, hello)}
      {:ok, %{"type" => "folders", "folders" => folders}} -> {:ok, folders(state, folders)}
      _ -> {:ok, state}
    end
  end

  def handle_in(_frame, state), do: {:ok, state}

  @impl true
  def handle_info({:call, from, ref, method, params}, state) do
    id = state.next
    message = Jason.encode!(%{type: "call", id: id, method: method, params: params})
    state = %{state | next: id + 1, calls: Map.put(state.calls, id, {from, ref})}
    {:push, {:text, message}, state}
  end

  def handle_info(:replaced, state), do: {:stop, :normal, {1000, "replaced"}, state}
  def handle_info(:removed, state), do: {:stop, :normal, {4001, "removed"}, state}
  def handle_info(_message, state), do: {:ok, state}

  @impl true
  def terminate(_reason, state) do
    for {_id, {from, ref}} <- state.calls, do: send(from, {ref, {:error, :offline}})
    Registry.unregister(@registry, state.id)
    if state.hello?, do: Computers.disconnected(state.id)
    :ok
  end

  defp answer(state, id, reply) do
    case Map.pop(state.calls, id) do
      {nil, _calls} ->
        state

      {{from, ref}, calls} ->
        result =
          case reply do
            %{"error" => error} when is_binary(error) -> {:error, error}
            %{"result" => result} -> {:ok, result}
            _ -> {:error, "the computer sent no answer"}
          end

        send(from, {ref, result})
        %{state | calls: calls}
    end
  end

  defp hello(state, hello) do
    computer = Computers.connected(state.computer, hello)
    Logger.info("computer #{state.id} (#{computer.name}) connected, bridge #{computer.version}")
    %{state | computer: computer, hello?: true}
  end

  defp folders(state, folders) do
    Computers.folders_changed(state.id, folders)
    state
  end
end
