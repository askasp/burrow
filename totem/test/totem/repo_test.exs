defmodule Totem.RepoTest do
  use ExUnit.Case, async: true

  alias Totem.{Blob, Repo}

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    files = %{"lib/a.ex" => "a1\na2\na3\n", "lib/b.ex" => "b1\n", "README.md" => "hi\n"}
    tree = Map.new(files, fn {path, content} -> {path, Blob.hash(content)} end)
    blobs = Map.new(files, fn {_path, content} -> {Blob.hash(content), content} end)
    {:ok, first} = Repo.init(dir, tree, blobs, "Import", "test")
    %{dir: dir, first: first}
  end

  test "init once, then reads", %{dir: dir, first: first} do
    assert first.id == 1 and Repo.ref(dir, "main") == 1
    assert Repo.init(dir, %{}, %{}, "again", "test") == {:error, :not_empty}
    assert Repo.file(dir, "lib/b.ex") == {:ok, "b1\n"}
    assert [%{id: 1, intent: "Import"}] = Repo.log(dir)
  end

  test "parallel drafts land one after the other, merging lines", %{dir: dir} do
    {:ok, _} = Repo.put_draft(dir, "x", 1, [{"lib/a.ex", "A1\na2\na3\n"}], intent: "x")
    {:ok, _} = Repo.put_draft(dir, "y", 1, [{"lib/a.ex", "a1\na2\nA3\n"}, {"lib/c.ex", "c\n"}])

    {:ok, x} = Repo.land(dir, "x", "test")
    {:ok, y} = Repo.land(dir, "y", "test")

    assert {x.id, y.id, Repo.ref(dir, "main")} == {2, 3, 3}
    assert Repo.file(dir, "lib/a.ex") == {:ok, "A1\na2\nA3\n"}
    assert Repo.file(dir, "lib/c.ex") == {:ok, "c\n"}
    assert %{status: "landed", change: 2} = Repo.draft(dir, "x")
    assert Repo.contains?(dir, "main", 2)
  end

  test "the same lines changed on both sides conflict", %{dir: dir} do
    {:ok, _} = Repo.put_draft(dir, "x", 1, [{"lib/a.ex", "X\na2\na3\n"}])
    {:ok, _} = Repo.put_draft(dir, "y", 1, [{"lib/a.ex", "Y\na2\na3\n"}, {"lib/b.ex", :deleted}])
    {:ok, _} = Repo.land(dir, "x", "test")

    assert Repo.land(dir, "y", "test") == {:error, {:conflict, ["lib/a.ex"]}}
    assert Repo.ref(dir, "main") == 2
  end

  test "no-op drafts, bad paths and policy are refused", %{dir: dir} do
    assert Repo.put_draft(dir, "x", 1, [{"lib/b.ex", "b1\n"}]) == {:error, :no_changes}
    assert {:error, {:invalid, _}} = Repo.put_draft(dir, "x", 1, [{"../evil", "x"}])

    assert {:error, {:policy, [%{rule: :forbidden_path}]}} =
             Repo.put_draft(dir, "x", 1, [{"AGENTS.md", "x"}],
               policy: [forbidden_paths: ["AGENTS.md"]]
             )
  end

  test "revert undoes a change on the tip; refs move by compare-and-swap", %{dir: dir} do
    {:ok, _} = Repo.put_draft(dir, "x", 1, [{"lib/a.ex", "A1\na2\na3\n"}, {"lib/new.ex", "n\n"}])
    {:ok, _} = Repo.land(dir, "x", "test")
    {:ok, _} = Repo.commit(dir, 2, [{"lib/a.ex", "A1\na2\nA3\n"}], "later", "test")

    {:ok, revert} = Repo.revert(dir, 2, "test")
    assert revert.intent =~ "Revert #2"
    assert Repo.file(dir, "lib/a.ex") == {:ok, "a1\na2\nA3\n"}
    assert Repo.file(dir, "lib/new.ex") == {:error, :not_found}

    assert Repo.move_ref(dir, "prod", 2, nil) == :ok
    assert Repo.move_ref(dir, "prod", 3, nil) == {:error, {:stale, 2}}
    assert Repo.move_ref(dir, "prod", 3, 2) == :ok
    assert Repo.refs(dir) == %{"main" => 4, "prod" => 3}
  end
end
