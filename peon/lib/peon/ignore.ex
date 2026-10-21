defmodule Peon.Ignore do
  @moduledoc """
  Paths Peon never stores: `Totem.Ignore`'s, Peon's and the agent's own
  folders, and anything listed in `.peonignore`.
  """

  @extra [".peon/**", ".opencode/**"]

  @doc "Returns a predicate for `Totem.Tree.from_dir/2`, reading `.peonignore` under `root`."
  @spec matcher(Path.t()) :: (String.t() -> boolean())
  def matcher(root), do: Totem.Ignore.matcher(root, file: ".peonignore", extra: @extra)

  @doc "True for paths that are never stored, whatever `.peonignore` says."
  @spec builtin?(String.t()) :: boolean()
  def builtin?(path), do: Totem.Ignore.builtin?(path) or Totem.Glob.matches?(path, @extra)
end
