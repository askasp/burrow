defmodule Totem.Ignore do
  @moduledoc """
  Paths that are never part of an app's code: build output, deps, local
  databases and anything listed in an ignore file (one glob per line, `#` for
  comments).
  """

  @builtin [
    "_build/**",
    "deps/**",
    ".git/**",
    # Totem's own store
    ".totem/**",
    "**.db",
    "**.db-*",
    "node_modules/**",
    "erl_crash.dump",
    # Built from assets/
    "priv/static/assets/**",
    "priv/static/cache_manifest.json",
    "cover/**",
    "doc/**",
    "tmp/**"
  ]

  @doc """
  Returns a predicate for `Totem.Tree.from_dir/2`.

  Options:
    * `:file` - the ignore file under `root` (default `".totemignore"`)
    * `:extra` - globs to ignore on top of the built-in ones
  """
  @spec matcher(Path.t(), keyword()) :: (String.t() -> boolean())
  def matcher(root, opts \\ []) do
    file = Keyword.get(opts, :file, ".totemignore")
    globs = @builtin ++ Keyword.get(opts, :extra, []) ++ read(Path.join(root, file))
    &Totem.Glob.matches?(&1, globs)
  end

  @doc "True for paths that are never code, whatever the ignore file says."
  @spec builtin?(String.t()) :: boolean()
  def builtin?(path), do: Totem.Glob.matches?(path, @builtin)

  defp read(path) do
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
