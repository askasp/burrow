defmodule Burrow.Activity do
  @moduledoc """
  Where each chat and each project stands, in the workspace's words.

  A chat's phase (`chats/2`), from its agent and its draft:

    * `"new"` - empty, waiting for its first message
    * `"idle"` - talked, nothing submitted yet (or sent back to merge)
    * `"working"` - the agent works, or its draft is being checked
    * `"failed"` - its checks failed, or main did not pass with it
    * `"ready"` - a repo chat whose PR is open
    * `"landing"` - on main, not shipped yet
    * `"staged"` - on staging, not on prod yet
    * `"live"` - on prod

  A project's tile in the rails (`of/1`): `%{"state" => "working" |
  "waiting" | "done" | "stopped", "label", "pct"}`. Any event in a project
  (`Burrow.Projects.broadcast/3`) redraws the rails: `:rail_changed` on
  topic `"rail"`, changes within `@debounce` ms as one.
  """

  use GenServer

  alias Burrow.{Cell, Chat, Chats, Env, Projects, Secrets, Ship}
  alias Totem.Repo

  @debounce 300

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  def subscribe, do: Phoenix.PubSub.subscribe(Burrow.PubSub, "rail")

  @doc "Tells every workspace to draw its rail again."
  def push do
    if Process.whereis(__MODULE__), do: GenServer.cast(__MODULE__, :push)
    :ok
  end

  @doc "`[%{chat, draft, phase}]` in tab order; `busy` holds the chats whose agent works."
  def chats(project, busy) do
    repo = if !Projects.Project.repo?(project), do: Projects.repo_dir(project)
    refs = repo && Repo.refs(repo)

    for chat <- Chats.list(project.id) do
      draft = repo && Repo.draft(repo, chat.id)
      %{chat: chat, draft: draft, phase: phase(chat, draft, MapSet.member?(busy, chat.id), refs)}
    end
  end

  defp phase(_chat, _draft, true, _refs), do: "working"
  defp phase(%{pr_url: url}, _draft, false, nil) when url != nil, do: "ready"
  defp phase(%{started_at: nil}, nil, false, _refs), do: "new"
  defp phase(_chat, nil, false, _refs), do: "idle"
  defp phase(_chat, %{status: "checking"}, false, _refs), do: "working"
  defp phase(_chat, %{status: "failed"}, false, _refs), do: "failed"

  defp phase(_chat, %{status: "landed", change: id}, false, refs) do
    cond do
      id <= (refs["prod"] || 0) -> "live"
      id <= (refs["staging"] || 0) -> "staged"
      true -> "landing"
    end
  end

  defp phase(_chat, _draft, false, _refs), do: "idle"

  @doc "The change main could ship to prod now, when a person has to press Ship; else nil."
  def shippable(project) do
    repo = Projects.repo_dir(project)
    check = Ship.main_check(project)

    candidate =
      if Ship.staging?(project),
        do: (Env.info(project, "staging") || %{})[:good],
        else: check && check.status == "passed" && check.change_id

    if candidate && Projects.settings(project)["auto_ship"] != true and candidate > (Repo.ref(repo, "prod") || 0),
      do: candidate
  end

  @doc "The project's tile in the rails."
  def of(project) do
    case Cell.status(project.id) do
      :starting -> tile("working", "starting", 40)
      :running -> running(project)
      _ -> tile("stopped", "stopped", 8)
    end
  end

  defp running(project) do
    phases = MapSet.new(chats(project, Chat.busy_ids(project.id)), & &1.phase)
    any? = &MapSet.member?(phases, &1)
    repo? = Projects.Project.repo?(project)
    prod = !repo? && Env.info(project, "prod")

    cond do
      any?.("working") or any?.("landing") -> tile("working", "working", 60)
      match?(%{status: {:crashed, _}}, prod) -> tile("stopped", "stopped", 8)
      any?.("ready") or any?.("staged") or any?.("failed") -> tile("waiting", "waiting on you", 100)
      Enum.any?(Secrets.list(project.id), &(not &1.set?)) -> tile("waiting", "waiting on you", 100)
      !repo? && shippable(project) -> tile("waiting", "ready to ship", 100)
      repo? -> tile("done", "ready", 100)
      Repo.ref(Projects.repo_dir(project), "prod") == nil -> tile("waiting", "new", 100)
      true -> tile("done", "live", 100)
    end
  end

  defp tile(state, label, pct), do: %{"state" => state, "label" => label, "pct" => pct}

  @impl true
  def init(nil) do
    Projects.subscribe()
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

  def handle_info(_projects_or_teams_changed, state), do: {:noreply, schedule(state)}

  defp schedule(%{timer: nil} = state), do: %{state | timer: Process.send_after(self(), :push, @debounce)}
  defp schedule(state), do: state
end
