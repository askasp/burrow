defmodule PeonCore.BlobTreeTest do
  use ExUnit.Case, async: true

  alias PeonCore.{Blob, Tree}

  test "blob hash is sha256 hex and survives compression" do
    assert Blob.hash("") == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855"
    assert "abc" |> Blob.compress() |> Blob.decompress() == "abc"
    assert Blob.verify("abc", Blob.hash("abc")) == {:ok, "abc"}
    assert Blob.verify("abd", Blob.hash("abc")) == {:error, :hash_mismatch}
  end

  test "applying changes(from, to) to from yields to" do
    from = %{"a" => "1", "b" => "2", "c" => "3"}
    to = %{"a" => "1", "b" => "9", "d" => "4"}

    changes = Tree.changes(from, to)
    assert changes == [{"b", "9"}, {"c", :deleted}, {"d", "4"}]
    assert Tree.apply_changes(from, changes) == to
    assert Tree.changed_paths(from, to) == MapSet.new(["b", "c", "d"])
  end

  @tag :tmp_dir
  test "from_dir hashes files and honours ignore", %{tmp_dir: dir} do
    File.mkdir_p!(Path.join(dir, "lib"))
    File.mkdir_p!(Path.join(dir, "_build"))
    File.write!(Path.join(dir, "lib/a.ex"), "a")
    File.write!(Path.join(dir, "_build/x"), "x")

    {tree, blobs} = Tree.from_dir(dir, &String.starts_with?(&1, "_build/"))
    assert tree == %{"lib/a.ex" => Blob.hash("a")}
    assert blobs == %{Blob.hash("a") => "a"}
  end
end
