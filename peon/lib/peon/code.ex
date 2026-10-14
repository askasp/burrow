defmodule Peon.Code do
  @moduledoc """
  Read side of the store. Plain queries, safe to call from any process;
  all writes go through `Peon.Store`.
  """

  import Ecto.Query

  alias Peon.Repo
  alias Peon.Store.{Blob, Changeset, ChangesetPath, Ref, TreeCache}
  alias PeonCore.{Diff, Tree}

  @doc "Resolves a ref name or changeset id (`nil` means main)."
  @spec resolve(String.t() | integer() | nil) :: {:ok, Changeset.t()} | {:error, :not_found}
  def resolve(nil), do: resolve("main")
  def resolve(id) when is_integer(id), do: changeset(id)

  def resolve(at) when is_binary(at) do
    case Integer.parse(at) do
      {id, ""} ->
        changeset(id)

      _ ->
        case Repo.get(Ref, at) do
          nil -> {:error, :not_found}
          ref -> changeset(ref.changeset_id)
        end
    end
  end

  def changeset(id) do
    case Repo.get(Changeset, id) do
      nil -> {:error, :not_found}
      cs -> {:ok, cs}
    end
  end

  def refs, do: Repo.all(from r in Ref, order_by: r.name)

  def ref(name), do: Repo.get(Ref, name)

  @doc "The tree at a changeset, rebuilt from the nearest cached ancestor when missing."
  @spec tree(integer()) :: Tree.t()
  def tree(changeset_id) do
    case Repo.get(TreeCache, changeset_id) do
      %TreeCache{entries: entries} -> entries
      nil -> rebuild_tree(changeset_id)
    end
  end

  defp rebuild_tree(changeset_id) do
    {base, pending} = collect_uncached(changeset_id, [])

    tree =
      Enum.reduce(pending, base, fn cs, tree ->
        Tree.apply_changes(tree, Changeset.changes(cs))
      end)

    Repo.insert(%TreeCache{changeset_id: changeset_id, entries: tree}, on_conflict: :nothing)
    tree
  end

  defp collect_uncached(nil, acc), do: {%{}, acc}

  defp collect_uncached(id, acc) do
    case Repo.get(TreeCache, id) do
      %TreeCache{entries: entries} ->
        {entries, acc}

      nil ->
        cs = Repo.get!(Changeset, id)
        collect_uncached(cs.parent_id, [cs | acc])
    end
  end

  @spec blob(String.t()) :: binary() | nil
  def blob(hash) do
    case Repo.get(Blob, hash) do
      nil -> nil
      %Blob{content: data} -> PeonCore.Blob.decompress(data)
    end
  end

  @spec file(String.t(), String.t() | integer() | nil) :: {:ok, binary()} | {:error, :not_found}
  def file(path, at) do
    with {:ok, cs} <- resolve(at),
         hash when is_binary(hash) <- Map.get(tree(cs.id), path) do
      {:ok, blob(hash)}
    else
      _ -> {:error, :not_found}
    end
  end

  @doc """
  Searches file contents line by line. Options: `:regex` (treat `query` as a
  regex), `:path` (glob filter), `:limit` (default 200 matches).
  """
  def search(query, at, opts \\ []) do
    limit = Keyword.get(opts, :limit, 200)
    path_glob = Keyword.get(opts, :path)

    with {:ok, matcher} <- matcher(query, Keyword.get(opts, :regex, false)),
         {:ok, cs} <- resolve(at) do
      matches =
        tree(cs.id)
        |> Enum.filter(fn {path, _} ->
          is_nil(path_glob) or PeonCore.Policy.matches?(path, [path_glob])
        end)
        |> Enum.sort()
        |> Stream.flat_map(fn {path, hash} -> search_blob(path, blob(hash), matcher) end)
        |> Enum.take(limit)

      {:ok, matches}
    end
  end

  defp matcher(query, false), do: {:ok, &String.contains?(&1, query)}

  defp matcher(query, true) do
    case Regex.compile(query) do
      {:ok, regex} -> {:ok, &Regex.match?(regex, &1)}
      {:error, {reason, _}} -> {:error, {:bad_regex, to_string(reason)}}
    end
  end

  defp search_blob(path, content, matcher) do
    if String.contains?(content, <<0>>) do
      []
    else
      content
      |> String.split("\n")
      |> Enum.with_index(1)
      |> Enum.filter(fn {line, _} -> matcher.(line) end)
      |> Enum.map(fn {line, n} -> %{path: path, line: n, text: String.slice(line, 0, 300)} end)
    end
  end

  @doc "Changesets that touched `path`, newest first."
  def history(path, limit \\ 50) do
    Repo.all(
      from c in Changeset,
        join: p in ChangesetPath,
        on: p.changeset_id == c.id,
        where: p.path == ^path,
        order_by: [desc: c.id],
        limit: ^limit
    )
  end

  @doc "The newest changesets, newest first."
  def history_all(limit) do
    Repo.all(from c in Changeset, order_by: [desc: c.id], limit: ^limit)
  end

  @doc "Per-file diff between two changesets (or refs)."
  def diff(from, to) do
    with {:ok, a} <- resolve(from), {:ok, b} <- resolve(to) do
      old = tree(a.id)
      new = tree(b.id)

      files =
        for {path, change} <- Tree.changes(old, new) do
          old_content = old[path] && blob(old[path])
          new_content = if change == :deleted, do: nil, else: blob(change)

          %{
            path: path,
            status: diff_status(old_content, new_content),
            diff: Diff.lines(old_content, new_content) |> Diff.format()
          }
        end

      {:ok, files}
    end
  end

  defp diff_status(nil, _), do: "added"
  defp diff_status(_, nil), do: "deleted"
  defp diff_status(_, _), do: "modified"

  @doc "True when `ancestor_id` is `id` or one of its ancestors."
  def ancestor?(ancestor_id, id) do
    %{rows: rows} =
      Repo.query!(
        """
        WITH RECURSIVE anc(id) AS (
          SELECT ?1
          UNION ALL
          SELECT c.parent_id FROM changesets c JOIN anc ON c.id = anc.id
          WHERE c.parent_id IS NOT NULL
        )
        SELECT 1 FROM anc WHERE id = ?2 LIMIT 1
        """,
        [id, ancestor_id]
      )

    rows != []
  end
end
