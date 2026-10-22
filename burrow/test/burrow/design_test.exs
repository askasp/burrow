defmodule Burrow.DesignTest do
  # Boards: main's, a chat's changes to them, and landing them alone.
  use Burrow.DataCase, async: false

  import Burrow.ProjectFixtures

  alias Burrow.{Activity, Chat, Chats, Design, Projects, Ship, Workspace}
  alias Totem.Repo

  setup do
    project = project_fixture()

    history!(project, %{
      "lib/a.ex" => "a\n",
      "design/settings/a.html" => "<!doctype html><title>tabs</title><p>a",
      "design/tokens.css" => "body{}"
    })

    previous = Application.get_env(:burrow, :check_runner)
    on_exit(fn -> Application.put_env(:burrow, :check_runner, previous) end)
    # Boards alone never get checked: any check fails.
    Application.put_env(:burrow, :check_runner, fn _, _, _ -> {"checked", 1} end)
    %{project: project, repo: Projects.repo_dir(project)}
  end

  defp chat(project, repo, files) do
    chat = Chats.create(project.id, "t", "ada")
    dir = Chat.workspace_dir(project, chat.id)
    Workspace.reset(repo, dir, Repo.ref(repo, "main"))

    for {path, content} <- files do
      File.mkdir_p!(Path.dirname(Path.join(dir, path)))
      File.write!(Path.join(dir, path), content)
    end

    chat
  end

  defp phase(project, chat),
    do: Enum.find(Activity.chats(project, MapSet.new()), &(&1.chat.id == chat.id)).phase

  test "a chat sees main's boards with its own changes", %{project: project, repo: repo} do
    fresh = Chats.create_empty(project.id, "ada") |> elem(1)

    assert [%{path: "design/settings/a.html", folder: "settings/", title: "tabs", here?: false}] =
             Design.boards(project, fresh.id)

    chat = chat(project, repo, [{"design/settings/b.html", "<title>sidebar</title>"}])

    assert [
             %{name: "a.html", here?: false},
             %{name: "b.html", title: "sidebar", here?: true}
           ] = Design.boards(project, chat.id)

    assert Design.read(project, chat.id, "settings/b.html") == {:ok, "<title>sidebar</title>"}
    assert Design.read(project, fresh.id, "tokens.css") == {:ok, "body{}"}
  end

  test "nothing outside design/ is read, nor through links", %{project: project, repo: repo} do
    chat = chat(project, repo, [])
    dir = Chat.workspace_dir(project, chat.id)
    File.ln_s!(Path.join(dir, "lib/a.ex"), Path.join(dir, "design/a.html"))

    assert Design.read(project, chat.id, "../lib/a.ex") == {:error, :not_found}
    assert Design.read(project, chat.id, "a.html") == {:error, :not_found}
    assert Enum.map(Design.boards(project, chat.id), & &1.name) == ["a.html"]
  end

  test "what the agent draws, from its tool lines" do
    assert Design.drawn("write /app/design/settings/c.html") == ["design/settings/c.html"]
    assert Design.drawn("apply_patch design/a.html lib/x.ex") == ["design/a.html"]
    assert Design.drawn("read /app/design/a.html") == []
    assert Design.drawn("edit /app/lib/design/x.ex") == []
  end

  test "boards alone land without checks, and the chat goes on", %{project: project, repo: repo} do
    chat = chat(project, repo, [{"design/settings/b.html", "<title>b</title>"}])
    assert Design.pending(project, chat.id) == {:design, 1}

    assert {"The boards landed on main as #2." <> _, false} = Ship.submit(project, chat.id, "b")
    assert Repo.file(repo, "design/settings/b.html") == {:ok, "<title>b</title>"}
    assert phase(project, chat) == "drawn"
    assert Design.pending(project, chat.id) == :none

    # Code in the same chat is checked as always.
    File.write!(Path.join(Chat.workspace_dir(project, chat.id), "lib/a.ex"), "A\n")
    assert Design.pending(project, chat.id) == :code
    assert {"Checks FAILED" <> _, true} = Ship.submit(project, chat.id, "A")
  end

  test "a person submits design; not when the chat changed code", %{project: project, repo: repo} do
    boards = chat(project, repo, [{"design/settings/c.html", "<title>c</title>"}])

    assert {:ok, %{id: 2, intent: "Boards: settings/c.html"}} =
             Ship.submit_design(project, boards.id, "ada")

    code = chat(project, repo, [{"design/x.html", "x"}, {"lib/a.ex", "A\n"}])
    assert Ship.submit_design(project, code.id, "ada") == {:error, :not_design_only}
    assert Repo.ref(repo, "main") == 2
  end
end
