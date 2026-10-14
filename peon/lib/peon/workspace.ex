defmodule Peon.Workspace do
  @moduledoc """
  A chat's working directory: a checkout of a changeset that the agent edits
  freely, like a developer's laptop checkout. Nothing in it counts until it is
  submitted (`changes/1` + `Peon.Store.submit/1`).

  The tree the workspace was checked out at (its base) is kept in
  `<dir>/.peon/base.json`. Files Peon doesn't track (deps, _build, databases,
  `.peon/`) are ignored.
  """

  alias Peon.Code
  alias PeonCore.{Blob, Tree}

  @doc "Writes the tree of `changeset_id` into an empty or new `dir`."
  def checkout(dir, changeset_id) do
    tree = Code.tree(changeset_id)
    Enum.each(tree, fn {path, hash} -> write(dir, path, hash) end)
    write_base(dir, changeset_id, tree)
  end

  def checked_out?(dir), do: File.exists?(base_path(dir))

  @doc """
  Makes `dir` match `changeset_id`, writing only files that differ from the
  previous base. For directories only Peon writes to, like the check
  workspace, where reusing deps and _build matters.
  """
  def reset(dir, changeset_id) do
    target = Code.tree(changeset_id)
    base = if checked_out?(dir), do: read_base(dir)["tree"], else: %{}

    Enum.each(Tree.changes(base, target), fn
      {path, :deleted} -> File.rm(Path.join(dir, path))
      {path, hash} -> write(dir, path, hash)
    end)

    write_base(dir, changeset_id, target)
  end

  @doc "The changeset the workspace is based on."
  def base_id(dir), do: read_base(dir)["changeset_id"]

  @doc """
  The agent's changes against the base: `{base_id, [{path, content | :deleted}]}`.
  """
  def changes(dir) do
    %{"changeset_id" => base_id, "tree" => base} = read_base(dir)
    {current, blobs} = Tree.from_dir(dir, PeonCore.Ignore.matcher(dir))

    changes =
      for {path, change} <- Tree.changes(base, current) do
        if change == :deleted, do: {path, :deleted}, else: {path, Map.fetch!(blobs, change)}
      end

    {base_id, changes}
  end

  @doc """
  Moves the workspace onto `target_id` (normally the new main). Files the agent
  hasn't touched are updated; files changed on both sides keep the agent's
  version and are returned as conflicts.
  """
  def rebase(dir, target_id) do
    %{"tree" => base} = read_base(dir)
    target = Code.tree(target_id)
    {current, _blobs} = Tree.from_dir(dir, PeonCore.Ignore.matcher(dir))

    conflicts =
      for {path, change} <- Tree.changes(base, target), reduce: [] do
        conflicts ->
          cond do
            # Untouched locally: take the new version.
            Map.get(current, path) == Map.get(base, path) ->
              if change == :deleted,
                do: File.rm(Path.join(dir, path)),
                else: write(dir, path, change)

              conflicts

            # Changed the same way on both sides.
            Map.get(current, path) == Map.get(target, path) ->
              conflicts

            true ->
              [path | conflicts]
          end
      end

    write_base(dir, target_id, target)
    Enum.reverse(conflicts)
  end

  defp write(dir, path, hash) do
    file = Path.join(dir, path)
    File.mkdir_p!(Path.dirname(file))
    {:ok, content} = Blob.verify(Code.blob(hash), hash)
    File.write!(file, content)
  end

  defp read_base(dir), do: dir |> base_path() |> File.read!() |> Jason.decode!()

  defp write_base(dir, changeset_id, tree) do
    File.mkdir_p!(Path.join(dir, ".peon"))
    File.write!(base_path(dir), Jason.encode!(%{changeset_id: changeset_id, tree: tree}))
  end

  defp base_path(dir), do: Path.join([dir, ".peon", "base.json"])
end
