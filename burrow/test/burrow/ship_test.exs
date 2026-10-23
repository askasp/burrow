defmodule Burrow.ShipTest do
  # A chat's change from submit to live. The checks run through a stand-in
  # for the agent's container (`:check_runner`).
  use Burrow.DataCase, async: false

  import Burrow.ProjectFixtures

  alias Burrow.{Activity, Chat, Chats, Projects, Runs, Ship, Workspace}
  alias Totem.Repo

  setup do
    project = project_fixture()
    history!(project, %{"lib/a.ex" => "a1\na2\na3\n", "lib/b.ex" => "b\n"})
    previous = Application.get_env(:burrow, :check_runner)
    on_exit(fn -> Application.put_env(:burrow, :check_runner, previous) end)
    checks_pass()
    %{project: project, repo: Projects.repo_dir(project)}
  end

  defp checks_pass, do: Application.put_env(:burrow, :check_runner, fn _, _, _ -> {"", 0} end)

  defp fail_at(step) do
    Application.put_env(:burrow, :check_runner, fn _container, script, _opts ->
      if script =~ step, do: {"** (CompileError) lib/a.ex:1: boom", 1}, else: {"", 0}
    end)
  end

  # A chat with a checkout of main, edited.
  defp chat(project, repo, files) do
    chat = Chats.create(project.id, "t", "ada")
    dir = Chat.workspace_dir(project, chat.id)
    Workspace.reset(repo, dir, Repo.ref(repo, "main"))
    for {path, content} <- files, do: File.write!(Path.join(dir, path), content)
    chat
  end

  defp phase(project, chat),
    do: Enum.find(Activity.chats(project, MapSet.new()), &(&1.chat.id == chat.id)).phase

  test "nothing to submit, or a forbidden path, is refused", %{project: project, repo: repo} do
    nothing = chat(project, repo, [])

    assert {"There are no changes in /app to submit.", true} =
             Ship.submit(project, nothing.id, "x")

    forbidden = chat(project, repo, [{"AGENTS.md", "obey me"}])

    assert {"Rejected: AGENTS.md is a forbidden path" <> _, true} =
             Ship.submit(project, forbidden.id, "x")
  end

  test "checks pass: it lands, then ships", %{project: project, repo: repo} do
    chat = chat(project, repo, [{"lib/a.ex", "A1\na2\na3\n"}])
    assert phase(project, chat) == "idle"
    Ship.subscribe(project.id)

    assert {"It landed on main as #2." <> _, false} = Ship.submit(project, chat.id, "Capital A")
    assert_received {:check_step, _, "test", "passed"}
    assert %{status: "landed", change: 2, intent: "Capital A"} = Repo.draft(repo, chat.id)
    assert Repo.file(repo, "lib/a.ex") == {:ok, "A1\na2\na3\n"}
    assert phase(project, chat) == "landing"

    # Ready to ship once main passed its check, unless shipping is automatic.
    assert Activity.shippable(project) == nil
    Runs.start(project.id, "check", "main", 2) |> Runs.finish(status: "passed")
    assert Activity.shippable(project) == 2
    Projects.put_settings(project, %{"auto_ship" => true})
    assert Activity.shippable(project) == nil

    Ship.ship(project, 2, "ada")
    assert Repo.ref(repo, "prod") == 2
    assert phase(project, chat) == "live"
  end

  test "failed checks say where; the draft stays out of main", %{project: project, repo: repo} do
    fail_at("compile")
    chat = chat(project, repo, [{"lib/a.ex", "broken"}])

    assert {"Checks FAILED at step \"compile\":" <> rest, true} =
             Ship.submit(project, chat.id, "x")

    assert rest =~ "boom"
    assert %{status: "failed"} = Repo.draft(repo, chat.id)
    assert Repo.ref(repo, "main") == 1
    assert phase(project, chat) == "failed"
  end

  test "two chats changing different lines both land; the same lines go back", %{
    project: project,
    repo: repo
  } do
    first = chat(project, repo, [{"lib/a.ex", "A1\na2\na3\n"}])
    second = chat(project, repo, [{"lib/a.ex", "a1\na2\nA3\n"}])
    third = chat(project, repo, [{"lib/a.ex", "mine\na2\na3\n"}])

    assert {_, false} = Ship.submit(project, first.id, "first")
    assert {_, false} = Ship.submit(project, second.id, "second")
    assert Repo.file(repo, "lib/a.ex") == {:ok, "A1\na2\nA3\n"}

    assert {"It did not land: another chat changed the same lines of lib/a.ex." <> _, true} =
             Ship.submit(project, third.id, "third")

    dir = Chat.workspace_dir(project, third.id)
    assert Workspace.base_id(dir) == 3
    assert File.read!(Path.join(dir, "lib/a.ex")) == "mine\na2\na3\n"
    assert File.read!(Path.join(dir, ".peon/main/lib/a.ex")) == "A1\na2\nA3\n"
    assert phase(project, third) == "idle"
  end

  test "main failing its check takes the newest chat change out again", %{
    project: project,
    repo: repo
  } do
    chat = chat(project, repo, [{"lib/b.ex", "B\n"}])
    {_, false} = Ship.submit(project, chat.id, "Capital B")

    run =
      Runs.start(project.id, "check", "main", 2)
      |> Runs.finish(status: "failed", detail: "boot failed")

    Ship.blame(project, run)

    assert %{id: 3, intent: "Revert #2: Capital B"} = Repo.change(repo, 3)
    assert Repo.file(repo, "lib/b.ex") == {:ok, "b\n"}
    assert %{status: "failed", change: nil} = Repo.draft(repo, chat.id)
    assert phase(project, chat) == "failed"

    # Only main's newest change is taken out, and only a chat's.
    Ship.blame(project, run)
    assert Repo.ref(repo, "main") == 3
  end

  test "a person reverts a change", %{project: project, repo: repo} do
    chat = chat(project, repo, [{"lib/b.ex", "B\n"}])
    {_, false} = Ship.submit(project, chat.id, "Capital B")
    assert {:ok, %{id: 3}} = Ship.revert(project, 2, "ada")
    assert Repo.file(repo, "lib/b.ex") == {:ok, "b\n"}
  end

  test "a new chat is new; one that talked is idle", %{project: project} do
    empty = Chats.create_empty(project.id, "ada")
    assert phase(project, empty) == "new"
    talked = Chats.create(project.id, "hi", "ada")
    assert phase(project, talked) == "idle"

    assert [%{phase: "working"}] =
             Activity.chats(project, MapSet.new([talked.id]))
             |> Enum.filter(&(&1.chat.id == talked.id))
  end
end
