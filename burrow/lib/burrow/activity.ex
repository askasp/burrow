defmodule Burrow.Activity do
  @moduledoc """
  What each project's Peon is doing, for the project rail in every
  workspace. A Peon reports its project's state when it changes (`put/2`):
  `%{"state" => "working" | "waiting" | "done" | "stopped", "label", "pct"}`,
  `pct` being how far the tile's health bar reaches.

  Whenever an activity, a Peon's status (`Burrow.Cell`) or the projects and
  teams change, every running Peon is told (`Burrow.PeonAPI.rail_changed/1`)
  and its workspaces fetch their rail again, so nothing polls. Pushes within
  `@debounce` ms go out as one.
  """

  use GenServer

  alias Burrow.{Cell, PeonAPI, Projects}

  @table __MODULE__
  @debounce 300

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  def put(project_id, activity), do: GenServer.cast(__MODULE__, {:put, project_id, activity})

  @doc "The project's tile in a rail: its Peon's own report while it runs."
  def of(project_id) do
    case Cell.status(project_id) do
      :starting -> %{"state" => "working", "label" => "starting", "pct" => 40}
      :running -> reported(project_id) || %{"state" => "done", "label" => "running", "pct" => 100}
      _ -> %{"state" => "stopped", "label" => "stopped", "pct" => 8}
    end
  end

  defp reported(project_id) do
    case :ets.lookup(@table, project_id) do
      [{_, activity}] -> activity
      [] -> nil
    end
  end

  @impl true
  def init(nil) do
    :ets.new(@table, [:named_table, :protected, read_concurrency: true])
    Projects.subscribe()
    Cell.subscribe()
    Burrow.Teams.subscribe()
    {:ok, %{timer: nil}}
  end

  @impl true
  def handle_cast({:put, id, activity}, state) do
    if reported(id) == activity do
      {:noreply, state}
    else
      :ets.insert(@table, {id, activity})
      {:noreply, schedule(state)}
    end
  end

  @impl true
  def handle_info(:push, state) do
    for project <- Projects.all(),
        Cell.status(project.id) == :running,
        do: Task.start(fn -> PeonAPI.rail_changed(project) end)

    {:noreply, %{state | timer: nil}}
  end

  # A Peon that stops loses its report; it sends a new one when it is back.
  def handle_info({:cell, id, status}, state) do
    if status != :running, do: :ets.delete(@table, id)
    {:noreply, schedule(state)}
  end

  def handle_info(_projects_or_teams_changed, state), do: {:noreply, schedule(state)}

  defp schedule(%{timer: nil} = state),
    do: %{state | timer: Process.send_after(self(), :push, @debounce)}

  defp schedule(state), do: state
end
