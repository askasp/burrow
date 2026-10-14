defmodule PeonCore.Tree do
  @moduledoc """
  A tree is a map of path => blob hash. A changeset's tree is its parent's tree
  with the changeset's file changes applied.
  """

  alias PeonCore.Blob

  @type t :: %{String.t() => Blob.hash()}
  @type change :: {String.t(), Blob.hash() | :deleted}

  @spec apply_changes(t(), [change()]) :: t()
  def apply_changes(tree, changes) do
    Enum.reduce(changes, tree, fn
      {path, :deleted}, acc -> Map.delete(acc, path)
      {path, hash}, acc -> Map.put(acc, path, hash)
    end)
  end

  @doc "The changes that turn tree `from` into tree `to`, sorted by path."
  @spec changes(t(), t()) :: [change()]
  def changes(from, to) do
    deleted = for {path, _} <- from, not Map.has_key?(to, path), do: {path, :deleted}
    upserted = for {path, hash} <- to, Map.get(from, path) != hash, do: {path, hash}
    Enum.sort(deleted ++ upserted)
  end

  @spec changed_paths(t(), t()) :: MapSet.t(String.t())
  def changed_paths(from, to) do
    changes(from, to) |> MapSet.new(&elem(&1, 0))
  end

  @doc """
  Builds a tree from file contents on disk under `root`. Returns the tree and a
  map of hash => content for the blobs it references.
  """
  @spec from_dir(Path.t(), (String.t() -> boolean())) :: {t(), %{Blob.hash() => binary()}}
  def from_dir(root, ignore? \\ fn _ -> false end) do
    root
    |> Path.join("**")
    |> Path.wildcard(match_dot: true)
    |> Enum.filter(&File.regular?/1)
    |> Enum.map(&Path.relative_to(&1, root))
    |> Enum.reject(ignore?)
    |> Enum.reduce({%{}, %{}}, fn path, {tree, blobs} ->
      content = File.read!(Path.join(root, path))
      hash = Blob.hash(content)
      {Map.put(tree, path, hash), Map.put(blobs, hash, content)}
    end)
  end
end
