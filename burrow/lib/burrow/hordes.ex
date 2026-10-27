defmodule Burrow.Hordes do
  @moduledoc """
  A horde: a chat's tk queue (`Burrow.Tickets`) run at the same time, a
  peon per ticket.

  Peon writes the job as tickets with dependencies; nothing runs until the
  user starts the queue as a horde (`run_queue/2`). Each peon is a chat of
  its own (`Burrow.Chats.Chat`'s `horde_id`) with its own checkout, told its
  one ticket; its preview starts only when someone opens it. It submits
  like any chat and ships on its own when its checks pass: its ticket
  closes in tk, the planning chat's checkout follows main (so its preview
  shows everything coming together) and the peon's agent, preview and
  checkout go. A ticket starts once everything it depends on has shipped,
  `at_once` at a time (`fill/2`). `Burrow.Hordes.Runner` follows the peons'
  chats and drafts and moves the horde on (`drafted/3`, `idle/2`,
  `main_checked/2`).

  While the horde is paused, by hand or because main went red or a running
  environment reports new errors after its ships (`errors/2`), peons keep
  working but nothing lands: a peon whose checks pass is held (`hold?/2`)
  and lands when shipping resumes.

  Each peon thinks as hard as its ticket needs: the planner tags each
  ticket `think:low`, `think:medium` or `think:high` (`thinking/2` maps that
  to the model's levels).
  A peon whose checks fail three times, or whose agent stops without
  shipping, is stuck: it tries again by itself once, thinking hardest, then
  needs the user (a hint, another model, or skipping it, with or without
  what waits on it). The horde is done when no peon is left to work;
  stopping it stops the rest, leaves their tickets open in tk and can take
  out what shipped.

  Broadcasts `{:horde, horde_id}` on the project's `"hordes"` topic.
  """

  import Ecto.Query

  require Logger

  alias Burrow.{Accounts, Chat, Chats, Projects, Repo, Ship, Tickets, Workspace}

  defmodule Peon do
    @moduledoc false
    use Ecto.Schema

    schema "horde_peons" do
      belongs_to :horde, Burrow.Hordes.Horde
      field :n, :integer
      field :title, :string
      field :task, :string
      field :chat_id, :string
      field :status, :string, default: "queued"
      field :fails, :integer, default: 0
      field :change_id, :integer
      # The tk ticket it takes, in the planning chat's queue, and the tickets
      # it waits on
      field :ticket, :string
      field :deps, {:array, :string}, default: []
      # How hard it thinks: one of its horde's `efforts`, as its task needs
      field :effort, :string
      # What it did: [%{"at", "text", "tone"}], oldest first
      field :log, {:array, :map}, default: []
      timestamps(type: :utc_datetime)
    end
  end

  defmodule Horde do
    @moduledoc false
    use Ecto.Schema

    schema "hordes" do
      field :project_id, :integer
      field :chat_id, :string
      field :status, :string, default: "planned"
      field :paused_by, :string
      field :at_once, :integer, default: 4
      # The thinking levels of the model the peons use (`Burrow.OpenCode.models/1`)
      field :efforts, {:array, :string}, default: []
      field :started_at, :utc_datetime
      field :finished_at, :utc_datetime
      has_many :peons, Burrow.Hordes.Peon, preload_order: [asc: :n]
      timestamps(type: :utc_datetime)
    end
  end

  @max_fails 3
  # A peon at work holds one of the horde's slots; "retrying" is one that
  # got stuck and tries again thinking harder.
  @active ~w(working checking fixing retrying)
  # A peon that can still ship.
  @open ~w(queued working checking fixing retrying held needs_you)
  # Thinking levels, least first, as models name them (opencode's variants).
  @thinking ~w(none minimal low medium high xhigh max)

  def max_fails, do: @max_fails

  @doc """
  The most peons a horde runs at once (`:max_horde_at_once`, 32 by default):
  each is an agent and a preview, about half a GB idle, and compiles and
  tests while it works, all on the owner's AI login.
  """
  def max_at_once, do: Application.get_env(:burrow, :max_horde_at_once, 32)

  def subscribe(project_id), do: Projects.subscribe(project_id, "hordes")

  @doc "Chat `chat_id`'s horde, the newest, with its peons; nil if it has none."
  def for_chat(chat_id) do
    Repo.one(
      from c in Horde,
        where: c.chat_id == ^chat_id,
        order_by: [desc: c.id],
        limit: 1,
        preload: :peons
    )
  end

  def get!(id), do: Horde |> Repo.get!(id) |> Repo.preload(:peons)

  @doc "The project's hordes by the chat that planned them, the newest of each, with peons."
  def by_chat(project_id) do
    Repo.all(from c in Horde, where: c.project_id == ^project_id, order_by: c.id, preload: :peons)
    |> Map.new(&{&1.chat_id, &1})
  end

  @doc "The peon chat `chat_id` works as, with its horde; nil for any other chat."
  def peon_of(chat_id) do
    Repo.one(from p in Peon, where: p.chat_id == ^chat_id, preload: :horde)
  end

  @doc "The hordes that run or wait in `project` (`Burrow.Hordes.Runner` follows them)."
  def going(project_id) do
    Repo.all(
      from c in Horde,
        where: c.project_id == ^project_id and c.status in ~w(running paused),
        preload: :peons
    )
  end

  @doc """
  A horde for chat `chat_id`, not started yet (`start/2`): `tasks`
  (`%{"title", "task"}`, and `"ticket"`, `"deps"`, `"thinking"`), `at_once`
  at a time. A chat runs one horde at a time. `{:ok, horde}` or
  `{:error, text}`.
  """
  def plan(project, chat_id, tasks, at_once \\ nil, efforts \\ []) do
    case for_chat(chat_id) do
      %{status: status} when status in ~w(running paused) ->
        {:error, "A horde already runs in this chat. It must finish or be stopped first."}

      _ ->
        Repo.transaction(fn ->
          horde =
            Repo.insert!(%Horde{
              project_id: project.id,
              chat_id: chat_id,
              at_once: clamp(at_once),
              efforts: efforts
            })

          for {task, n} <- Enum.with_index(tasks, 1) do
            Repo.insert!(%Peon{
              horde_id: horde.id,
              n: n,
              title: task["title"] |> to_string() |> String.trim() |> String.slice(0, 120),
              task: task["task"] |> to_string() |> String.trim(),
              ticket: task["ticket"],
              deps: task["deps"] || [],
              effort: thinking(task["thinking"], efforts)
            })
          end

          horde.id
        end)
        |> case do
          {:ok, id} -> {:ok, id |> get!() |> broadcast()}
          {:error, reason} -> {:error, inspect(reason)}
        end
    end
  end

  @doc """
  Runs chat `chat_id`'s tk queue as a horde: a peon for each ticket not
  closed, waiting on the ones it depends on, as many at once as the chat's
  + menu says. `{:ok, horde}` or `{:error, text}`.
  """
  def run_queue(project, chat_id) do
    tickets = Tickets.unfinished(Chat.tickets(project, chat_id))
    ids = MapSet.new(tickets, & &1.id)
    chat = Chats.get(chat_id)

    tasks =
      for t <- tickets do
        %{
          "title" => t.title,
          "task" => if(t.description == "", do: t.title, else: t.description),
          "ticket" => t.id,
          "deps" => Enum.filter(t.deps, &MapSet.member?(ids, &1)),
          "thinking" => Enum.find_value(t.tags, fn tag -> with "think:" <> l <- tag, do: l end)
        }
      end

    with true <- tasks != [] || {:error, "The queue has no open tickets."},
         {:ok, horde} <-
           plan(
             project,
             chat_id,
             tasks,
             chat && chat.horde_at_once,
             model_efforts(project, chat_id)
           ),
         do: {:ok, start(project, horde)}
  end

  @doc """
  The model's thinking level (one of `efforts`) closest to `level`, the
  harder of two as close; nil when the model has none to pick from.
  """
  def thinking(level, efforts) do
    known = Enum.filter(efforts, &rank/1)

    cond do
      level in efforts -> level
      known == [] or rank(level) == nil -> nil
      true -> Enum.min_by(known, &{abs(rank(&1) - rank(level)), -rank(&1)})
    end
  end

  @doc "The model's hardest thinking level, or nil."
  def hardest(efforts), do: efforts |> Enum.filter(&rank/1) |> Enum.max_by(&rank/1, fn -> nil end)

  defp rank(level), do: Enum.find_index(@thinking, &(&1 == level))

  @doc """
  The thinking levels of the model chat `chat_id` uses, from the project
  owner's AI login; none when that can't be asked.
  """
  def model_efforts(project, chat_id) do
    chat = Chats.get(chat_id)
    model = (chat && chat.model) || Burrow.OpenCode.model(project.user_id)

    with {:ok, models} <- Burrow.OpenCode.models(project.user_id),
         {_, efforts} <- List.keyfind(models, model, 0),
         do: efforts,
         else: (_ -> [])
  rescue
    _ -> []
  catch
    :exit, _ -> []
  end

  defp blank(nil), do: nil
  defp blank(text), do: if(String.trim(to_string(text)) == "", do: nil, else: String.trim(text))

  defp clamp(n) when is_integer(n), do: n |> max(1) |> min(max_at_once())
  defp clamp(_), do: 4

  @doc "Starts a horde: its first ready peons get to work."
  def start(project, %Horde{status: "planned"} = horde) do
    Burrow.Hordes.Runner.ensure(project)

    horde
    |> Ecto.Changeset.change(status: "running", started_at: DateTime.utc_now(:second))
    |> Repo.update!()
    |> reload()
    |> then(&fill(project, &1))
    |> broadcast()
  end

  def start(_project, horde), do: horde

  @doc "Shipping pauses: peons keep working, and what passes is held (`hold?/2`)."
  def pause(%Horde{status: "running"} = horde, by) do
    horde |> Ecto.Changeset.change(status: "paused", paused_by: by) |> Repo.update!() |> changed()
  end

  def pause(horde, _by), do: horde

  @doc "Shipping resumes: held peons land, one by one, and free slots fill."
  def resume(project, %Horde{status: "paused"} = horde) do
    horde =
      horde
      |> Ecto.Changeset.change(status: "running", paused_by: nil)
      |> Repo.update!()
      |> reload()

    for %{status: "held"} = peon <- horde.peons, !review?(peon), do: land_held(project, peon)
    horde |> reload() |> then(&fill(project, &1)) |> finish() |> broadcast()
  end

  def resume(_project, horde), do: horde

  @doc """
  Stops the horde: peons that haven't shipped stop and keep their chats.
  With `revert?`, what shipped comes out of main again, newest first.
  """
  def stop(project, horde, revert? \\ false) do
    for peon <- horde.peons, peon.status in @open do
      if peon.status in @active, do: interrupt(peon)
      ticket(project, horde, peon, "open")
      set(peon, status: "stopped", log: "Stopped with the horde; its ticket stays open")
    end

    if revert? do
      for peon <- Enum.sort_by(horde.peons, & &1.change_id, :desc),
          peon.status == "shipped" and peon.change_id,
          do: revert(project, peon, "horde")
    end

    horde
    |> Ecto.Changeset.change(status: "stopped", finished_at: DateTime.utc_now(:second))
    |> Repo.update!()
    |> changed()
  end

  @doc "Merges every peon whose checks passed and that waits (for review, or a pause)."
  def merge_ready(project, horde) do
    for %{status: "held"} = peon <- horde.peons, do: land_held(project, peon)
    changed(horde)
  end

  # Its chat ships for review (`Burrow.Chats.pick_shipping/2`): a person merges it.
  defp review?(%Peon{chat_id: id}), do: match?(%{shipping: "review"}, Chats.get(id))

  @doc "Takes every shipped peon's change out of main again, newest first."
  def revert_all(project, horde) do
    for peon <- Enum.sort_by(horde.peons, & &1.change_id, :desc),
        peon.status == "shipped" and peon.change_id,
        do: revert(project, peon, "horde")

    changed(horde)
  end

  ## One peon

  @doc """
  Tries a peon again in its own chat: with the user's `hint`, if any, and
  `model` (`{provider/model, thinking level}`), if given.
  """
  def retry(project, peon, hint \\ nil, model \\ nil) do
    horde = Repo.get!(Horde, peon.horde_id)

    with {model, effort} <- model,
         %Chats.Chat{} = chat <- peon.chat_id && Chats.get(peon.chat_id),
         do: Chats.pick_model(chat, model, effort)

    cond do
      peon.chat_id == nil ->
        set(peon, status: "queued", fails: 0, log: "Back in the queue")
        horde |> reload() |> then(&fill(project, &1))

      true ->
        hint = blank(hint)

        line = if hint, do: "Tried again with a hint: " <> hint, else: "Tried again"
        line = with {model, _effort} <- model, do: line <> " on " <> model, else: (_ -> line)
        effort = with {_model, effort} <- model, do: effort, else: (_ -> peon.effort)
        set(peon, status: "working", fails: 0, effort: effort, log: line)

        Ship.tell_chat(project.id, peon.chat_id, retry_text(hint))
    end

    if horde.status in ~w(stopped done),
      do: horde |> Ecto.Changeset.change(status: "running", finished_at: nil) |> Repo.update!()

    changed(horde)
  end

  defp retry_text(nil),
    do:
      "Try your task again: find what stopped it, fix it and submit. The tests must pass " <>
        "and the change must land."

  defp retry_text(hint),
    do: "The user has a hint for your task: #{hint}\n\nTry again with it and submit."

  @doc """
  The user skips a peon: it stops where it is and its ticket stays open.
  What waits on it goes ahead without it, or with `waiting?` is skipped too.
  """
  def skip(project, peon, waiting? \\ false) do
    horde = get!(peon.horde_id)
    skipped = if waiting?, do: [peon | waiting(horde, peon)], else: [peon]

    for p <- skipped, p.status in @open do
      if p.status in @active, do: interrupt(p)
      ticket(project, horde, p, "open")

      set(p,
        status: "skipped",
        log: if(p.n == peon.n, do: "Skipped", else: "Skipped with ##{peon.n}")
      )
    end

    horde |> reload() |> then(&fill(project, &1)) |> finish() |> broadcast()
  end

  @doc "Lands a held peon now, though shipping is paused."
  def ship_now(project, %Peon{status: "held"} = peon) do
    land_held(project, peon)
    changed(Repo.get!(Horde, peon.horde_id))
  end

  def ship_now(_project, peon), do: changed(Repo.get!(Horde, peon.horde_id))

  @doc "Takes a shipped peon's change out of main again."
  def revert(project, %Peon{status: "shipped", change_id: id} = peon, actor) when id != nil do
    case Ship.revert(project, id, actor) do
      {:ok, change} -> set(peon, status: "reverted", log: "Taken out again as ##{change.id}")
      _ -> :error
    end

    changed(Repo.get!(Horde, peon.horde_id))
  end

  def revert(_project, peon, _actor), do: changed(Repo.get!(Horde, peon.horde_id))

  ## What the runner sees

  @doc "Whether chat `chat_id`'s change waits instead of landing: its horde is paused."
  def hold?(_project, chat_id) do
    Repo.exists?(
      from p in Peon,
        join: c in Horde,
        on: c.id == p.horde_id,
        where: p.chat_id == ^chat_id and c.status == "paused"
    )
  end

  @doc "A peon's draft moved (`Burrow.Ship`'s `{:draft, chat_id, status}`)."
  def drafted(project, chat_id, status) do
    with %Peon{} = peon <- peon_of(chat_id) do
      on_draft(project, peon, status)
      peon.horde |> reload() |> then(&fill(project, &1)) |> finish() |> broadcast()
    end
  end

  defp on_draft(_project, peon, "checking") do
    if peon.status in ~w(working fixing needs_you),
      do: set(peon, status: "checking", log: "Checking")
  end

  defp on_draft(_project, peon, "held") do
    line =
      if review?(peon),
        do: "Checks passed; waiting for you to merge it",
        else: "Checks passed; held while shipping is paused"

    set(peon, status: "held", log: line, tone: "ok")
  end

  defp on_draft(project, peon, "landed") do
    draft = Totem.Repo.draft(Projects.repo_dir(project), peon.chat_id)
    id = draft && draft.change
    peon = set(peon, status: "shipped", change_id: id, log: "Shipped ##{id}", tone: "ok")
    shipped(project, get!(peon.horde_id), peon)
  end

  defp on_draft(project, %{status: "shipped"} = peon, "failed") do
    set(peon,
      status: "fixing",
      change_id: nil,
      fails: peon.fails + 1,
      log: "Main did not pass with ##{peon.change_id}; taken out again",
      tone: "bad"
    )

    give_up?(project, peon_of(peon.chat_id))
  end

  defp on_draft(project, peon, "failed") do
    set(peon,
      status: "fixing",
      fails: peon.fails + 1,
      log: "Checks failed" <> failed_step(project, peon),
      tone: "bad"
    )

    give_up?(project, peon_of(peon.chat_id))
  end

  # Landing found the same lines changed on main: the agent merges and submits again.
  defp on_draft(_project, peon, "open") do
    if peon.status in ~w(checking held),
      do: set(peon, status: "fixing", log: "Main changed the same lines; merging", tone: "bad")
  end

  defp on_draft(_project, _peon, _status), do: :ok

  # Its ticket closes, the planning chat's checkout follows main, and once
  # its agent is done its own checkout goes.
  defp shipped(project, horde, peon) do
    ticket(project, horde, peon, "closed")
    follow_main(project, horde)
    unless MapSet.member?(Chat.busy_ids(project.id), peon.chat_id), do: clean_up(project, peon)
  end

  # The planning chat's checkout moves onto main, unless its agent works:
  # its preview reloads with every ship.
  defp follow_main(project, horde) do
    dir = Chat.workspace_dir(project, horde.chat_id)
    repo = Projects.repo_dir(project)

    if Workspace.checked_out?(dir) and
         not MapSet.member?(Chat.busy_ids(project.id), horde.chat_id),
       do: Workspace.rebase(repo, dir, Totem.Repo.ref(repo, "main"))
  end

  # A shipped peon's agent and preview stop and its checkout goes; its chat
  # stays, to read, and starts again from main on a message.
  defp clean_up(project, %Peon{chat_id: id}) when id != nil do
    Task.Supervisor.start_child(Burrow.TaskSupervisor, fn ->
      Chat.stop(id, :shipped)
      File.rm_rf(Chat.workspace_dir(project, id))
    end)
  end

  defp clean_up(_project, _peon), do: :ok

  # Its ticket in the planning chat's queue, as tk would set it.
  defp ticket(_project, _horde, %Peon{ticket: nil}, _status), do: :ok

  defp ticket(project, horde, %Peon{ticket: id}, status),
    do: Tickets.set_status(Chat.tickets_dir(project, horde.chat_id), id, status)

  defp failed_step(project, peon) do
    case Totem.Repo.draft(Projects.repo_dir(project), peon.chat_id) do
      %{checks: %{"steps" => [_ | _] = steps}} -> " at " <> List.last(steps)["name"]
      _ -> ""
    end
  end

  # Three failed tries: the peon is stuck.
  defp give_up?(project, %Peon{fails: fails} = peon) when fails >= @max_fails,
    do: stuck(project, peon, "Stuck after #{fails} tries")

  defp give_up?(_project, _peon), do: :ok

  @doc "A peon's agent stopped (`{:chat_busy, chat_id, false}`)."
  def idle(project, chat_id) do
    case peon_of(chat_id) do
      %Peon{status: status} = peon when status in ~w(working fixing) ->
        stuck(project, peon, "Stopped without shipping")
        peon.horde |> reload() |> then(&fill(project, &1)) |> finish() |> broadcast()

      %Peon{status: "shipped"} = peon ->
        clean_up(project, peon)

      _ ->
        :ok
    end
  end

  # A stuck peon tries again by itself, once, thinking hardest; after that
  # (or when it already did) it waits for the user.
  defp stuck(project, peon, why) do
    horde = Repo.get!(Horde, peon.horde_id)
    hardest = hardest(horde.efforts)
    chat = peon.chat_id && Chats.get(peon.chat_id)

    if hardest && chat && (chat.effort || peon.effort) != hardest do
      Chats.pick_model(chat, chat.model, hardest)

      set(peon,
        status: "retrying",
        fails: 0,
        effort: hardest,
        log: "#{why}; trying again, thinking harder (#{hardest})",
        tone: "bad"
      )

      # Its turn ends first, so the next one thinks at the new level.
      Task.Supervisor.start_child(Burrow.TaskSupervisor, fn ->
        Chat.interrupt(peon.chat_id)
        Ship.tell_chat(project.id, peon.chat_id, harder_text(why))
      end)
    else
      interrupt(peon)
      set(peon, status: "needs_you", log: "#{why}. Needs you.", tone: "bad")
    end
  end

  defp harder_text(why),
    do:
      "#{why}. Step back and think it through: find the root cause, fix it properly " <>
        "and submit. The tests must pass and the change must land."

  @doc "A peon's agent works again, as when the user takes over in its chat."
  def busy(_project, chat_id) do
    with %Peon{status: status} = peon when status in ~w(needs_you skipped stopped retrying) <-
           peon_of(chat_id),
         %Horde{status: horde_status} when horde_status in ~w(running paused) <- peon.horde do
      set(peon, status: "working", log: "Working again")
      broadcast(peon.horde)
    end
  end

  @doc "Main was checked (`{:main_check, run}`): red pauses the hordes, green resumes them."
  def main_checked(project, %{status: "failed", change_id: id}) do
    for horde <- going(project.id), horde.status == "running" do
      Logger.info("#{project.slug}: main ##{id} is red, horde #{horde.id} pauses")
      pause(horde, "main")
    end
  end

  def main_checked(project, %{status: "passed"}) do
    for horde <- going(project.id), horde.paused_by == "main", do: resume(project, horde)
  end

  def main_checked(_project, _run), do: :ok

  @doc """
  A new error in a running environment (`Burrow.Incidents`): hordes whose
  shipped changes it runs pause, as when main goes red.
  """
  def errors(project, %{change_id: id}) when is_integer(id) do
    for horde <- going(project.id),
        horde.status == "running",
        Enum.any?(horde.peons, &(&1.change_id && &1.change_id <= id)) do
      Logger.info("#{project.slug}: errors on ##{id}, horde #{horde.id} pauses")
      pause(horde, "errors")
    end
  end

  def errors(_project, _incident), do: :ok

  @doc "An error was fixed: hordes it paused resume once none of theirs is left."
  def errors_fixed(project) do
    for horde <- going(project.id),
        horde.paused_by == "errors",
        errors_of(horde) == [],
        do: resume(project, horde)
  end

  @doc "The errors not fixed yet in environments that run the horde's shipped changes."
  def errors_of(%Horde{} = horde) do
    case horde.peons |> Enum.map(& &1.change_id) |> Enum.reject(&is_nil/1) do
      [] ->
        []

      ids ->
        first = Enum.min(ids)

        Repo.all(
          from i in Burrow.Incidents,
            where:
              i.project_id == ^horde.project_id and i.status in ~w(open fixing) and
                i.change_id >= ^first,
            order_by: [desc: i.last_seen_at]
        )
    end
  end

  @doc """
  Catches up with what the peons' drafts did while nobody followed them
  (no runner, or a restart): landed is shipped, held is held, failed is
  fixing, checking is checking.
  """
  def sync(project, horde) do
    repo = Projects.repo_dir(project)

    for %{chat_id: id} = peon <- horde.peons,
        id != nil,
        peon.status in @active or peon.status == "held" do
      case Totem.Repo.draft(repo, id) do
        %{status: "landed", change: change} when peon.status != "shipped" ->
          set(peon, status: "shipped", change_id: change, log: "Shipped ##{change}", tone: "ok")

        %{status: "held"} when peon.status != "held" ->
          set(peon, status: "held", log: "Checks passed; held", tone: "ok")

        %{status: "failed"} when peon.status != "fixing" ->
          set(peon, status: "fixing", log: "Checks failed", tone: "bad")

        %{status: "checking"} when peon.status != "checking" ->
          set(peon, status: "checking", log: "Checking")

        _ ->
          :ok
      end
    end

    reload(horde)
  end

  @doc "Ends a horde with nothing left to work on, and tells its screen."
  def settle(horde), do: horde |> finish() |> broadcast()

  @doc """
  After a restart (the project's chats stopped with it): peons that were
  at work and whose agents don't work now are told to go on.
  """
  def wake(project, horde, busy) do
    for %{status: status, chat_id: id} <- horde.peons,
        status in @active and id != nil and not MapSet.member?(busy, id),
        do:
          Ship.tell_chat(
            project.id,
            id,
            "Burrow restarted while you worked. Go on with your task."
          )

    horde
  end

  @doc """
  Starts ready peons (`ready?/2`) while the horde runs and has free slots.
  """
  def fill(project, %Horde{status: "running"} = horde) do
    active = Enum.count(horde.peons, &(&1.status in @active))
    ready = Enum.filter(horde.peons, &(&1.status == "queued" and ready?(horde, &1)))
    Enum.each(Enum.take(ready, max(horde.at_once - active, 0)), &start_peon(project, horde, &1))
    reload(horde)
  end

  def fill(_project, horde), do: horde

  defp start_peon(project, horde, peon) do
    lead = Chats.get(horde.chat_id)
    by = (lead && lead.user_id && Repo.get(Accounts.User, lead.user_id)) || "peon"

    chat =
      Chats.create(project.id, peon.title, by,
        horde_id: horde.id,
        model: lead && lead.model,
        effort: peon.effort || (lead && lead.effort),
        shipping: lead && lead.shipping
      )

    ticket(project, horde, peon, "in_progress")
    set(peon, chat_id: chat.id, status: "working", log: "Started in its own checkout")
    Ship.tell_chat(project.id, chat.id, task_text(lead, peon, length(horde.peons)))
  end

  defp task_text(lead, peon, size) do
    """
    You are peon ##{peon.n} of a horde of #{size}, working on "#{lead && lead.title}". \
    Your one task#{if peon.ticket, do: ", ticket #{peon.ticket}"}: #{peon.title}

    #{peon.task}

    The other peons change other parts of the app at the same time, each in its own \
    checkout; what this task depends on has shipped already. Do only this task and touch \
    only the files it needs. No tk tickets for it. Your preview isn't running: check your \
    work with the tests. When it works and the tests pass, call peon_submit_changeset; if \
    the checks fail, fix them and submit again. You are done once it lands.\
    """
  end

  # Nothing left to work on: the horde is done (some may still need the user).
  defp finish(%Horde{status: "running"} = horde) do
    if Enum.any?(horde.peons, &(&1.status in @open)),
      do: horde,
      else:
        horde
        |> Ecto.Changeset.change(status: "done", finished_at: DateTime.utc_now(:second))
        |> Repo.update!()
        |> reload()
  end

  defp finish(horde), do: horde

  defp land_held(project, peon) do
    case Ship.land_held(project, peon.chat_id) do
      {:ok, _change} -> :ok
      _ -> :ok
    end
  end

  defp interrupt(%Peon{chat_id: nil}), do: :ok

  defp interrupt(%Peon{chat_id: id}) do
    # Not from inside a broadcast the chat itself may be waiting on.
    Task.Supervisor.start_child(Burrow.TaskSupervisor, fn -> Chat.interrupt(id) end)
    :ok
  end

  # Updates a peon; `:log` and `:tone` add a line to what it did.
  defp set(peon, fields) do
    {line, fields} = Keyword.pop(fields, :log)
    {tone, fields} = Keyword.pop(fields, :tone)

    log =
      if line,
        do:
          peon.log ++
            [
              %{"at" => DateTime.utc_now(:second) |> DateTime.to_iso8601(), "text" => line}
              |> tone(tone)
            ],
        else: peon.log

    peon |> Ecto.Changeset.change([log: log] ++ fields) |> Repo.update!()
  end

  defp tone(line, nil), do: line
  defp tone(line, tone), do: Map.put(line, "tone", tone)

  defp reload(horde), do: get!(horde.id)

  defp changed(horde), do: horde |> reload() |> broadcast()

  defp broadcast(%Horde{} = horde) do
    Projects.broadcast(horde.project_id, "hordes", {:horde, horde.id})
    horde
  end

  ## Tickets and what waits on what

  @doc """
  Whether a queued peon can start: every ticket it waits on shipped, or
  was skipped to let it go ahead.
  """
  def ready?(horde, peon),
    do: Enum.all?(waits_on(horde, peon), &(&1.status in ~w(shipped skipped)))

  @doc "The peons whose tickets `peon` waits on."
  def waits_on(horde, peon), do: Enum.filter(horde.peons, &(&1.ticket && &1.ticket in peon.deps))

  @doc "The peons that wait on `peon`, directly or through others."
  def waiting(horde, peon), do: waiting(horde, [peon], MapSet.new())

  defp waiting(_horde, [], seen), do: seen |> MapSet.to_list() |> Enum.sort_by(& &1.n)

  defp waiting(horde, [peon | rest], seen) do
    next =
      for p <- horde.peons,
          peon.ticket && peon.ticket in p.deps,
          not MapSet.member?(seen, p),
          do: p

    waiting(horde, rest ++ next, Enum.reduce(next, seen, &MapSet.put(&2, &1)))
  end

  @doc """
  Each peon's wave, by its n: 1 for one that waits on nothing in the
  horde, else one more than the latest wave it waits on.
  """
  def waves(horde) do
    Enum.reduce(horde.peons, %{}, fn peon, acc -> wave(horde, peon, acc, []) end)
  end

  defp wave(_horde, %{n: n}, acc, _path) when is_map_key(acc, n), do: acc

  defp wave(horde, peon, acc, path) do
    deps = for p <- waits_on(horde, peon), p.n not in path, do: p
    acc = Enum.reduce(deps, acc, &wave(horde, &1, &2, [peon.n | path]))
    Map.put(acc, peon.n, 1 + Enum.reduce(deps, 0, &max(acc[&1.n] || 0, &2)))
  end

  ## For the screen

  @doc """
  What the horde's peons shipped, in their order: `[%{peon, change, files}]`,
  each file `%{path, diff}`, its unified diff against the change's parent.
  """
  def changes(project, horde) do
    dir = Projects.repo_dir(project)

    for %{change_id: id} = peon <- horde.peons,
        id != nil,
        change = Totem.Repo.change(dir, id),
        change != nil do
      before = if change.parent, do: Totem.Repo.tree(dir, change.parent), else: %{}

      files =
        for {path, hash} <- change.files do
          old = before[path] && Totem.Repo.blob(dir, before[path])
          new = if hash != :deleted, do: Totem.Repo.blob(dir, hash)
          %{path: path, diff: old |> Totem.Diff.lines(new) |> Totem.Diff.format()}
        end

      %{peon: peon, change: change, files: files}
    end
  end

  @doc """
  Counts by status, and how the horde stands in words:
  `%{counts, shipped, total, text, sub, tone}`.
  """
  def summary(%Horde{} = horde) do
    counts = Enum.frequencies_by(horde.peons, & &1.status)
    n = &Map.get(counts, &1, 0)
    total = length(horde.peons)
    working = n.("working") + n.("checking") + n.("fixing") + n.("retrying")
    min = minutes(horde)

    {text, sub, tone} =
      cond do
        horde.status == "stopped" ->
          {"Horde stopped", "#{n.("shipped")} shipped", "idle"}

        horde.status == "done" ->
          {"Horde done", "#{n.("shipped")} shipped in #{min} min", "ok"}

        horde.paused_by == "main" ->
          {"Paused itself: main is red", "Peons keep working, nothing merges", "warn"}

        horde.paused_by == "errors" ->
          {"Paused itself: errors after a ship", "Peons keep working, nothing merges", "warn"}

        horde.status == "paused" ->
          {"Shipping paused", "Peons keep working, nothing merges", "warn"}

        working + n.("queued") == 0 and n.("needs_you") + n.("held") > 0 ->
          waits =
            [{n.("needs_you"), "stuck"}, {n.("held"), "ready to merge"}]
            |> Enum.filter(&(elem(&1, 0) > 0))
            |> Enum.map_join(" · ", fn {count, what} -> "#{count} #{what}" end)

          {"Waiting on you", "#{n.("shipped")} shipped · #{waits}", "warn"}

        true ->
          ready = if n.("held") > 0, do: " · #{n.("held")} ready to merge", else: ""
          {"#{working} working", "#{n.("shipped")} shipped#{ready} · #{min} min", "working"}
      end

    %{counts: counts, shipped: n.("shipped"), total: total, text: text, sub: sub, tone: tone}
  end

  defp minutes(%Horde{started_at: nil}), do: 0

  defp minutes(%Horde{started_at: started, finished_at: finished}),
    do: div(DateTime.diff(finished || DateTime.utc_now(), started), 60)
end
