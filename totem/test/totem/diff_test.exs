defmodule Totem.DiffTest do
  use ExUnit.Case, async: true

  alias Totem.Diff

  test "line diff" do
    assert Diff.lines("a\nb\nc", "a\nx\nc") == [eq: ["a"], del: ["b"], ins: ["x"], eq: ["c"]]
    assert Diff.lines(nil, "a") == [ins: ["a"]]
    assert Diff.lines("a", nil) == [del: ["a"]]
  end

  test "format keeps context around changes" do
    old = Enum.map_join(1..10, "\n", &"l#{&1}")
    new = String.replace(old, "l5", "L5")
    text = Diff.lines(old, new) |> Diff.format(1)
    assert text == " l4\n-l5\n+L5\n l6"

    two = String.replace(new, "l9", "L9")
    assert Diff.lines(old, two) |> Diff.format(1) == " l4\n-l5\n+L5\n l6\n@@\n l8\n-l9\n+L9\n l10"
  end
end
