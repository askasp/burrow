defmodule Totem.Server do
  @moduledoc """
  Owns the app's code in this node: one change at a time, so a version is
  always what's on disk and, unless it waits for a restart, what runs.
  See `Totem` for the API.
  """

  use GenServer

  require Logger

  alias Totem.{Ignore, Loader, Store, Tree}

  @cold_paths ["mix.exs", "mix.lock"]
  @warm_paths ["config/**", "lib/*/application.ex", "lib/*_web/endpoint.ex"]
  # Changes that need the CSS/JS bundles rebuilt (Tailwind scans the web layer).
  @asset_paths ["assets/**", "lib/*_web/**", "priv/static/**"]
  @migration_paths ["priv/repo/migrations/*.exs"]

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    root = Path.expand(opts[:root] || config(:root) || File.cwd!())

    state = %{
      root: root,
      store: Path.expand(opts[:store] || config(:store) || Path.join(root, ".totem")),
      otp_app: opts[:otp_app] || config(:otp_app) || mix_app(),
      cold_paths: config(:cold_paths) || @cold_paths,
      warm_paths: config(:warm_paths) || @warm_paths,
      asset_paths: config(:asset_paths) || @asset_paths,
      migration_paths: config(:migration_paths) || @migration_paths
    }

    booted(state)
    {:ok, state}
  end

  @impl true
  def handle_call(:info, _from, state), do: {:reply, Map.take(state, [:root, :store]), state}

  def handle_call(:current, _from, state), do: {:reply, sync(state), state}

  def handle_call({:apply, change, opts}, _from, state),
    do: {:reply, apply_change(state, change, opts), state}

  def handle_call({:rollback, n, opts}, _from, state) do
    current = sync(state)

    reply =
      case Store.version(state.store, n) do
        nil ->
          {:error, :not_found}

        target ->
          files =
            for {path, hash} <- Tree.changes(current.tree, target.tree),
                do: {path, if(hash == :deleted, do: :deleted, else: {:blob, hash})}

          source = Keyword.get(opts, :source, "rollback to #{n}")
          apply_change(state, %{base: current.version, files: files}, source: source)
      end

    {:reply, reply, state}
  end

  # The version the node booted with runs now, whatever waited for a restart.
  defp booted(state) do
    with n when n != nil <- Store.current(state.store),
         %{status: "restart_required"} = version <- Store.version(state.store, n) do
      Store.put_status(state.store, version, "loaded")
    end
  end

  # The current version, after recording what's on disk if it changed outside Totem.
  defp sync(state) do
    {tree, blobs} = Tree.from_dir(state.root, Ignore.matcher(state.root))
    current = (n = Store.current(state.store)) && Store.version(state.store, n)

    if current && current.tree == tree do
      current
    else
      for {_hash, content} <- blobs, do: Store.put_blob(state.store, content)
      Store.put_version(state.store, %{tree: tree, mode: "found", source: "disk"})
    end
  end

  defp apply_change(state, change, opts) do
    current = sync(state)

    with :ok <- check_base(change, current),
         {:ok, changes} <- store_files(state, Map.get(change, :files, [])) do
      tree = Tree.apply_changes(current.tree, changes)

      if tree == current.tree,
        do: {:ok, %{version: current.version, mode: "none", output: ""}},
        else: load(state, current, tree, opts)
    end
  end

  defp check_base(%{base: base}, %{version: base}), do: :ok
  defp check_base(%{base: _}, current), do: {:error, {:conflict, current.version}}
  defp check_base(_change, _current), do: {:error, :no_base}

  defp store_files(state, files) do
    Enum.reduce_while(files, {:ok, []}, fn {path, content}, {:ok, acc} ->
      case store_file(state, path, content) do
        {:ok, change} -> {:cont, {:ok, [change | acc]}}
        error -> {:halt, error}
      end
    end)
  end

  defp store_file(state, path, content) do
    cond do
      not valid_path?(path) -> {:error, {:bad_path, path}}
      content == :deleted -> {:ok, {path, :deleted}}
      is_binary(content) -> {:ok, {path, Store.put_blob(state.store, content)}}
      match?({:blob, _}, content) -> stored_blob(state, path, elem(content, 1))
      true -> {:error, {:bad_content, path}}
    end
  end

  defp stored_blob(state, path, hash) do
    case Store.missing(state.store, [hash]) do
      [] -> {:ok, {path, hash}}
      _ -> {:error, {:missing_blob, hash}}
    end
  end

  defp valid_path?(path) do
    is_binary(path) and path != "" and Path.type(path) == :relative and
      not String.contains?(path, ["\\", <<0>>]) and ".." not in Path.split(path) and
      not Ignore.builtin?(path)
  end

  defp load(state, current, tree, opts) do
    paths = Tree.changed_paths(current.tree, tree)
    mode = mode(state, paths)
    write_tree(state, current.tree, tree)

    case run(state, mode) |> after_load(state, mode, paths) do
      {:ok, output, done} ->
        status = if mode == "cold", do: "restart_required", else: "loaded"
        attrs = %{tree: tree, mode: mode, source: opts[:source], status: status}
        version = Store.put_version(state.store, attrs)
        {:ok, Map.merge(%{version: version.version, mode: mode, output: output}, done)}

      {:error, output} ->
        Logger.warning("Totem: #{mode} load failed, back to version #{current.version}")
        write_tree(state, tree, current.tree)
        restore(state, mode)
        {:error, {:load_failed, mode, output}}
    end
  end

  # Once the code loaded: new migrations, and the bundles in prod.
  defp after_load({:ok, output}, _state, "cold", _paths),
    do: {:ok, output, %{migrated: [], assets: false}}

  defp after_load({:ok, output}, state, _mode, paths) do
    assets? = Enum.any?(paths, &Totem.Glob.matches?(&1, state.asset_paths))
    migrate? = Enum.any?(paths, &Totem.Glob.matches?(&1, state.migration_paths))

    try do
      assets = assets? and Loader.assets(state.otp_app)
      migrated = if migrate?, do: Loader.migrate(state.otp_app), else: []
      {:ok, output, %{migrated: migrated, assets: assets}}
    rescue
      e -> {:error, output <> "\n" <> Exception.format(:error, e, __STACKTRACE__)}
    end
  end

  defp after_load(error, _state, _mode, _paths), do: error

  defp mode(state, paths) do
    cond do
      Enum.any?(paths, &Totem.Glob.matches?(&1, state.cold_paths)) -> "cold"
      Enum.any?(paths, &Totem.Glob.matches?(&1, state.warm_paths)) -> "warm"
      true -> "hot"
    end
  end

  defp run(_state, "cold"), do: {:ok, ""}

  defp run(state, mode) do
    cond do
      not Loader.available?() -> {:error, "this node can't compile: it doesn't run under Mix"}
      mode == "warm" -> Loader.warm(state.otp_app, state.root)
      true -> Loader.hot()
    end
  end

  # The previous code is back on disk: load it the way the failed load would have.
  defp restore(_state, "cold"), do: :ok

  defp restore(state, mode) do
    {_, output} =
      if mode == "warm",
        do: Loader.warm(state.otp_app, state.root, force: true),
        else: Loader.hot(force: true)

    Logger.info("Totem: previous version reloaded #{String.slice(output, -500, 500)}")
  end

  # Turns the files under root from tree `from` into tree `to`.
  defp write_tree(state, from, to) do
    for {path, hash} <- Tree.changes(from, to) do
      file = Path.join(state.root, path)

      if hash == :deleted do
        File.rm(file)
      else
        {:ok, content} = Store.get_blob(state.store, hash)
        File.mkdir_p!(Path.dirname(file))
        File.write!(file, content)
      end
    end
  end

  defp config(key), do: Application.get_env(:totem, key)

  defp mix_app do
    if Loader.available?(), do: Mix.Project.config()[:app]
  end
end
