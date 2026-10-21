defmodule Totem.Merge do
  @moduledoc """
  Three-way line merge: two edits of the same base text combine when they
  change different lines. Edits to the same lines conflict, unless both
  sides made the very same edit.
  """

  @doc "Merges `ours` and `theirs`, both edits of `base`: `{:ok, text}` or `{:conflict, lines}`."
  @spec merge3(String.t(), String.t(), String.t()) ::
          {:ok, String.t()} | {:conflict, [pos_integer()]}
  def merge3(base, ours, theirs) do
    cond do
      ours == theirs or theirs == base -> {:ok, ours}
      ours == base -> {:ok, theirs}
      true -> merge_lines(split(base), split(ours), split(theirs))
    end
  end

  defp merge_lines(base, ours, theirs) do
    hunks =
      (Enum.map(hunks(base, ours), &{:ours, &1}) ++ Enum.map(hunks(base, theirs), &{:theirs, &1}))
      |> Enum.sort_by(fn {side, {start, len, _}} -> {start, len, side} end)

    {chosen, conflicts} =
      hunks
      |> group()
      |> Enum.reduce({[], []}, fn group, {chosen, conflicts} ->
        case pick(group) do
          {:ok, picked} -> {chosen ++ picked, conflicts}
          :conflict -> {chosen, conflicts ++ [first_line(group)]}
        end
      end)

    if conflicts == [],
      do: {:ok, chosen |> apply_hunks(base) |> Enum.join("\n")},
      else: {:conflict, conflicts}
  end

  # Edits as {base start, base lines replaced, new lines}, from a line diff.
  defp hunks(base, new) do
    {hunks, pending, _at} =
      List.myers_difference(base, new)
      |> Enum.reduce({[], nil, 0}, fn
        {:eq, lines}, {hunks, pending, at} ->
          {flush(hunks, pending), nil, at + length(lines)}

        {:del, lines}, {hunks, pending, at} ->
          {hunks, grow(pending, at, length(lines), []), at + length(lines)}

        {:ins, lines}, {hunks, pending, at} ->
          {hunks, grow(pending, at, 0, lines), at}
      end)

    Enum.reverse(flush(hunks, pending))
  end

  defp grow(nil, at, deleted, inserted), do: {at, deleted, inserted}

  defp grow({start, len, lines}, _at, deleted, inserted),
    do: {start, len + deleted, lines ++ inserted}

  defp flush(hunks, nil), do: hunks
  defp flush(hunks, hunk), do: [hunk | hunks]

  # Hunks touching the same base lines (or inserting at the same place) form a group.
  defp group(hunks) do
    hunks
    |> Enum.reduce([], fn {_side, {start, len, _}} = hunk, groups ->
      case groups do
        [{gs, ge, members} | rest] when start < ge or start == gs ->
          [{gs, max(ge, start + len), [hunk | members]} | rest]

        _ ->
          [{start, start + len, [hunk]} | groups]
      end
    end)
    |> Enum.reverse()
    |> Enum.map(fn {_gs, _ge, members} -> Enum.reverse(members) end)
  end

  defp pick(group) do
    {ours, theirs} = Enum.split_with(group, &(elem(&1, 0) == :ours))
    ours = Enum.map(ours, &elem(&1, 1))
    theirs = Enum.map(theirs, &elem(&1, 1))

    cond do
      theirs == [] -> {:ok, ours}
      ours == [] or ours == theirs -> {:ok, theirs}
      true -> :conflict
    end
  end

  defp first_line([{_side, {start, _, _}} | _]), do: start + 1

  defp apply_hunks(hunks, base) do
    {out, at} =
      Enum.reduce(hunks, {[], 0}, fn {start, len, lines}, {out, at} ->
        {out ++ Enum.slice(base, at, start - at) ++ lines, start + len}
      end)

    out ++ Enum.drop(base, at)
  end

  defp split(text), do: String.split(text, "\n")
end
