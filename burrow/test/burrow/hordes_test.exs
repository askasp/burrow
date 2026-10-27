defmodule Burrow.HordesTest do
  # A horde from plan to done. Peons' checks run through a stand-in for the
  # agent's container (`:check_runner`); without running cells nobody is
  # told anything, so the runner's events are called here by hand.
  use Burrow.DataCase, async: false

  import Burrow.ProjectFixtures

  alias Burrow.{Chat, Chats, Hordes, Projects, Ship, Workspace}
  alias Totem.Repo

  setup do
    project = project_fixture()
    history!(project, %{"lib/a.ex" => "a\n", "lib/b.ex" => "b\n", "lib/c.ex" => "c\n"})
    previous = Application.get_env(:burrow, :check_runner)
    on_exit(fn -> Application.put_env(:burrow, :check_runner, previous) end)
    Application.put_env(:burrow, :check_runner, fn _, _, _ -> {"", 0} end)
    lead = Chats.create(project.id, "Capitalize every file", "ada")
    %{project: project, repo: Projects.repo_dir(project), lead: lead}
  end

  defp tasks(n),
    do: for(i <- 1..n, do: %{"title" => "Task #{i}", "task" => "Do part #{i}"})

  defp peon(horde, n), do: Enum.find(Hordes.get!(horde.id).peons, &(&1.n == n))

  defp statuses(horde), do: Enum.map(Hordes.get!(horde.id).peons, & &1.status)

  # The peon's chat edits `path` in a checkout of main and submits it.
  defp submit!(project, repo, peon, path, content) do
    dir = Chat.workspace_dir(project, peon.chat_id)
    Workspace.reset(repo, dir, Repo.ref(repo, "main"))
    File.write!(Path.join(dir, path), content)
    Ship.submit(project, peon.chat_id, "Change #{path}")
  end

  test "a chat runs one horde at a time", %{project: project, lead: lead} do
    assert {:ok, horde} = Hordes.plan(project, lead.id, tasks(3), 2)
    assert horde.at_once == 2
    assert Enum.map(horde.peons, & &1.title) == ["Task 1", "Task 2", "Task 3"]

    Hordes.start(project, horde)
    assert {:error, "A horde already runs" <> _} = Hordes.plan(project, lead.id, tasks(2))
  end

  test "peons start at_once at a time, ship, and make room for the next", %{
    project: project,
    repo: repo,
    lead: lead
  } do
    {:ok, horde} = Hordes.plan(project, lead.id, tasks(3), 2)
    horde = Hordes.start(project, horde)
    assert statuses(horde) == ["working", "working", "queued"]

    first = peon(horde, 1)
    assert %{horde_id: id, title: "Task 1"} = Chats.get(first.chat_id)
    assert id == horde.id
    assert {"It landed on main" <> _, false} = submit!(project, repo, first, "lib/a.ex", "A\n")
    Hordes.drafted(project, first.chat_id, "landed")
    assert %{status: "shipped", change_id: change} = peon(horde, 1)
    assert change == Repo.ref(repo, "main")
    assert statuses(horde) == ["shipped", "working", "working"]
    assert Hordes.summary(Hordes.get!(horde.id)).text == "2 working"
  end

  test "three failed checks: the peon needs you; a hint sends it back to work", %{
    project: project,
    lead: lead
  } do
    {:ok, horde} = Hordes.plan(project, lead.id, tasks(2), 2)
    horde = Hordes.start(project, horde)
    chat_id = peon(horde, 1).chat_id

    for _ <- 1..2 do
      Hordes.drafted(project, chat_id, "checking")
      Hordes.drafted(project, chat_id, "failed")
    end

    assert %{status: "fixing", fails: 2} = peon(horde, 1)
    Hordes.drafted(project, chat_id, "failed")
    assert %{status: "needs_you", fails: 3} = peon(horde, 1)
    assert List.last(peon(horde, 1).log)["text"] == "Stuck after 3 tries. Needs you."

    Hordes.retry(project, peon(horde, 1), "Default to []")
    assert %{status: "working", fails: 0} = peon(horde, 1)
    assert List.last(peon(horde, 1).log)["text"] == "Tried again with a hint: Default to []"
  end

  test "an agent that stops without shipping needs you; skipping lets the horde finish", %{
    project: project,
    repo: repo,
    lead: lead
  } do
    {:ok, horde} = Hordes.plan(project, lead.id, tasks(2), 2)
    horde = Hordes.start(project, horde)

    Hordes.idle(project, peon(horde, 1).chat_id)
    assert peon(horde, 1).status == "needs_you"

    second = peon(horde, 2)
    submit!(project, repo, second, "lib/b.ex", "B\n")
    Hordes.drafted(project, second.chat_id, "landed")
    assert Hordes.summary(Hordes.get!(horde.id)).text == "Waiting on you"

    Hordes.skip(project, peon(horde, 1))
    assert %{status: "done", finished_at: %DateTime{}} = Hordes.get!(horde.id)
    assert Hordes.summary(Hordes.get!(horde.id)).text == "Horde done"
  end

  test "while paused, a passed change is held; it lands when shipping resumes", %{
    project: project,
    repo: repo,
    lead: lead
  } do
    {:ok, horde} = Hordes.plan(project, lead.id, tasks(2), 2)
    horde = Hordes.start(project, horde)
    main = Repo.ref(repo, "main")

    # Main went red: the horde pauses itself.
    Hordes.main_checked(project, %{status: "failed", change_id: main})
    assert %{status: "paused", paused_by: "main"} = Hordes.get!(horde.id)

    first = peon(horde, 1)

    assert {"The checks passed. Your horde paused shipping" <> _, false} =
             submit!(project, repo, first, "lib/a.ex", "A\n")

    assert %{status: "held"} = Repo.draft(repo, first.chat_id)
    assert Repo.ref(repo, "main") == main
    Hordes.drafted(project, first.chat_id, "held")
    assert peon(horde, 1).status == "held"

    # Main is green again: the horde resumes and the held change lands.
    Hordes.main_checked(project, %{status: "passed", change_id: main})
    assert %{status: "landed", change: landed} = Repo.draft(repo, first.chat_id)
    assert Repo.ref(repo, "main") == landed
    Hordes.drafted(project, first.chat_id, "landed")
    assert %{status: "shipped", change_id: ^landed} = peon(horde, 1)
    assert Hordes.get!(horde.id).status == "running"
  end

  test "a person's pause holds too, and only they resume it", %{project: project, lead: lead} do
    {:ok, horde} = Hordes.plan(project, lead.id, tasks(2), 1)
    horde = horde |> then(&Hordes.start(project, &1)) |> Hordes.pause("you")
    assert Hordes.hold?(project, peon(horde, 1).chat_id)
    Hordes.main_checked(project, %{status: "passed", change_id: 1})
    assert Hordes.get!(horde.id).status == "paused"
    assert Hordes.summary(Hordes.get!(horde.id)).text == "Shipping paused"

    horde = Hordes.resume(project, Hordes.get!(horde.id))
    assert horde.status == "running"
    refute Hordes.hold?(project, peon(horde, 1).chat_id)
  end

  test "stopping keeps the peons' chats; with revert, what shipped comes out", %{
    project: project,
    repo: repo,
    lead: lead
  } do
    {:ok, horde} = Hordes.plan(project, lead.id, tasks(3), 2)
    horde = Hordes.start(project, horde)

    first = peon(horde, 1)
    submit!(project, repo, first, "lib/a.ex", "A\n")
    Hordes.drafted(project, first.chat_id, "landed")
    assert Repo.file(repo, "lib/a.ex") == {:ok, "A\n"}

    horde = Hordes.stop(project, Hordes.get!(horde.id), true)
    assert horde.status == "stopped"
    assert statuses(horde) == ["reverted", "stopped", "stopped"]
    assert Repo.file(repo, "lib/a.ex") == {:ok, "a\n"}
    assert Chats.get(peon(horde, 2).chat_id)
  end

  test "new errors where its ships run pause the horde; fixed, it goes on", %{
    project: project,
    repo: repo,
    lead: lead
  } do
    {:ok, horde} = Hordes.plan(project, lead.id, tasks(2), 2)
    horde = Hordes.start(project, horde)
    first = peon(horde, 1)
    submit!(project, repo, first, "lib/a.ex", "A\n")
    Hordes.drafted(project, first.chat_id, "landed")
    shipped = peon(horde, 1).change_id

    # An error from before the horde's ships doesn't pause it.
    Hordes.errors(project, %{change_id: shipped - 1})
    assert Hordes.get!(horde.id).status == "running"

    incident =
      Burrow.Repo.insert!(%Burrow.Incidents{
        project_id: project.id,
        env: "staging",
        fingerprint: "boom",
        title: "RuntimeError: boom",
        change_id: shipped,
        last_seen_at: DateTime.utc_now(:second)
      })

    Hordes.errors(project, incident)
    horde = Hordes.get!(horde.id)
    assert %{status: "paused", paused_by: "errors"} = horde
    assert [%{title: "RuntimeError: boom"}] = Hordes.errors_of(horde)
    assert Hordes.summary(horde).text == "Paused itself: errors after a ship"

    Burrow.Incidents.resolve(incident)
    Hordes.errors_fixed(project)
    assert Hordes.get!(horde.id).status == "running"
  end

  test "a horde that ships for review holds every passed peon until it is merged", %{
    project: project,
    repo: repo,
    lead: lead
  } do
    Chats.pick_shipping(lead, "review")

    {:ok, horde} =
      Hordes.plan(project, lead.id, tasks(1) ++ [%{"title" => "B", "task" => "b"}], 2)

    horde = Hordes.start(project, horde)
    first = peon(horde, 1)
    assert %{shipping: "review"} = Chats.get(first.chat_id)

    assert {"The checks passed. The user reviews" <> _, false} =
             submit!(project, repo, first, "lib/a.ex", "A\n")

    Hordes.drafted(project, first.chat_id, "held")
    assert peon(horde, 1).status == "held"
    assert Hordes.summary(Hordes.get!(horde.id)).sub =~ "1 ready to merge"

    # Resuming a pause doesn't merge what waits for review.
    horde = Hordes.get!(horde.id) |> Hordes.pause("you") |> then(&Hordes.resume(project, &1))
    assert %{status: "held"} = Repo.draft(repo, first.chat_id)

    Hordes.merge_ready(project, horde)
    assert %{status: "landed", change: change} = Repo.draft(repo, first.chat_id)
    assert Repo.ref(repo, "main") == change
  end

  test "a stuck peon retries on a bigger model; the horde's changes show their diffs", %{
    project: project,
    repo: repo,
    lead: lead
  } do
    {:ok, horde} = Hordes.plan(project, lead.id, tasks(2), 2)
    horde = Hordes.start(project, horde)
    Hordes.idle(project, peon(horde, 1).chat_id)

    Hordes.retry(project, peon(horde, 1), nil, {"anthropic/claude-opus", "max"})
    assert %{model: "anthropic/claude-opus", effort: "max"} = Chats.get(peon(horde, 1).chat_id)
    assert List.last(peon(horde, 1).log)["text"] == "Tried again on anthropic/claude-opus"

    second = peon(horde, 2)
    submit!(project, repo, second, "lib/b.ex", "B\n")
    Hordes.drafted(project, second.chat_id, "landed")

    assert [%{peon: %{n: 2}, files: [%{path: "lib/b.ex", diff: "-b\n+B" <> _}]}] =
             Hordes.changes(project, Hordes.get!(horde.id))
  end

  test "a queue runs as a horde: tickets wait on what they need and close as they ship", %{
    project: project,
    repo: repo,
    lead: lead
  } do
    dir = Chat.tickets_dir(project, lead.id)

    client =
      tk(dir, ["create", "Regenerate the client", "-d", "From the spec", "--tags", "think:high"])

    a = tk(dir, ["create", "Move page a"])
    b = tk(dir, ["create", "Move page b"])
    c = tk(dir, ["create", "Polish page a"])
    tk(dir, ["dep", a, client])
    tk(dir, ["dep", b, client])
    tk(dir, ["dep", c, a])
    Chats.pick_horde(lead, 3)

    assert {:ok, horde} = Hordes.run_queue(project, lead.id)
    assert horde.at_once == 3

    assert Enum.map(horde.peons, &{&1.ticket, &1.status}) ==
             [{client, "working"}, {a, "queued"}, {b, "queued"}, {c, "queued"}]

    assert Hordes.waves(horde) == %{1 => 1, 2 => 2, 3 => 2, 4 => 3}
    assert %{task: "From the spec"} = peon(horde, 1)
    assert status(dir, client) == "in_progress"

    first = peon(horde, 1)
    submit!(project, repo, first, "lib/a.ex", "A\n")
    Hordes.drafted(project, first.chat_id, "landed")
    assert status(dir, client) == "closed"
    assert statuses(horde) == ["shipped", "working", "working", "queued"]

    # Skipping a ticket and what waits on it leaves their tickets open.
    Hordes.skip(project, peon(horde, 2), true)
    assert statuses(horde) == ["shipped", "skipped", "working", "skipped"]
    assert status(dir, a) == "open" and status(dir, c) == "open"

    Hordes.stop(project, Hordes.get!(horde.id))
    assert status(dir, b) == "open"
    assert Hordes.get!(horde.id).status == "stopped"
  end

  defp tk(dir, args) do
    tk = Application.app_dir(:burrow, "priv/tk/tk")
    File.mkdir_p!(dir)
    {out, 0} = System.cmd("bash", [tk | args], cd: Path.dirname(dir), env: [{"TICKETS_DIR", dir}])
    String.trim(out)
  end

  defp status(dir, id), do: Enum.find(Burrow.Tickets.list(dir), &(&1.id == id)).status

  test "each peon thinks as hard as its task needs; stuck, it first tries thinking hardest", %{
    project: project,
    lead: lead
  } do
    assert Hordes.thinking("high", ~w(low medium high)) == "high"
    assert Hordes.thinking("high", ~w(minimal low max)) == "max"
    assert Hordes.thinking("low", ~w(fast)) == nil
    assert Hordes.thinking("medium", []) == nil

    tasks = [
      %{"title" => "Rename", "task" => "a", "thinking" => "low"},
      %{"title" => "Untangle", "task" => "b", "thinking" => "high"}
    ]

    {:ok, horde} = Hordes.plan(project, lead.id, tasks, 2, ~w(low medium high))
    assert Enum.map(horde.peons, & &1.effort) == ["low", "high"]
    horde = Hordes.start(project, horde)
    first = peon(horde, 1)
    assert %{effort: "low"} = Chats.get(first.chat_id)

    for _ <- 1..3, do: Hordes.drafted(project, first.chat_id, "failed")
    assert %{status: "retrying", effort: "high", fails: 0} = peon(horde, 1)

    assert List.last(peon(horde, 1).log)["text"] ==
             "Stuck after 3 tries; trying again, thinking harder (high)"

    assert %{effort: "high"} = Chats.get(first.chat_id)
    assert Hordes.summary(Hordes.get!(horde.id)).text == "2 working"

    # It works again, and gets stuck again: now it needs the user.
    Hordes.busy(project, first.chat_id)
    assert peon(horde, 1).status == "working"
    Hordes.idle(project, first.chat_id)
    assert %{status: "needs_you"} = peon(horde, 1)

    # One that already thinks hardest needs the user at once.
    Hordes.idle(project, peon(horde, 2).chat_id)
    assert %{status: "needs_you", effort: "high"} = peon(horde, 2)
  end

  test "sync catches up with drafts that moved while nobody followed the horde", %{
    project: project,
    repo: repo,
    lead: lead
  } do
    {:ok, horde} = Hordes.plan(project, lead.id, tasks(3), 3)
    horde = Hordes.start(project, horde)
    submit!(project, repo, peon(horde, 1), "lib/a.ex", "A\n")

    Application.put_env(:burrow, :check_runner, fn _, _, _ -> {"boom", 1} end)
    submit!(project, repo, peon(horde, 2), "lib/b.ex", "B\n")

    horde = Hordes.sync(project, Hordes.get!(horde.id))
    assert %{status: "shipped", change_id: 2} = peon(horde, 1)
    assert peon(horde, 2).status == "fixing"
    assert peon(horde, 3).status == "working"
  end
end
