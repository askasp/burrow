defmodule Peon.Activity do
  @moduledoc """
  Where each chat and the project as a whole stand, in the workspace's
  words.

  A chat's phase (`chats/1`), from its agent and its one changeset:

    * `"new"` - empty, waiting for its first message
    * `"idle"` - talked, no changeset yet
    * `"working"` - the agent works, or its changeset is being checked
    * `"failed"` - its changeset failed the checks and the agent stopped
    * `"ready"` - checks passed, waiting to be merged (a repo chat: its PR is open)
    * `"landing"` - merged, on its way live or to staging
    * `"staged"` - on staging, not on prod yet
    * `"live"` - on prod (live)

  The project's (`project/1`) is what Burrow's rails show:
  `%{"state" => "working" | "waiting" | "done" | "stopped", "label", "pct"}`.
  This process reports it to Burrow whenever it changes (`Peon.Burrow.report/1`).
  """

  use GenServer

  alias Peon.{Chat, Chats, Code, Env, Secrets, Ship, Source}

  @debounce 300

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "`[%{chat, changeset, phase}]` in tab order; `busy` holds the chats whose agent works."
  def chats(busy) do
    refs = refs()

    for chat <- Chats.list() do
      cs = if refs, do: Chats.latest_changeset(chat.id)
      %{chat: chat, changeset: cs, phase: phase(chat, cs, MapSet.member?(busy, chat.id), refs)}
    end
  end

  # The refs a changeset moves through; nil in a repo project (no store).
  defp refs do
    unless Source.repo?() do
      id = fn name -> with %{changeset_id: id} <- Code.ref(name), do: id end

      %{
        main: id.("main"),
        staging: id.("staging"),
        prod: id.("prod"),
        live_only?: Ship.live_only?()
      }
    end
  end

  defp phase(_chat, _cs, true, _refs), do: "working"

  defp phase(chat, _cs, false, nil) do
    cond do
      chat.pr_url -> "ready"
      chat.started_at -> "idle"
      true -> "new"
    end
  end

  defp phase(chat, nil, false, _refs), do: if(chat.started_at, do: "idle", else: "new")

  defp phase(_chat, cs, false, refs) do
    on? = fn ref -> refs[ref] != nil and Code.ancestor?(cs.id, refs[ref]) end

    cond do
      cs.status in ["proposed", "checking"] -> "working"
      on?.(:prod) -> "live"
      not refs.live_only? and on?.(:staging) -> "staged"
      on?.(:main) -> "landing"
      cs.status == "passed" -> "ready"
      cs.status == "failed" -> "failed"
      true -> "idle"
    end
  end

  @doc "The project's tile in Burrow's rails, from its chats' phases."
  def project(chats) do
    phases = MapSet.new(chats, & &1.phase)
    any? = &MapSet.member?(phases, &1)

    cond do
      any?.("landing") ->
        tile("working", "working", 85)

      any?.("working") ->
        tile("working", "working", 40)

      prod_down?() ->
        tile("stopped", "stopped", 8)

      any?.("ready") or any?.("staged") or any?.("failed") ->
        tile("waiting", "waiting on you", 100)

      Enum.any?(Secrets.list(), &(not &1.set?)) ->
        tile("waiting", "waiting on you", 100)

      promotable?() ->
        tile("waiting", "waiting on you", 100)

      Source.repo?() ->
        tile("done", "ready", 100)

      Code.ref("prod") == nil ->
        tile("waiting", "new", 100)

      Ship.live_only?() ->
        tile("done", "live", 100)

      true ->
        tile("done", "done", 100)
    end
  end

  defp tile(state, label, pct), do: %{"state" => state, "label" => label, "pct" => pct}

  defp prod_down? do
    not Source.repo?() and
      match?(%{deployed: id, status: {:crashed, _}} when id != nil, Env.info("prod"))
  end

  defp promotable? do
    with false <- Source.repo?() or Ship.live_only?(),
         false <- Peon.Project.settings()["auto_promote"] == true,
         %{good: good} when good != nil <- Env.info("staging"),
         %{deployed: deployed} <- Env.info("prod") do
      good != deployed
    else
      _ -> false
    end
  end

  ## Server

  @impl true
  def init(nil) do
    Chats.subscribe()
    Peon.Store.subscribe()
    Peon.Checks.subscribe()
    Env.subscribe()
    Secrets.subscribe()
    {:ok, %{busy: MapSet.new(), reported: nil, timer: nil}, {:continue, :report}}
  end

  @impl true
  def handle_continue(:report, state), do: {:noreply, report(%{state | busy: Chat.busy_ids()})}

  @impl true
  def handle_info(:report, state), do: {:noreply, report(%{state | timer: nil})}

  def handle_info({:chat_busy, id, true}, state),
    do: {:noreply, schedule(%{state | busy: MapSet.put(state.busy, id)})}

  def handle_info({:chat_busy, id, false}, state),
    do: {:noreply, schedule(%{state | busy: MapSet.delete(state.busy, id)})}

  def handle_info(_changed, state), do: {:noreply, schedule(state)}

  defp schedule(%{timer: nil} = state),
    do: %{state | timer: Process.send_after(self(), :report, @debounce)}

  defp schedule(state), do: state

  defp report(state) do
    activity = project(chats(state.busy))

    if activity != state.reported,
      do: Task.Supervisor.start_child(Peon.TaskSupervisor, fn -> Peon.Burrow.report(activity) end)

    %{state | reported: activity}
  end
end
