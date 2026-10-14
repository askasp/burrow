defmodule PeonCore.Ignore do
  @moduledoc """
  Paths that are never stored in Peon: build output, deps, local databases and
  anything listed in `.peonignore` (one glob per line, `#` for comments).
  """

  @builtin [
    "_build/**",
    "deps/**",
    ".peon/**",
    ".opencode/**",
    ".git/**",
    "**.db",
    "**.db-*",
    "node_modules/**",
    "erl_crash.dump"
  ]

  @doc "Returns a predicate for `PeonCore.Tree.from_dir/2`, reading `.peonignore` under `root`."
  @spec matcher(Path.t()) :: (String.t() -> boolean())
  def matcher(root) do
    globs = @builtin ++ read_peonignore(Path.join(root, ".peonignore"))
    &PeonCore.Policy.matches?(&1, globs)
  end

  @doc "True for paths that are never stored, whatever `.peonignore` says."
  @spec builtin?(String.t()) :: boolean()
  def builtin?(path), do: PeonCore.Policy.matches?(path, @builtin)

  defp read_peonignore(path) do
    case File.read(path) do
      {:ok, content} ->
        content
        |> String.split("\n", trim: true)
        |> Enum.map(&String.trim/1)
        |> Enum.reject(&(&1 == "" or String.starts_with?(&1, "#")))
        |> Enum.map(&String.trim_trailing(&1, "/"))
        |> Enum.flat_map(&[&1, &1 <> "/**"])

      {:error, _} ->
        []
    end
  end
end
