defmodule Burrow.Hordes.Runner do
  @moduledoc """
  Moves a project's hordes on (`Burrow.Hordes`): it follows the peons' drafts
  and agents on the project's `"ship"` and `"chats"` topics, and main's
  checks, and new errors from its environments (`Burrow.Incidents`). On
  start it catches up with what the peons did meanwhile (`Burrow.Hordes.sync/2`),
  wakes the ones that stopped with a restart and fills free slots.
  """

  use GenServer

  require Logger

  alias Burrow.{Chat, Chats, Hordes, Incidents, Projects}

  @doc """
  Starts the project's runner if it doesn't run: a project whose cell
  started before hordes existed has none.
  """
  def ensure(project) do
    cond do
      # Without running projects (tests) there is no cell to start it in.
      not Application.get_env(:burrow, :start_cells, true) -> :ok
      Registry.lookup(Burrow.ProjectRegistry, {project.id, __MODULE__}) != [] -> :ok
      true -> Burrow.Cell.ensure(project.id, {__MODULE__, project})
    end
  end

  def start_link(project),
    do: GenServer.start_link(__MODULE__, project, name: Burrow.Cell.via(project.id, __MODULE__))

  @impl true
  def init(project) do
    Projects.subscribe(project.id, "ship")
    Chats.subscribe(project.id)
    Incidents.subscribe(project.id)
    send(self(), :fill)
    # The errors already known: only a new one (or one back again) pauses a horde.
    {:ok, %{project: project, errors: MapSet.new(open_errors(project), & &1.id)}}
  end

  defp open_errors(project),
    do: Enum.filter(Incidents.list(project.id, 100), &(&1.status in ~w(open fixing)))

  @impl true
  def handle_info(:fill, %{project: project} = state) do
    busy = Chat.busy_ids(project.id)

    # What happened while nobody followed: drafts first, then the peons
    # that stopped, then free slots.
    for horde <- Hordes.going(project.id) do
      horde = Hordes.sync(project, horde)
      project |> Hordes.wake(horde, busy) |> then(&Hordes.fill(project, &1)) |> Hordes.settle()
    end

    {:noreply, state}
  end

  def handle_info({:draft, chat_id, status}, %{project: project} = state) do
    safely(fn -> Hordes.drafted(project, chat_id, status) end)
    {:noreply, state}
  end

  def handle_info({:chat_busy, chat_id, false}, %{project: project} = state) do
    safely(fn -> Hordes.idle(project, chat_id) end)
    {:noreply, state}
  end

  def handle_info({:chat_busy, chat_id, true}, %{project: project} = state) do
    safely(fn -> Hordes.busy(project, chat_id) end)
    {:noreply, state}
  end

  def handle_info({:main_check, run}, %{project: project} = state) do
    safely(fn -> Hordes.main_checked(project, run) end)
    {:noreply, state}
  end

  def handle_info({:incident, %{status: status, id: id} = incident}, %{project: project} = state)
      when status in ~w(open fixing) do
    unless MapSet.member?(state.errors, id),
      do: safely(fn -> Hordes.errors(project, incident) end)

    {:noreply, %{state | errors: MapSet.put(state.errors, id)}}
  end

  def handle_info({:incident, incident}, %{project: project} = state) do
    safely(fn -> Hordes.errors_fixed(project) end)
    {:noreply, %{state | errors: MapSet.delete(state.errors, incident.id)}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # One bad event mustn't take the hordes down with it.
  defp safely(fun) do
    fun.()
  rescue
    e -> Logger.error("horde runner: " <> Exception.format(:error, e, __STACKTRACE__))
  end
end
