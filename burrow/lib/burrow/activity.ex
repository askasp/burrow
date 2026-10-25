defmodule Burrow.Activity do
  @moduledoc """
  Where each chat and each project stands, in the workspace's words.

  A chat's phase (`chats/2`), from its agent and its draft:

    * `"new"` - empty, waiting for its first message
    * `"idle"` - talked, nothing submitted yet (or sent back to merge)
    * `"working"` - the agent works, or its draft is being checked
    * `"failed"` - its checks failed, or main did not pass with it
    * `"ready"` - a repo chat whose PR is open
    * `"merged"`, `"closed"` - a repo chat whose PR GitHub merged or closed
    * `"drawn"` - its boards are on main (`Burrow.Design`); it goes on
    * `"landing"` - on main, not shipped yet
    * `"staged"` - on staging, not on prod yet
    * `"live"` - on prod

  A project's tile in the rails (`of/1`): `%{"state" => "working" |
  "waiting" | "done" | "stopped", "label", "pct"}`. Any event in a project
  (`Burrow.Projects.broadcast/3`) redraws the rails: `:rail_changed` on
  topic `"rail"`, changes within `@debounce` ms as one.
  """

  use GenServer

  alias Burrow.{Cell, Chat, Chats, Design, Env, Projects, Secrets, Ship}
  alias Burrow.GitRepo.PullRequest
  alias Totem.Repo

  @debounce 300

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  def subscribe, do: Phoenix.PubSub.subscribe(Burrow.PubSub, "rail")

  @doc "Tells every workspace to draw its rail again."
  def push do
    if Process.whereis(__MODULE__), do: GenServer.cast(__MODULE__, :push)
    :ok
  end

  @doc """
  `[%{chat, draft, phase, worked_at}]`, the one worked on last first;
  `busy` holds the chats whose agent works. A chat was worked on when it
  got a message (`Burrow.Chats.started/2`) or its draft was submitted.
  """
  def chats(project, busy), do: phases(project, Chats.list(project.id), busy)

  @doc "The chats user `user_id` sees (`Burrow.Chats.list/2`), as `chats/2` gives them."
  def chats(project, user_id, busy), do: phases(project, Chats.list(project, user_id), busy)

  defp phases(project, chats, busy) do
    repo = if !Projects.Project.repo?(project), do: Projects.repo_dir(project)
    refs = repo && Repo.refs(repo)

    # Newest first, so that of two worked on in the same second the newer leads
    for chat <- Enum.reverse(chats) do
      draft = repo && Repo.draft(repo, chat.id)

      %{
        chat: chat,
        draft: draft,
        phase: phase(chat, draft, MapSet.member?(busy, chat.id), refs),
        worked_at: worked_at(chat, draft)
      }
    end
    |> Enum.sort_by(& &1.worked_at, {:desc, DateTime})
  end

  defp worked_at(chat, %{at: at}) when is_binary(at) do
    {:ok, submitted, _offset} = DateTime.from_iso8601(at)
    Enum.max([chat.updated_at, submitted], DateTime)
  end

  defp worked_at(chat, _draft), do: chat.updated_at

  defp phase(_chat, _draft, true, _refs), do: "working"

  defp phase(%{pr_url: url, pr_state: state}, _draft, false, nil)
       when url != nil and state in ~w(merged closed),
       do: state

  defp phase(%{pr_url: url}, _draft, false, nil) when url != nil, do: "ready"
  defp phase(%{started_at: nil}, nil, false, _refs), do: "new"
  defp phase(_chat, nil, false, _refs), do: "idle"
  defp phase(_chat, %{status: "checking"}, false, _refs), do: "working"
  defp phase(_chat, %{status: "failed"}, false, _refs), do: "failed"

  defp phase(_chat, %{status: "landed", change: id} = draft, false, refs) do
    cond do
      Design.only?(draft.files) -> "drawn"
      id <= (refs["prod"] || 0) -> "live"
      id <= (refs["staging"] || 0) -> "staged"
      true -> "landing"
    end
  end

  defp phase(_chat, _draft, false, _refs), do: "idle"

  @doc "A chat whose change is live, or on main where main is what goes live: it is done."
  def done?(%{phase: "live"}, _live_only?), do: true
  def done?(%{phase: "landing"}, live_only?), do: live_only?
  def done?(_chat, _live_only?), do: false

  @doc """
  Whether user `user_id` can start another chat in the project: up to
  `Burrow.Chats.max/0` of the ones they see that count (`counts?/2`).
  Peon's chats (nil) count as the owner's. A repo project at the limit
  asks GitHub first whether some of its PRs were merged or closed since.
  """
  def room?(project, user_id \\ nil) do
    room? = fn ->
      live_only? = not Ship.staging?(project)
      chats = chats(project, user_id || project.user_id, MapSet.new())
      Enum.count(chats, &counts?(&1, live_only?)) < Chats.max()
    end

    room?.() or
      (Projects.Project.repo?(project) and PullRequest.refresh(project) > 0 and room?.())
  end

  @doc """
  Whether the chat counts against the open-chat limit: not while it is
  empty (it runs nothing yet), done, or a repo chat whose PR is through.
  """
  def counts?(%{phase: phase}, _live_only?) when phase in ~w(new merged closed), do: false
  def counts?(chat, live_only?), do: not done?(chat, live_only?)

  @doc "Whether the chat's change is on main or staging and not live yet."
  def unshipped?(project, chat_id) do
    with false <- Projects.Project.repo?(project),
         repo = Projects.repo_dir(project),
         %{status: "landed"} = draft <- Repo.draft(repo, chat_id),
         %{} = chat <- Chats.get(chat_id) do
      phase(chat, draft, false, Repo.refs(repo)) in ~w(landing staged)
    else
      _ -> false
    end
  end

  @doc "The change main could ship to prod now, when a person has to press Ship; else nil."
  def shippable(project) do
    repo = Projects.repo_dir(project)
    check = Ship.main_check(project)

    candidate =
      if Ship.staging?(project),
        do: (Env.info(project, "staging") || %{})[:good],
        else: check && check.status == "passed" && check.change_id

    if is_integer(candidate) and Projects.settings(project)["auto_ship"] != true and
         candidate > (Repo.ref(repo, "prod") || 0),
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
      any?.("working") or any?.("landing") ->
        tile("working", "working", 60)

      match?(%{status: {:crashed, _}}, prod) ->
        tile("stopped", "stopped", 8)

      any?.("ready") or any?.("staged") or any?.("failed") ->
        tile("waiting", "waiting on you", 100)

      Enum.any?(Secrets.list(project.id), &(not &1.set?)) ->
        tile("waiting", "waiting on you", 100)

      !repo? && shippable(project) ->
        tile("waiting", "ready to ship", 100)

      repo? ->
        tile("done", "ready", 100)

      Repo.ref(Projects.repo_dir(project), "prod") == nil ->
        tile("waiting", "new", 100)

      true ->
        tile("done", "live", 100)
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

  defp schedule(%{timer: nil} = state),
    do: %{state | timer: Process.send_after(self(), :push, @debounce)}

  defp schedule(state), do: state
end
