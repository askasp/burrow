defmodule Burrow.WorkspaceTest do
  use ExUnit.Case, async: true

  alias Burrow.Workspace
  alias Totem.{Blob, Repo}

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    repo = Path.join(dir, "repo")

    files = %{
      "lib/a.ex" => "a1\na2\na3\n",
      "lib/b.ex" => "b\n",
      "lib/c.ex" => "c1\nc2\nc3\n"
    }

    tree = Map.new(files, fn {path, content} -> {path, Blob.hash(content)} end)

    {:ok, _} =
      Repo.init(repo, tree, Map.new(files, &{Blob.hash(elem(&1, 1)), elem(&1, 1)}), "Import", "t")

    ws = Path.join(dir, "ws")
    Workspace.reset(repo, ws, 1)
    %{repo: repo, ws: ws}
  end

  test "changes are the edits against the base, ignoring build output and Burrow's files", %{
    ws: ws
  } do
    assert Workspace.base_id(ws) == 1
    assert Workspace.changes(ws) == {1, []}

    File.write!(Path.join(ws, "lib/a.ex"), "changed\n")
    File.rm!(Path.join(ws, "lib/b.ex"))
    File.write!(Path.join(ws, "lib/new.ex"), "new\n")
    File.mkdir_p!(Path.join(ws, "_build/dev"))
    File.write!(Path.join(ws, "_build/dev/x.beam"), "beam")
    File.write!(Path.join(ws, ".peon/preview.log"), "log")

    assert {1, changes} = Workspace.changes(ws)

    assert Enum.sort(changes) == [
             {"lib/a.ex", "changed\n"},
             {"lib/b.ex", :deleted},
             {"lib/new.ex", "new\n"}
           ]
  end

  test "restore puts files back as the base has them", %{repo: repo, ws: ws} do
    File.write!(Path.join(ws, "lib/a.ex"), "changed\n")
    File.write!(Path.join(ws, "lib/new.ex"), "new\n")

    :ok = Workspace.restore(repo, ws, ["lib/a.ex", "lib/new.ex"])
    assert Workspace.changes(ws) == {1, []}
  end

  test "rebase: untouched files take main's version, lines merge, the same lines conflict", %{
    repo: repo,
    ws: ws
  } do
    files = [{"lib/a.ex", "a1\na2\nA3\n"}, {"lib/b.ex", "B\n"}, {"lib/c.ex", "c1\nC2\nc3\n"}]
    {:ok, main} = Repo.commit(repo, 1, files, "main moved", "t")

    File.write!(Path.join(ws, "lib/a.ex"), "A1\na2\na3\n")
    File.write!(Path.join(ws, "lib/c.ex"), "c1\nmine\nc3\n")

    assert Workspace.rebase(repo, ws, main.id) == ["lib/c.ex"]
    assert Workspace.base_id(ws) == main.id
    assert File.read!(Path.join(ws, "lib/b.ex")) == "B\n"
    assert File.read!(Path.join(ws, "lib/a.ex")) == "A1\na2\nA3\n"
    assert File.read!(Path.join(ws, "lib/c.ex")) == "c1\nmine\nc3\n"
    assert File.read!(Path.join(ws, ".peon/main/lib/c.ex")) == "c1\nC2\nc3\n"
  end
end
