defmodule Totem.Repo do
  @moduledoc """
  A project's history, the origin every runtime follows: plain files under
  one directory, no database.

      objects/ab/cdef…       contents by hash (`Totem.Store`)
      changes/000041.json    a change on main: parent, intent, who, its files and its tree
      refs/<name>            the change a ref points at: main, and whatever else (prod)
      drafts/<id>.json       work not on main yet: its base, files, status and checks

  Main is one straight line: every change's parent is the change before it,
  so "is #12 in what prod runs" is `12 <= prod`. A draft lands (`land/3`) by
  merging its files onto main's tip, line by line where both changed the same
  file (`Totem.Merge`); only the same lines changed on both sides conflict.

  Writes take a lock per directory, so any number of processes may call in.
  Files are written aside and renamed into place.
  """

  alias Totem.{Merge, Policy, Store, Tree}

  @type change :: %{
          id: pos_integer(),
          parent: pos_integer() | nil,
          intent: String.t(),
          kind: String.t(),
          author: String.t(),
          at: String.t(),
          files: [{String.t(), Totem.Blob.hash() | :deleted}],
          tree: Tree.t(),
          draft: String.t() | nil
        }

  ## Reading

  def empty?(dir), do: ref(dir, "main") == nil

  @spec change(Path.t(), pos_integer()) :: change() | nil
  def change(dir, id) do
    case File.read(change_path(dir, id)) do
      {:ok, json} -> decode_change(JSON.decode!(json))
      {:error, _} -> nil
    end
  end

  @doc "Main's changes, newest first."
  def log(dir, limit \\ 50) do
    case ref(dir, "main") do
      nil -> []
      head -> head..max(head - limit + 1, 1)//-1 |> Enum.map(&change(dir, &1))
    end
  end

  @doc "The tree at change `id`, or main's when nil."
  def tree(dir, id \\ nil) do
    case change(dir, id || ref(dir, "main")) do
      nil -> %{}
      change -> change.tree
    end
  end

  def blob(dir, hash) do
    case Store.get_blob(dir, hash) do
      {:ok, content} -> content
      :error -> nil
    end
  end

  def file(dir, path, at \\ nil) do
    case tree(dir, at) do
      %{^path => hash} -> {:ok, blob(dir, hash)}
      _ -> {:error, :not_found}
    end
  end

  def ref(dir, name) do
    case File.read(Path.join([dir, "refs", name])) do
      {:ok, id} -> String.to_integer(String.trim(id))
      {:error, _} -> nil
    end
  end

  def refs(dir) do
    case File.ls(Path.join(dir, "refs")) do
      {:ok, names} -> for name <- names, into: %{}, do: {name, ref(dir, name)}
      {:error, _} -> %{}
    end
  end

  @doc "Whether change `id` is part of what `ref` points at."
  def contains?(dir, ref, id) do
    at = ref(dir, ref)
    at != nil and id != nil and id <= at
  end

  ## Writing

  @doc "The first change: `tree` with its contents (`blobs`, hash => content). Only once."
  def init(dir, tree, blobs, intent, author) do
    locked(dir, fn ->
      if empty?(dir) do
        Enum.each(blobs, fn {_hash, content} -> Store.put_blob(dir, content) end)
        files = Enum.sort(tree)
        {:ok, write_change(dir, 1, nil, files, tree, intent, "human", author, nil)}
      else
        {:error, :not_empty}
      end
    end)
  end

  @doc """
  Moves (or creates) a ref to change `to`, if it still points at `expected`
  (nil when it doesn't exist yet): `:ok` or `{:error, {:stale, current}}`.
  """
  def move_ref(dir, name, to, expected) do
    locked(dir, fn ->
      current = ref(dir, name)

      cond do
        current != expected -> {:error, {:stale, current}}
        change(dir, to) == nil -> {:error, :not_found}
        true -> Store.write!(Path.join([dir, "refs", name]), Integer.to_string(to))
      end
    end)
  end

  @doc """
  Puts a draft (replacing one with the same id): `files` are
  `{path, content | :deleted}` made against change `base`. Options:
  `:kind` (`"ai"` or `"human"`), `:author`, `:intent`, `:policy` (settings
  for `Totem.Policy`). Files that match the base are dropped; none left is
  `{:error, :no_changes}`.
  """
  def put_draft(dir, id, base, files, opts \\ []) do
    base_tree = tree(dir, base)
    kind = Keyword.get(opts, :kind, "ai")

    files =
      Enum.reject(files, fn
        {path, :deleted} -> not Map.has_key?(base_tree, path)
        {path, content} -> base_tree[path] == Totem.Blob.hash(content)
      end)

    author = if kind == "human", do: :human, else: :ai
    policy = [author: author, settings: Keyword.get(opts, :policy, [])]

    with :ok <- valid_paths(files),
         [_ | _] <- files || {:error, :no_changes},
         {:ok, flags} <- policy_check(files, base_tree, policy) do
      draft = %{
        "id" => id,
        "base" => base,
        "intent" => opts[:intent] || "",
        "kind" => kind,
        "author" => opts[:author] || id,
        "files" => for({path, content} <- files, do: [path, store(dir, content)]),
        "flags" => flags,
        "status" => "open",
        "checks" => %{},
        "change" => nil,
        "at" => now()
      }

      locked(dir, fn -> Store.write!(draft_path(dir, id), JSON.encode!(draft)) end)
      {:ok, decode_draft(draft)}
    else
      [] -> {:error, :no_changes}
      error -> error
    end
  end

  def draft(dir, id) do
    case File.read(draft_path(dir, id)) do
      {:ok, json} -> decode_draft(JSON.decode!(json))
      {:error, _} -> nil
    end
  end

  @doc "Sets a draft's `status` and `checks` (or any other of its fields)."
  def update_draft(dir, id, fields) do
    locked(dir, fn ->
      case File.read(draft_path(dir, id)) do
        {:ok, json} ->
          draft =
            Map.merge(JSON.decode!(json), Map.new(fields, fn {k, v} -> {to_string(k), v} end))

          Store.write!(draft_path(dir, id), JSON.encode!(draft))
          {:ok, decode_draft(draft)}

        {:error, _} ->
          {:error, :not_found}
      end
    end)
  end

  def delete_draft(dir, id), do: File.rm(draft_path(dir, id))

  @doc """
  Lands draft `id` on main as a new change: its files merged onto main's tip
  (`Totem.Merge` where both changed a file). `{:ok, change}`, or
  `{:error, {:conflict, paths}}` when both changed the same lines.
  """
  def land(dir, id, actor) do
    case draft(dir, id) do
      nil ->
        {:error, :not_found}

      draft ->
        result = commit_hashed(dir, draft.base, draft.files, draft.intent, draft.kind, actor, id)

        with {:ok, change} <- result do
          update_draft(dir, id, status: "landed", change: change.id)
          {:ok, change}
        end
    end
  end

  @doc "A change on main straight away: `files` (`{path, content | :deleted}`) made against `base`."
  def commit(dir, base, files, intent, author, kind \\ "human") do
    hashed = for {path, content} <- files, do: {path, store(dir, content)}
    commit_hashed(dir, base, hashed, intent, kind, author, nil)
  end

  @doc "Undoes change `id` on main's tip, as a new change."
  def revert(dir, id, author) do
    change = change(dir, id)
    before = tree(dir, change.parent)
    files = for {path, _} <- change.files, do: {path, before[path] || :deleted}
    commit_hashed(dir, id, files, "Revert ##{id}: #{change.intent}", "human", author, nil)
  end

  # files: {path, hash | :deleted}, written against `base`.
  defp commit_hashed(dir, base, files, intent, kind, author, draft) do
    locked(dir, fn ->
      head = ref(dir, "main")
      tip = tree(dir, head)

      with {:ok, merged} <- merge(dir, tree(dir, base), tip, files),
           [_ | _] = changes <- Tree.changes(tip, merged) || {:error, :no_changes} do
        {:ok, write_change(dir, head + 1, head, changes, merged, intent, kind, author, draft)}
      else
        [] -> {:error, :no_changes}
        error -> error
      end
    end)
  end

  defp merge(dir, base, tip, files) do
    {tree, conflicts} =
      Enum.reduce(files, {tip, []}, fn {path, theirs}, {tree, conflicts} ->
        theirs = if theirs == :deleted, do: nil, else: theirs

        case merge_file(dir, base[path], tip[path], theirs) do
          {:ok, nil} -> {Map.delete(tree, path), conflicts}
          {:ok, hash} -> {Map.put(tree, path, hash), conflicts}
          :conflict -> {tree, [path | conflicts]}
        end
      end)

    if conflicts == [], do: {:ok, tree}, else: {:error, {:conflict, Enum.reverse(conflicts)}}
  end

  defp merge_file(_dir, base, base, theirs), do: {:ok, theirs}
  defp merge_file(_dir, base, ours, base), do: {:ok, ours}
  defp merge_file(_dir, _base, ours, ours), do: {:ok, ours}

  defp merge_file(dir, base, ours, theirs) when ours != nil and theirs != nil do
    case Merge.merge3(blob(dir, base) || "", blob(dir, ours), blob(dir, theirs)) do
      {:ok, text} -> {:ok, Store.put_blob(dir, text)}
      {:conflict, _lines} -> :conflict
    end
  end

  defp merge_file(_dir, _base, _ours, _theirs), do: :conflict

  defp write_change(dir, id, parent, files, tree, intent, kind, author, draft) do
    change = %{
      "id" => id,
      "parent" => parent,
      "intent" => intent,
      "kind" => kind,
      "author" => author,
      "at" => now(),
      "files" =>
        for({path, hash} <- files, do: [path, if(hash == :deleted, do: nil, else: hash)]),
      "tree" => tree,
      "draft" => draft
    }

    Store.write!(change_path(dir, id), JSON.encode!(change))
    Store.write!(Path.join([dir, "refs", "main"]), Integer.to_string(id))
    decode_change(change)
  end

  defp policy_check(files, base_tree, opts) do
    case Policy.check(files, base_tree, opts) do
      {:ok, flags} -> {:ok, Map.new(flags, fn {k, v} -> {to_string(k), v} end)}
      {:error, violations} -> {:error, {:policy, violations}}
    end
  end

  defp valid_paths(files) do
    case Enum.reject(files, &valid_path?(elem(&1, 0))) do
      [] -> :ok
      [{path, _} | _] -> {:error, {:invalid, "invalid path: #{inspect(path)}"}}
    end
  end

  defp valid_path?(path) do
    is_binary(path) and path != "" and Path.type(path) == :relative and String.valid?(path) and
      not Enum.any?(Path.split(path), &(&1 in [".", ".."])) and
      not String.contains?(path, ["\\", <<0>>]) and not Totem.Ignore.builtin?(path)
  end

  defp store(_dir, :deleted), do: nil
  defp store(dir, content), do: Store.put_blob(dir, content)

  defp locked(dir, fun),
    do: :global.trans({{__MODULE__, Path.expand(dir)}, self()}, fun, [node()])

  defp decode_change(map) do
    %{
      id: map["id"],
      parent: map["parent"],
      intent: map["intent"],
      kind: map["kind"],
      author: map["author"],
      at: map["at"],
      files: files(map["files"]),
      tree: map["tree"],
      draft: map["draft"]
    }
  end

  defp decode_draft(map) do
    %{
      id: map["id"],
      base: map["base"],
      intent: map["intent"],
      kind: map["kind"],
      author: map["author"],
      files: files(map["files"]),
      flags: map["flags"],
      status: map["status"],
      checks: map["checks"],
      change: map["change"],
      at: map["at"]
    }
  end

  defp files(list), do: for([path, hash] <- list, do: {path, hash || :deleted})

  defp change_path(dir, id),
    do: Path.join([dir, "changes", String.pad_leading(Integer.to_string(id), 6, "0") <> ".json"])

  defp draft_path(dir, id) do
    unless is_binary(id) and id =~ ~r/\A[\w-]{1,64}\z/,
      do: raise(ArgumentError, "bad draft id: #{inspect(id)}")

    Path.join([dir, "drafts", id <> ".json"])
  end

  defp now, do: DateTime.utc_now() |> DateTime.truncate(:second) |> DateTime.to_iso8601()
end
