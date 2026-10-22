defmodule Burrow.Workspace do
  @moduledoc """
  A folder made from the project's history (`Totem.Repo`): a chat's
  checkout, which the agent edits freely, or an environment's app. The
  change it was made from (its base) is kept in `<dir>/.peon/base.json`.
  Files the history doesn't keep (deps, _build, databases, `.peon/`,
  `.opencode/`, what `.peonignore` lists) are left alone.
  """

  alias Totem.{Repo, Tree}

  @doc "What is never part of the app's code in `dir`."
  def ignore(dir),
    do: Totem.Ignore.matcher(dir, file: ".peonignore", extra: [".peon/**", ".opencode/**"])

  def checked_out?(dir), do: File.exists?(base_path(dir))

  def base_id(dir), do: read_base(dir)["change"]

  @doc "The tree `dir` was made from: path => hash."
  def base_tree(dir), do: read_base(dir)["tree"]

  @doc """
  Makes `dir` match change `id` of `repo`, writing only what differs from
  its previous base, so deps and _build stay.
  """
  def reset(repo, dir, id) do
    target = Repo.tree(repo, id)
    base = if checked_out?(dir), do: read_base(dir)["tree"], else: %{}

    for {path, change} <- Tree.changes(base, target) do
      if change == :deleted,
        do: File.rm(Path.join(dir, path)),
        else: write(repo, dir, path, change)
    end

    mark(repo, dir, id)
  end

  @doc "Records that `dir` matches change `id` already (e.g. Totem wrote its files)."
  def mark(repo, dir, id) do
    File.mkdir_p!(Path.join(dir, ".peon"))
    File.write!(base_path(dir), JSON.encode!(%{change: id, tree: Repo.tree(repo, id)}))
  end

  @doc "The edits against the base: `{base_id, [{path, content | :deleted}]}`."
  def changes(dir) do
    %{"change" => base_id, "tree" => base} = read_base(dir)
    {current, blobs} = Tree.from_dir(dir, ignore(dir))

    changes =
      for {path, change} <- Tree.changes(base, current),
          do: {path, if(change == :deleted, do: :deleted, else: Map.fetch!(blobs, change))}

    {base_id, changes}
  end

  @doc "Puts `paths` back as they are in the base (removing those it doesn't have)."
  def restore(repo, dir, paths) do
    base = read_base(dir)["tree"]

    for path <- paths do
      if hash = base[path], do: write(repo, dir, path, hash), else: File.rm(Path.join(dir, path))
    end

    :ok
  end

  @doc """
  Moves `dir` onto change `id`: files the agent didn't touch take the new
  version, files both changed are merged line by line, and where the same
  lines changed the agent's version stays, with the new one in
  `.peon/main/<path>`. Returns those paths.
  """
  def rebase(repo, dir, id) do
    %{"tree" => base} = read_base(dir)
    target = Repo.tree(repo, id)
    {current, blobs} = Tree.from_dir(dir, ignore(dir))
    main = Path.join([dir, ".peon", "main"])
    File.rm_rf!(main)

    conflicts =
      for {path, change} <- Tree.changes(base, target),
          current[path] != target[path],
          reduce: [] do
        conflicts ->
          cond do
            current[path] == base[path] and change == :deleted ->
              File.rm(Path.join(dir, path))
              conflicts

            current[path] == base[path] ->
              write(repo, dir, path, change)
              conflicts

            merged = merge(repo, base[path], blobs[current[path]], change) ->
              File.write!(Path.join(dir, path), merged)
              conflicts

            true ->
              if change != :deleted, do: write(repo, main, path, change)
              [path | conflicts]
          end
      end

    mark(repo, dir, id)
    Enum.reverse(conflicts)
  end

  defp merge(_repo, _base, nil, _theirs), do: nil
  defp merge(_repo, _base, _ours, :deleted), do: nil

  defp merge(repo, base, ours, theirs) do
    case Totem.Merge.merge3((base && Repo.blob(repo, base)) || "", ours, Repo.blob(repo, theirs)) do
      {:ok, text} -> text
      {:conflict, _} -> nil
    end
  end

  defp write(repo, dir, path, hash) do
    file = Path.join(dir, path)
    File.mkdir_p!(Path.dirname(file))
    File.write!(file, Repo.blob(repo, hash))
  end

  defp read_base(dir), do: dir |> base_path() |> File.read!() |> JSON.decode!()

  defp base_path(dir), do: Path.join([dir, ".peon", "base.json"])
end
