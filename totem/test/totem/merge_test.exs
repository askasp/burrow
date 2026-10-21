defmodule Totem.MergeTest do
  use ExUnit.Case, async: true

  import Totem.Merge

  @base "a\nb\nc\nd\ne\n"

  test "edits to different lines combine" do
    assert merge3(@base, "A\nb\nc\nd\ne\n", "a\nb\nc\nd\nE\n") == {:ok, "A\nb\nc\nd\nE\n"}

    assert merge3(@base, "a\nb\nc\nd\ne\nf\n", "z\na\nb\nc\nd\ne\n") ==
             {:ok, "z\na\nb\nc\nd\ne\nf\n"}

    # adjacent but not the same lines
    assert merge3(@base, "a\nB\nc\nd\ne\n", "a\nb\nC\nd\ne\n") == {:ok, "a\nB\nC\nd\ne\n"}
    # one side deletes a line, the other edits elsewhere
    assert merge3(@base, "a\nc\nd\ne\n", "a\nb\nc\nd\nE\n") == {:ok, "a\nc\nd\nE\n"}
  end

  test "one side unchanged, or both the same, takes the edit" do
    assert merge3(@base, @base, "x\n") == {:ok, "x\n"}
    assert merge3(@base, "x\n", @base) == {:ok, "x\n"}
    assert merge3(@base, "a\nB\nc\nd\ne\n", "a\nB\nc\nd\ne\n") == {:ok, "a\nB\nc\nd\ne\n"}
  end

  test "edits to the same lines conflict, with the base line where they start" do
    assert merge3(@base, "a\nX\nc\nd\ne\n", "a\nY\nc\nd\ne\n") == {:conflict, [2]}
    # both insert at the same place, differently
    assert merge3(@base, "a\nb\nX\nc\nd\ne\n", "a\nb\nY\nc\nd\ne\n") == {:conflict, [3]}
    # one edits a line the other deletes
    assert merge3(@base, "a\nX\nc\nd\ne\n", "a\nc\nd\ne\n") == {:conflict, [2]}
  end
end
