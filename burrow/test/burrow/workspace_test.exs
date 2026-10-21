defmodule Peon.WorkspaceTest do
  use Peon.DataCase, async: false

  alias Peon.{Code, Store, Workspace}

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    src = Path.join(dir, "src")
    File.mkdir_p!(Path.join(src, "lib"))
    File.write!(Path.join(src, "lib/a.ex"), "a1")
    File.write!(Path.join(src, "lib/b.ex"), "b1")
    {:ok, base} = Store.import_dir(src, "app", "App", %{kind: :human, id: "aksel"})

    ws = Path.join(dir, "ws")
    Workspace.checkout(ws, base.id)
    %{base: base, ws: ws}
  end

  test "changes are the agent's edits against the base, ignoring build output", %{
    base: base,
    ws: ws
  } do
    assert Workspace.changes(ws) == {base.id, []}

    File.write!(Path.join(ws, "lib/a.ex"), "a2")
    File.rm!(Path.join(ws, "lib/b.ex"))
    File.write!(Path.join(ws, "lib/c.ex"), "c1")
    File.mkdir_p!(Path.join(ws, "_build/dev"))
    File.write!(Path.join(ws, "_build/dev/x"), "x")
    File.write!(Path.join(ws, "app_dev.db"), "db")

    assert {_, changes} = Workspace.changes(ws)
    assert Enum.sort(changes) == [{"lib/a.ex", "a2"}, {"lib/b.ex", :deleted}, {"lib/c.ex", "c1"}]
  end

  test "restore puts files back as they are in the base", %{ws: ws} do
    File.write!(Path.join(ws, "lib/a.ex"), "a2")
    File.write!(Path.join(ws, "lib/new.ex"), "n")
    :ok = Workspace.restore(ws, ["lib/a.ex", "lib/new.ex"])
    assert File.read!(Path.join(ws, "lib/a.ex")) == "a1"
    refute File.exists?(Path.join(ws, "lib/new.ex"))
  end

  test "rebase takes main's changes to untouched files and reports conflicts", %{
    base: base,
    ws: ws
  } do
    {:ok, cs} =
      Store.submit(%{
        parent: base.id,
        intent: "change a and b",
        files: [
          %{"path" => "lib/a.ex", "content" => "a-main"},
          %{"path" => "lib/b.ex", "content" => "b-main"}
        ],
        author: %{kind: :human, id: "aksel"}
      })

    {:ok, _} = Store.set_status(cs.id, "passed", %{})
    {:ok, _} = Store.move_ref("main", cs.id, Code.ref("main").version, "aksel")

    File.write!(Path.join(ws, "lib/b.ex"), "b-agent")
    assert Workspace.rebase(ws, cs.id) == ["lib/b.ex"]

    assert File.read!(Path.join(ws, "lib/a.ex")) == "a-main"
    assert File.read!(Path.join(ws, "lib/b.ex")) == "b-agent"
    assert File.read!(Path.join(ws, ".peon/main/lib/b.ex")) == "b-main"
    assert Workspace.changes(ws) == {cs.id, [{"lib/b.ex", "b-agent"}]}
  end
end
