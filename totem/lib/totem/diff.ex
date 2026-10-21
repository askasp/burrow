defmodule Totem.Diff do
  @moduledoc "Line-based file diffs."

  @type op :: {:eq | :ins | :del, [String.t()]}

  @doc "Diffs two file contents by line. `nil` means the file is absent."
  @spec lines(String.t() | nil, String.t() | nil) :: [op()]
  def lines(old, new) do
    List.myers_difference(split(old), split(new))
  end

  @doc "Renders a diff as unified-style text, keeping `context` lines around changes."
  @spec format([op()], non_neg_integer()) :: String.t()
  def format(ops, context \\ 3) do
    last = length(ops) - 1

    ops
    |> Enum.with_index()
    |> Enum.flat_map(fn
      {{:ins, lines}, _} -> Enum.map(lines, &("+" <> &1))
      {{:del, lines}, _} -> Enum.map(lines, &("-" <> &1))
      {{:eq, lines}, i} -> eq_context(lines, i == 0, i == last, context)
    end)
    |> Enum.join("\n")
  end

  # Unchanged lines: keep `n` after the previous change and `n` before the next,
  # with a "@@" marker where lines between two changes are skipped.
  defp eq_context(lines, first?, last?, n) do
    head = if first?, do: [], else: Enum.take(lines, n)
    tail = if last?, do: [], else: Enum.take(lines, -n)

    kept =
      cond do
        first? and last? -> []
        length(lines) <= 2 * n and not (first? or last?) -> lines
        first? or last? -> head ++ tail
        true -> head ++ [:skip] ++ tail
      end

    Enum.map(kept, fn
      :skip -> "@@"
      line -> " " <> line
    end)
  end

  defp split(nil), do: []
  defp split(""), do: []
  defp split(content), do: String.split(content, "\n")
end
