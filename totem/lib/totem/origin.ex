defmodule Totem.Origin do
  @moduledoc """
  The app's history in the app itself, for a node that is its own origin
  (`config :totem, origin: true` or `TOTEM_ORIGIN=1`), such as a dev app that
  agents change directly. A `Totem.Repo` in `.totem/repo` (or `:repo_dir`):

    1. agents write drafts against a change of main (`write_draft/4`)
    2. a draft is built and tested in a scratch directory (`check/1`)
    3. landing merges it onto main and loads main's new tree into the app
       with a watch window (`land/1`); if the app takes it badly, the change
       is reverted on main too, so main is always what runs

  Files changed on disk outside Totem are recorded on main as a change of
  their own before anything lands.
  """

  alias Totem.{Check, Repo, Tree}

  def enabled?,
    do:
      Application.get_env(:totem, :origin) == true or System.get_env("TOTEM_ORIGIN") in ~w(1 true)

  def dir do
    Application.get_env(:totem, :repo_dir) || Path.join(Totem.info().store, "repo")
  end

  @doc "Main's id, importing the files on disk as the first change if there is no history yet."
  def head do
    dir = dir()

    if Repo.empty?(dir) do
      %{tree: tree} = Totem.current()
      root = Totem.info().root
      blobs = for {path, hash} <- tree, into: %{}, do: {hash, File.read!(Path.join(root, path))}
      Repo.init(dir, tree, blobs, "Import", "totem")
    end

    Repo.ref(dir, "main")
  end

  @doc "Puts draft `id`: `files` are `{path, content | :deleted}` against change `base` (nil: main)."
  def write_draft(id, base, files, intent) do
    head = head()
    Repo.put_draft(dir(), id, base || head, files, intent: intent, author: id)
  end

  @doc "Builds and tests the draft's tree; records `passed` or `failed` on it."
  def check(id) do
    with %{} = draft <- Repo.draft(dir(), id) || {:error, :not_found} do
      tree = Tree.apply_changes(Repo.tree(dir(), draft.base), draft.files)
      files = Map.new(tree, fn {path, hash} -> {path, Repo.blob(dir(), hash)} end)
      {result, output} = Check.run(Totem.info().root, id, files)
      status = if result == :ok, do: "passed", else: "failed"

      Repo.update_draft(dir(), id,
        status: status,
        checks: %{"output" => String.slice(output, -6000, 6000)}
      )

      {result, output}
    end
  end

  @doc "Lands draft `id` on main and loads it into the app: `{:ok, %{change, mode, …}}` or an error."
  def land(id, opts \\ []) do
    locked(fn ->
      found()
      with {:ok, change} <- Repo.land(dir(), id, "totem"), do: load(change, opts)
    end)
  end

  @doc "Undoes change `id` on main and in the app."
  def revert(id, opts \\ []) do
    locked(fn ->
      found()
      with {:ok, change} <- Repo.revert(dir(), id, "totem"), do: load(change, opts)
    end)
  end

  # Main's new tree into the app. If the app won't have it, main goes back too.
  defp load(change, opts) do
    %{tree: disk} = Totem.current()

    files =
      for {path, hash} <- Tree.changes(disk, change.tree) do
        {path, disk[path], if(hash == :deleted, do: :deleted, else: Repo.blob(dir(), hash))}
      end

    case Totem.apply(files, Keyword.merge([label: "main ##{change.id}"], opts)) do
      {:ok, result} ->
        {:ok, Map.put(result, :change, change.id)}

      {:error, reason} ->
        Repo.revert(dir(), change.id, "totem")
        {:error, reason}
    end
  end

  # What changed on disk outside Totem becomes a change on main.
  defp found do
    head = head()
    %{tree: disk} = Totem.current()
    main = Repo.tree(dir(), head)
    root = Totem.info().root

    files =
      for {path, hash} <- Tree.changes(main, disk),
          do: {path, if(hash == :deleted, do: :deleted, else: File.read!(Path.join(root, path)))}

    if files != [], do: Repo.commit(dir(), head, files, "Found on disk", "totem")
  end

  defp locked(fun), do: :global.trans({{__MODULE__, dir()}, self()}, fun, [node()])
end
