defmodule Burrow.Activity do
  @moduledoc """
  What each project's Peon is doing, for the project rail in every
  workspace. Each Peon broadcasts its project's state when it changes
  (`Peon.Activity`): `%{"state" => "working" | "waiting" | "done" |
  "stopped", "label", "pct"}`, `pct` being how far the tile's health bar
  reaches.

  Whenever an activity, a Peon's status (`Burrow.Cell`) or the projects and
  teams change, `:rail_changed` goes out on topic `"rail"` and workspaces
  draw their rail again, so nothing polls. Changes within `@debounce` ms go
  out as one.
  """

  use GenServer

  alias Burrow.{Cell, Projects}

  @table __MODULE__
  @debounce 300

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  def subscribe, do: Phoenix.PubSub.subscribe(Burrow.PubSub, "rail")

  @doc "Tells every workspace to draw its rail again, e.g. after a user's theme changed."
  def push do
    if Process.whereis(__MODULE__), do: GenServer.cast(__MODULE__, :push)
    :ok
  end

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
    Phoenix.PubSub.subscribe(Peon.PubSub, Peon.Instance.activity_topic())
    Projects.subscribe()
    Cell.subscribe()
    Burrow.Teams.subscribe()
    {:ok, %{timer: nil}}
  end

  @impl true
  def handle_cast(:push, state), do: {:noreply, schedule(state)}

  @impl true
  def handle_info(:push, state) do
    Phoenix.PubSub.broadcast(Burrow.PubSub, "rail", :rail_changed)
    {:noreply, %{state | timer: nil}}
  end

  def handle_info({:activity, id, activity}, state) do
    if reported(id) == activity do
      {:noreply, state}
    else
      :ets.insert(@table, {id, activity})
      {:noreply, schedule(state)}
    end
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
