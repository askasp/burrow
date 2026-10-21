defmodule Totem.Glob do
  @moduledoc "Path globs where `*` stays within a segment and `**` spans segments."

  @doc "True when `path` matches any of `globs`."
  @spec matches?(String.t(), [String.t()]) :: boolean()
  def matches?(path, globs), do: Enum.any?(globs, &Regex.match?(regex(&1), path))

  defp regex(glob) do
    body =
      glob
      |> Regex.escape()
      |> String.replace("\\*\\*", "\0")
      |> String.replace("\\*", "[^/]*")
      |> String.replace("\0", ".*")

    Regex.compile!("^" <> body <> "$")
  end
end
