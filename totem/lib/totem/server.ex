defmodule Totem.Server do
  @moduledoc """
  Owns the app's files in this node: one change at a time, so what is on
  disk is what runs (unless it waits for a restart). See `Totem` for the API.
  It keeps no history: the code is the files on disk, plus a cache of
  contents sent ahead of a change (`.totem/objects`) and the label of the
  last change (`.totem/label`).
  """

  use GenServer

  require Logger

  alias Totem.{Ignore, Loader, Monitor, Store, Tree}

  @cold_paths ["mix.exs", "mix.lock"]
  @warm_paths ["config/**", "lib/*/application.ex", "lib/*_web/endpoint.ex"]
  # Changes that need the CSS/JS bundles rebuilt (Tailwind scans the web layer).
  @asset_paths ["assets/**", "lib/*_web/**", "priv/static/**"]
  @migration_paths ["priv/repo/migrations/*.exs"]

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(opts) do
    root = Path.expand(opts[:root] || config(:root) || File.cwd!())
    # Errors arrive here too, for the watch window after a load.
    if Process.whereis(Monitor), do: Monitor.subscribe()

    {:ok,
     %{
       root: root,
       store: Path.expand(opts[:store] || config(:store) || Path.join(root, ".totem")),
       otp_app: opts[:otp_app] || config(:otp_app) || mix_app(),
       cold_paths: config(:cold_paths) || @cold_paths,
       warm_paths: config(:warm_paths) || @warm_paths,
       asset_paths: config(:asset_paths) || @asset_paths,
       migration_paths: config(:migration_paths) || @migration_paths,
       # Paths whoever runs the app owns, e.g. Peon's .peon/: never the app's code.
       ignore:
         config(:ignore) || String.split(System.get_env("TOTEM_IGNORE") || "", ",", trim: true),
       watch: config(:watch) || 0
     }}
  end

  @impl true
  def handle_call(:info, _from, state), do: {:reply, Map.take(state, [:root, :store]), state}

  def handle_call(:current, _from, state) do
    {tree, _} = disk(state)
    {:reply, %{tree: tree, hash: Tree.hash(tree), label: label(state)}, state}
  end

  def handle_call({:apply, files, opts}, _from, state),
    do: {:reply, apply_files(state, files, opts), state}

  @impl true
  def handle_info(_msg, state), do: {:noreply, state}

  @doc false
  def disk(state), do: Tree.from_dir(state.root, Ignore.matcher(state.root, extra: state.ignore))

  defp apply_files(state, files, opts) do
    {tree, _} = disk(state)

    with :ok <- check_paths(files),
         [] <- for({path, from, _} <- files, tree[path] != from, do: path),
         {:ok, contents} <- contents(state, files) do
      before = for {path, _, _} <- files, into: %{}, do: {path, read(state, path)}
      write(state, contents)
      paths = Map.keys(contents)
      mode = mode(state, paths)
      known = known_errors()

      case state
           |> run(mode)
           |> after_load(state, mode, paths)
           |> watch(state, mode, known, opts) do
        {:ok, result} ->
          File.mkdir_p!(state.store)
          if opts[:label], do: File.write!(Path.join(state.store, "label"), opts[:label])
          {:ok, Map.merge(result, %{mode: mode, label: opts[:label] || label(state)})}

        {:error, reason} ->
          Logger.warning("Totem: #{mode} load #{elem(reason, 0)}, previous files back")
          write(state, before)
          restore(state, mode)
          {:error, reason |> Tuple.insert_at(1, mode)}
      end
    else
      [_ | _] = paths -> {:error, {:conflict, paths}}
      error -> error
    end
  end

  defp check_paths(files) do
    case Enum.reject(files, fn {path, _, _} -> valid_path?(path) end) do
      [] -> :ok
      [{path, _, _} | _] -> {:error, {:bad_path, path}}
    end
  end

  defp valid_path?(path) do
    is_binary(path) and path != "" and Path.type(path) == :relative and
      not String.contains?(path, ["\\", <<0>>]) and ".." not in Path.split(path) and
      not Ignore.builtin?(path)
  end

  # path => new content, or nil to delete.
  defp contents(state, files) do
    Enum.reduce_while(files, {:ok, %{}}, fn {path, _from, to}, {:ok, acc} ->
      case to do
        :deleted -> {:cont, {:ok, Map.put(acc, path, nil)}}
        content when is_binary(content) -> {:cont, {:ok, Map.put(acc, path, content)}}
        {:blob, hash} -> blob(state, path, hash, acc)
        _ -> {:halt, {:error, {:bad_content, path}}}
      end
    end)
  end

  defp blob(state, path, hash, acc) do
    case Store.get_blob(state.store, hash) do
      {:ok, content} -> {:cont, {:ok, Map.put(acc, path, content)}}
      :error -> {:halt, {:error, {:missing_blob, hash}}}
    end
  end

  defp read(state, path) do
    case File.read(Path.join(state.root, path)) do
      {:ok, content} -> content
      {:error, _} -> nil
    end
  end

  defp write(state, contents) do
    for {path, content} <- contents do
      file = Path.join(state.root, path)

      if content do
        File.mkdir_p!(Path.dirname(file))
        File.write!(file, content)
      else
        File.rm(file)
      end
    end
  end

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

  # Once the code loaded: new migrations, and the bundles in prod.
  defp after_load({:ok, output}, _state, "cold", _paths),
    do: {:ok, %{output: output, migrated: [], assets: false, restart_required: true}}

  defp after_load({:ok, output}, state, _mode, paths) do
    assets? = Enum.any?(paths, &Totem.Glob.matches?(&1, state.asset_paths))
    migrate? = Enum.any?(paths, &Totem.Glob.matches?(&1, state.migration_paths))

    try do
      assets = assets? and Loader.assets(state.otp_app)
      migrated = if migrate?, do: Loader.migrate(state.otp_app), else: []
      {:ok, %{output: output, migrated: migrated, assets: assets}}
    rescue
      e -> {:error, {:load_failed, output <> "\n" <> Exception.format(:error, e, __STACKTRACE__)}}
    end
  end

  defp after_load({:error, output}, _state, _mode, _paths), do: {:error, {:load_failed, output}}

  # The watch window: an error not seen before the load, or the app gone, undoes it.
  defp watch({:ok, _} = ok, _state, "cold", _known, _opts), do: ok

  defp watch({:ok, _} = ok, state, _mode, known, opts) do
    case Keyword.get(opts, :watch, state.watch) do
      ms when is_integer(ms) and ms > 0 ->
        deadline = System.monotonic_time(:millisecond) + ms

        case new_errors(known, deadline) do
          [] ->
            if app_up?(state),
              do: ok,
              else: {:error, {:reverted, [%{"message" => "the app stopped"}]}}

          errors ->
            {:error, {:reverted, errors}}
        end

      _ ->
        ok
    end
  end

  defp watch(error, _state, _mode, _known, _opts), do: error

  defp new_errors(known, deadline) do
    receive do
      {:totem, :error, %{"fingerprint" => fingerprint} = error} ->
        if MapSet.member?(known, fingerprint), do: new_errors(known, deadline), else: [error]
    after
      max(deadline - System.monotonic_time(:millisecond), 0) -> []
    end
  end

  defp known_errors do
    if Process.whereis(Monitor),
      do: MapSet.new(Monitor.errors(), & &1["fingerprint"]),
      else: MapSet.new()
  end

  defp app_up?(%{otp_app: nil}), do: true
  defp app_up?(%{otp_app: app}), do: List.keymember?(Application.started_applications(), app, 0)

  # The previous code is back on disk: load it the way the failed load would have.
  defp restore(_state, "cold"), do: :ok

  defp restore(state, mode) do
    {_, output} =
      if mode == "warm",
        do: Loader.warm(state.otp_app, state.root, force: true),
        else: Loader.hot(force: true)

    Logger.info("Totem: previous files reloaded #{String.slice(output, -500, 500)}")
  end

  defp label(state) do
    case File.read(Path.join(state.store, "label")) do
      {:ok, label} -> label
      {:error, _} -> nil
    end
  end

  defp config(key), do: Application.get_env(:totem, key)

  defp mix_app do
    if Loader.available?(), do: Mix.Project.config()[:app]
  end
end
