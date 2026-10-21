defmodule Peon.Store do
  @moduledoc """
  The single writer for this project's history. Every insert of changesets and
  every ref move is serialized through this process, inside a transaction.

  History is append-only: blobs and changesets are only inserted (a changeset's
  status, flags, checks and verify are the only fields updated), and refs move
  by compare-and-swap on their version.

  Changes land on main as soon as their checks pass (`land/2`): there is no
  queue in front of main. A changeset written against an older main is rebased
  onto main's tip at land time, unless a path it touches changed in between.
  Tests run on main after landing (`Peon.Verifier`), and deploys are gated on
  those (`Peon.Env`).

  Broadcasts on `Peon.PubSub` topic `"store"`:
    * `{:changeset, id, status}`
    * `{:ref_moved, name, changeset_id, version}`
  """

  use GenServer

  alias Peon.{Code, Project, Repo}
  alias Peon.Store.{Blob, Changeset, ChangesetPath, Event, Ref, TreeCache}
  alias Peon.Policy
  alias Totem.Tree

  @topic "store"
  @open ~w(proposed checking passed)
  @ref_name ~r"\A(main|staging|prod)\z"

  @type author :: %{kind: :human | :ai, id: String.t()}

  def start_link(instance),
    do: GenServer.start_link(__MODULE__, instance, name: Peon.Instance.via(instance, __MODULE__))

  def subscribe, do: Peon.Instance.subscribe(@topic)

  @doc """
  Imports a directory as the project's first changeset and points main at it.
  Only allowed while the project is empty.
  """
  def import_dir(dir, slug, name, author) do
    cond do
      Code.ref("main") ->
        {:error, {:invalid, "project already has history"}}

      not File.dir?(dir) ->
        {:error, {:invalid, "#{dir} is not a directory"}}

      true ->
        {tree, blobs} = Tree.from_dir(dir, Peon.Ignore.matcher(dir))
        import_tree(tree, blobs, slug, name, author)
    end
  end

  @doc "Like `import_dir/4`, for a tree and its blobs (hash => content) built in memory."
  def import_tree(tree, blobs, slug, name, author),
    do:
      GenServer.call(
        Peon.Instance.via(__MODULE__),
        {:import_tree, tree, blobs, slug, name, author},
        :infinity
      )

  @doc """
  Submits a changeset. `attrs`:
    * `:parent` - changeset id the files were written against (must be on main's history)
    * `:intent` - what the change is for
    * `:files` - `[%{"path" => p, "content" => c}]` or `[%{"path" => p, "deleted" => true}]`
    * `:author` - `%{kind: :human | :ai, id: id}`
    * `:approve_destructive` - human confirmation for destructive migrations
    * `:conversation_id` - optional

  When `parent` is behind main and none of its paths changed since, the
  changeset is created on top of main. Otherwise returns `{:conflict, paths}`.
  """
  def submit(attrs),
    do: GenServer.call(Peon.Instance.via(__MODULE__), {:submit, attrs}, :infinity)

  @doc """
  Moves (or creates, with `expected_version` 0) a ref. Options:
    * `:approved_by` - required for prod: the human who approved the move
  """
  def move_ref(name, to, expected_version, actor, opts \\ []),
    do:
      GenServer.call(
        Peon.Instance.via(__MODULE__),
        {:move_ref, name, to, expected_version, actor, opts}
      )

  @doc """
  Puts a passed changeset on main. When main moved since the changeset's
  parent, a rebased copy is created on main's tip (`rebased_from_id`) and the
  original is superseded. Returns the changeset now at main, or
  `{:conflict, paths}` when main changed the same paths in between.
  """
  def land(id, actor), do: GenServer.call(Peon.Instance.via(__MODULE__), {:land, id, actor})

  @doc "Records the result of testing a changeset on main: `%{\"status\", \"steps\"}`."
  def set_verify(id, verify),
    do: GenServer.call(Peon.Instance.via(__MODULE__), {:set_verify, id, verify})

  @doc "Marks an open changeset superseded, e.g. when a newer draft replaces it."
  def supersede(id), do: GenServer.call(Peon.Instance.via(__MODULE__), {:supersede, id})

  @doc "Records check progress: status is checking, passed or failed."
  def set_status(id, status, checks),
    do: GenServer.call(Peon.Instance.via(__MODULE__), {:set_status, id, status, checks})

  ## Server

  @impl true
  def init(instance) do
    Peon.Instance.put(instance)
    {:ok, %{}}
  end

  @impl true
  def handle_call(request, _from, state) do
    reply =
      Repo.transaction(fn ->
        case handle(request) do
          {:ok, result, broadcasts} ->
            {result, broadcasts}

          {:error, reason} ->
            Repo.rollback(reason)
        end
      end)

    case reply do
      {:ok, {result, broadcasts}} ->
        Enum.each(broadcasts, &Peon.Instance.broadcast(@topic, &1))
        {:reply, {:ok, result}, state}

      {:error, reason} ->
        {:reply, {:error, reason}, state}
    end
  end

  defp handle({:import_tree, tree, blobs, slug, name, author}) do
    cond do
      Repo.get(Ref, "main") ->
        {:error, {:invalid, "project already has history"}}

      true ->
        insert_blobs(blobs)
        Repo.insert!(%Project{slug: slug, name: name})

        cs =
          insert_changeset!(%{
            parent_id: nil,
            author: author,
            intent: "Import #{slug}",
            changes: Enum.sort(tree),
            status: "passed",
            flags: %{},
            checks: %{"imported" => true},
            base_tree: %{}
          })

        ref = Repo.insert!(%Ref{name: "main", changeset_id: cs.id, version: 1})
        event!(author_id(author), "ref_moved", %{ref: "main", to: cs.id, version: 1})
        {:ok, cs, [{:ref_moved, "main", cs.id, ref.version}]}
    end
  end

  defp handle({:submit, attrs}) do
    author = attrs[:author]

    with {:ok, files} <- normalize_files(attrs[:files]),
         {:ok, intent} <- require_string(attrs[:intent], "intent"),
         {:ok, main} <- main(),
         {:ok, parent} <- fetch(attrs[:parent]),
         {:ok, base_tree} <- rebase_target(parent, main, Enum.map(files, &elem(&1, 0))),
         {:ok, files} <- drop_noops(files, base_tree),
         {:ok, flags} <- policy(files, base_tree, author, attrs[:approve_destructive] == true) do
      hashed = hash_files(files)

      cs =
        insert_changeset!(%{
          parent_id: main.id,
          author: author,
          intent: intent,
          changes: hashed,
          status: "proposed",
          flags: flags,
          checks: %{},
          conversation_id: attrs[:conversation_id],
          base_tree: base_tree
        })

      {:ok, cs, [{:changeset, cs.id, "proposed"}]}
    end
  end

  defp handle({:move_ref, name, to, expected_version, actor, opts}) do
    current = Repo.get(Ref, to_string(name))

    with :ok <- valid_ref_name(name),
         :ok <- check_version(current, expected_version),
         {:ok, cs} <- fetch(to) do
      move!(name, cs, current, actor, opts, [])
    end
  end

  defp handle({:land, id, actor}) do
    current = Repo.get(Ref, "main")

    with {:ok, cs} <- fetch(id),
         :ok <- landable(cs, current),
         {:ok, main} <- main(),
         {:ok, cs, broadcasts} <- onto(cs, main) do
      case move!("main", cs, current, actor, [], broadcasts) do
        {:ok, _ref, broadcasts} -> {:ok, cs, broadcasts}
        error -> error
      end
    end
  end

  defp handle({:set_verify, id, verify}) do
    with {:ok, cs} <- fetch(id) do
      cs = cs |> Ecto.Changeset.change(verify: verify) |> Repo.update!()
      {:ok, cs, [{:verified, cs.id, verify["status"]}]}
    end
  end

  defp handle({:supersede, id}) do
    with {:ok, cs} <- fetch(id) do
      if cs.status in @open do
        {:ok, supersede!(cs), [{:changeset, cs.id, "superseded"}]}
      else
        {:ok, cs, []}
      end
    end
  end

  defp handle({:set_status, id, status, checks}) when status in ~w(checking passed failed) do
    with {:ok, cs} <- fetch(id) do
      if cs.status in @open do
        cs = cs |> Ecto.Changeset.change(status: status, checks: checks) |> Repo.update!()
        {:ok, cs, [{:changeset, cs.id, status}]}
      else
        {:error, {:rejected, "changeset #{id} is #{cs.status}"}}
      end
    end
  end

  defp handle({:set_status, _id, status, _checks}),
    do: {:error, {:invalid, "status #{inspect(status)} cannot be set"}}

  defp move!(name, cs, current, actor, opts, broadcasts) do
    with :ok <- ref_rules(name, cs, current, opts),
         :ok <- recheck_policy(name, cs) do
      version = if current, do: current.version + 1, else: 1

      ref =
        (current || %Ref{name: name})
        |> Ecto.Changeset.change(changeset_id: cs.id, version: version)
        |> Repo.insert_or_update!()

      event!(actor, "ref_moved", %{
        ref: name,
        from: current && current.changeset_id,
        to: cs.id,
        version: version,
        approved_by: opts[:approved_by]
      })

      {:ok, ref, broadcasts ++ [{:ref_moved, name, cs.id, version}]}
    end
  end

  ## Land helpers

  defp landable(cs, main_ref) do
    cond do
      cs.status != "passed" -> {:error, {:rejected, "changeset #{cs.id} is #{cs.status}"}}
      Code.ancestor?(cs.id, main_ref.changeset_id) -> {:error, {:rejected, "already on main"}}
      true -> :ok
    end
  end

  # The changeset as a child of main's tip: itself, or a rebased copy.
  defp onto(%{parent_id: id} = cs, %{id: id}), do: {:ok, cs, []}

  defp onto(cs, main) do
    {:ok, parent} = fetch(cs.parent_id)
    changes = Changeset.changes(cs)

    with {:ok, main_tree} <- rebase_target(parent, main, Enum.map(changes, &elem(&1, 0))) do
      rebased =
        insert_changeset!(%{
          parent_id: main.id,
          rebased_from_id: cs.id,
          author: %{kind: cs.author_kind, id: cs.author_id},
          intent: cs.intent,
          changes: changes,
          status: "passed",
          flags: cs.flags,
          checks: cs.checks,
          conversation_id: cs.conversation_id,
          base_tree: main_tree
        })

      supersede!(cs)
      {:ok, rebased, [{:changeset, cs.id, "superseded"}, {:changeset, rebased.id, "passed"}]}
    end
  end

  ## Submit helpers

  defp normalize_files(files) when is_list(files) and files != [] do
    files
    |> Enum.reduce_while({:ok, []}, fn file, {:ok, acc} ->
      case normalize_file(file) do
        {:ok, entry} -> {:cont, {:ok, [entry | acc]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, entries} ->
        paths = Enum.map(entries, &elem(&1, 0))
        dups = paths -- Enum.uniq(paths)

        if dups == [],
          do: {:ok, Enum.sort(entries)},
          else: {:error, {:invalid, "duplicate paths: #{Enum.join(Enum.uniq(dups), ", ")}"}}

      error ->
        error
    end
  end

  defp normalize_files(_), do: {:error, {:invalid, "files must be a non-empty list"}}

  defp normalize_file(%{"path" => path} = file) when is_binary(path) do
    cond do
      not valid_path?(path) -> {:error, {:invalid, "invalid path: #{inspect(path)}"}}
      file["deleted"] == true -> {:ok, {path, :deleted}}
      is_binary(file["content"]) -> {:ok, {path, file["content"]}}
      true -> {:error, {:invalid, "#{path}: needs content or deleted: true"}}
    end
  end

  defp normalize_file(file), do: {:error, {:invalid, "invalid file entry: #{inspect(file)}"}}

  defp valid_path?(path) do
    path != "" and Path.type(path) == :relative and String.valid?(path) and
      not Enum.any?(Path.split(path), &(&1 in [".", ".."])) and
      not String.contains?(path, ["\\", <<0>>]) and not Peon.Ignore.builtin?(path)
  end

  defp require_string(value, _name) when is_binary(value) and value != "", do: {:ok, value}
  defp require_string(_, name), do: {:error, {:invalid, "#{name} is required"}}

  defp main do
    case Repo.get(Ref, "main") do
      nil -> {:error, {:invalid, "project has no main yet"}}
      ref -> fetch(ref.changeset_id)
    end
  end

  defp fetch(nil), do: {:error, {:invalid, "parent is required"}}

  defp fetch(id) do
    case Code.resolve(id) do
      {:ok, cs} -> {:ok, cs}
      {:error, :not_found} -> {:error, :not_found}
    end
  end

  # The tree a submission applies to: main's tree, as long as nothing the
  # submission touches changed between its parent and main.
  defp rebase_target(%{id: id}, %{id: id} = main, _paths), do: {:ok, Code.tree(main.id)}

  defp rebase_target(parent, main, paths) do
    if Code.ancestor?(parent.id, main.id) do
      main_tree = Code.tree(main.id)
      changed = Tree.changed_paths(Code.tree(parent.id), main_tree)

      case Enum.filter(paths, &MapSet.member?(changed, &1)) do
        [] -> {:ok, main_tree}
        conflicts -> {:error, {:conflict, conflicts}}
      end
    else
      {:error, {:invalid, "parent #{parent.id} is not on main's history; resubmit against main"}}
    end
  end

  defp drop_noops(files, base_tree) do
    files
    |> Enum.reject(fn
      {path, :deleted} -> not Map.has_key?(base_tree, path)
      {path, content} -> base_tree[path] == Totem.Blob.hash(content)
    end)
    |> case do
      [] -> {:error, {:invalid, "no changes against main"}}
      files -> {:ok, files}
    end
  end

  defp policy(files, base_tree, author, approve_destructive) do
    opts = [
      author: author.kind,
      approve_destructive: approve_destructive,
      settings: Project.policy_settings()
    ]

    case Policy.check(files, base_tree, opts) do
      {:ok, flags} ->
        {:ok,
         %{
           "restart_required" => flags.restart_required,
           "destructive_migrations" => flags.destructive_migrations,
           "approved_destructive" => approve_destructive and flags.destructive_migrations != []
         }}

      {:error, violations} ->
        {:error, {:policy, violations}}
    end
  end

  defp hash_files(files) do
    {changes, blobs} =
      Enum.map_reduce(files, %{}, fn
        {path, :deleted}, blobs ->
          {{path, :deleted}, blobs}

        {path, content}, blobs ->
          hash = Totem.Blob.hash(content)
          {{path, hash}, Map.put(blobs, hash, content)}
      end)

    insert_blobs(blobs)
    changes
  end

  defp insert_blobs(blobs) do
    blobs
    |> Enum.map(fn {hash, content} ->
      %{hash: hash, content: Totem.Blob.compress(content), size: byte_size(content)}
    end)
    |> Enum.chunk_every(200)
    |> Enum.each(&Repo.insert_all(Blob, &1, on_conflict: :nothing))
  end

  defp insert_changeset!(attrs) do
    cs =
      Repo.insert!(%Changeset{
        parent_id: attrs.parent_id,
        rebased_from_id: attrs[:rebased_from_id],
        author_kind: to_string(attrs.author.kind),
        author_id: attrs.author.id,
        intent: attrs.intent,
        files:
          Enum.map(attrs.changes, fn
            {path, :deleted} -> %{"path" => path, "hash" => nil}
            {path, hash} -> %{"path" => path, "hash" => hash}
          end),
        status: attrs.status,
        flags: attrs.flags,
        checks: attrs.checks,
        conversation_id: attrs[:conversation_id]
      })

    attrs.changes
    |> Enum.map(fn {path, _} -> %{path: path, changeset_id: cs.id} end)
    |> Enum.chunk_every(400)
    |> Enum.each(&Repo.insert_all(ChangesetPath, &1))

    tree = Tree.apply_changes(attrs.base_tree, attrs.changes)
    Repo.insert!(%TreeCache{changeset_id: cs.id, entries: tree})
    cs
  end

  ## Ref helpers

  defp valid_ref_name(name) when is_binary(name) do
    if Regex.match?(@ref_name, name),
      do: :ok,
      else: {:error, {:invalid, "invalid ref name: #{name}"}}
  end

  defp valid_ref_name(name), do: {:error, {:invalid, "invalid ref name: #{inspect(name)}"}}

  defp check_version(nil, 0), do: :ok
  defp check_version(%Ref{version: v}, v), do: :ok
  defp check_version(current, _), do: {:error, {:stale, current && current.version}}

  defp ref_rules("main", cs, current, _opts) do
    cond do
      is_nil(current) ->
        {:error, {:rejected, "main is created by import"}}

      cs.parent_id != current.changeset_id ->
        {:error, {:rejected, "main only moves forward by one changeset; rebase first"}}

      cs.status != "passed" ->
        {:error, {:rejected, "changeset #{cs.id} is #{cs.status}, not passed"}}

      true ->
        :ok
    end
  end

  defp ref_rules(env, cs, _current, opts) when env in ["staging", "prod"] do
    main = Repo.get!(Ref, "main")

    cond do
      not Code.ancestor?(cs.id, main.changeset_id) ->
        {:error, {:rejected, "#{env} can only point at changesets on main's history"}}

      env == "prod" and not is_binary(opts[:approved_by]) ->
        {:error, {:rejected, "moving prod requires a recorded human approval"}}

      true ->
        :ok
    end
  end

  # Policy runs again before a ref move, in case the project's settings changed
  # since the changeset was submitted. Imports have no parent and are trusted.
  defp recheck_policy(_name, %Changeset{parent_id: nil}), do: :ok

  defp recheck_policy(_name, cs) do
    files =
      for {path, change} <- Changeset.changes(cs),
          do: {path, if(change == :deleted, do: :deleted, else: Code.blob(change))}

    author = %{kind: String.to_existing_atom(cs.author_kind), id: cs.author_id}

    case policy(files, Code.tree(cs.parent_id), author, cs.flags["approved_destructive"] == true) do
      {:ok, _} -> :ok
      error -> error
    end
  end

  defp supersede!(cs), do: cs |> Ecto.Changeset.change(status: "superseded") |> Repo.update!()

  defp event!(actor, action, details),
    do: Repo.insert!(%Event{actor: actor, action: action, details: details})

  defp author_id(%{id: id}), do: id
end
