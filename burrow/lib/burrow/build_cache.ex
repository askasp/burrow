defmodule Burrow.BuildCache do
  @moduledoc """
  Dependencies fetched and compiled once, for fresh checkouts to copy.
  Otherwise a new chat's preview, its first checks, an environment's first
  boot and main's first check each fetch every dependency (the git ones from
  GitHub), compile them for their env and download tailwind and esbuild:
  some 40 seconds, against one for the app itself.

  A cache is a lock's (`mix.lock`, in the sandbox image): its `deps/` and
  `_build/` for dev, test and prod, built in the sandbox, one build at a
  time. `seed/1` copies one into a checkout that has neither: its lock's,
  or else the one used last, which Mix brings up to date (fetching and
  compiling only what differs) while its lock's is built for the next
  checkout. The dependencies don't depend on the app's name, so projects
  with the same lock share one. The template's is built as Burrow starts,
  and Burrow keeps the six used last.
  """

  use GenServer

  require Logger

  alias Burrow.Sandbox

  @keep 6
  @container "burrow-build-cache"

  # Not where Burrow starts no projects (tests): it builds in containers.
  def start_link(_) do
    if Application.get_env(:burrow, :start_cells, true),
      do: GenServer.start_link(__MODULE__, nil, name: __MODULE__),
      else: :ignore
  end

  @doc "Copies a cache into `dir` when it has no deps and no builds yet."
  def seed(dir) do
    unless File.exists?(Path.join(dir, "deps")) or File.exists?(Path.join(dir, "_build")) do
      exact = Path.join(root(), key(dir))
      cache = if File.dir?(exact), do: exact, else: List.first(caches())
      if cache != exact, do: build(dir)
      if cache, do: copy(cache, dir)
    end

    :ok
  end

  @doc "Builds the cache for `dir`'s lock from its mix.exs, mix.lock and config, unless it's there."
  def build(dir) do
    paths = ["mix.exs", "mix.lock" | Path.wildcard(Path.join(dir, "config/**/*.exs"))]

    files =
      for path <- paths,
          path = Path.relative_to(path, dir),
          {:ok, content} <- [File.read(Path.join(dir, path))],
          do: {path, content}

    GenServer.cast(__MODULE__, {:build, key(dir), files})
  end

  defp copy(cache, dir) do
    File.touch(cache)
    args = ["-a", "--reflink=auto", Path.join(cache, "deps"), Path.join(cache, "_build"), dir]

    with {output, status} when status != 0 <- System.cmd("cp", args, stderr_to_stdout: true) do
      # Half a copy is worse than none: Mix would take it as built.
      Logger.warning("could not seed #{dir} from the build cache: #{output}")
      File.rm_rf(Path.join(dir, "deps"))
      File.rm_rf(Path.join(dir, "_build"))
    end
  end

  ## Server

  @impl true
  def init(nil), do: {:ok, %{failed: MapSet.new()}, {:continue, :template}}

  @impl true
  def handle_continue(:template, state) do
    build(Application.fetch_env!(:burrow, :template_dir))
    {:noreply, state}
  end

  @impl true
  def handle_cast({:build, key, files}, state) do
    dir = Path.join(root(), key)

    cond do
      File.dir?(dir) or key in state.failed -> {:noreply, state}
      run(dir, files) == :ok -> {:noreply, state}
      true -> {:noreply, update_in(state.failed, &MapSet.put(&1, key))}
    end
  end

  defp run(dir, files) do
    part = dir <> ".part"
    File.rm_rf!(part)

    for {path, content} <- files do
      File.mkdir_p!(Path.dirname(Path.join(part, path)))
      File.write!(Path.join(part, path), content)
    end

    script =
      "mix deps.get && MIX_ENV=dev mix deps.compile && MIX_ENV=test mix deps.compile && " <>
        "MIX_ENV=prod mix deps.compile && mix assets.setup"

    # One left running by a Burrow that stopped would write into `part`.
    Sandbox.stop(@container)

    case Sandbox.run(part, script,
           name: @container,
           label: "burrow.cache=build",
           timeout: :timer.minutes(20)
         ) do
      {0, _output, ms} ->
        File.rename!(part, dir)
        Logger.info("build cache #{Path.basename(dir)} is ready, in #{div(ms, 1000)}s")
        caches() |> Enum.drop(@keep) |> Enum.each(&File.rm_rf/1)

      {status, output, _ms} ->
        Logger.warning("could not build the build cache (#{inspect(status)}): #{output}")
        File.rm_rf(part)
        :error
    end
  end

  # Built caches, used last first.
  defp caches do
    case File.ls(root()) do
      {:ok, names} ->
        names
        |> Enum.reject(&String.ends_with?(&1, ".part"))
        |> Enum.map(&Path.join(root(), &1))
        |> Enum.filter(&File.dir?/1)
        |> Enum.sort_by(&File.stat!(&1, time: :posix).mtime, :desc)

      {:error, _} ->
        []
    end
  end

  defp key(dir) do
    lock = File.read(Path.join(dir, "mix.lock"))
    image = Application.get_env(:burrow, :sandbox_image)

    :crypto.hash(:sha256, :erlang.term_to_binary({image, lock}))
    |> Base.encode16(case: :lower)
    |> binary_part(0, 12)
  end

  defp root, do: Path.join(Application.fetch_env!(:burrow, :data_dir), "cache/build")
end
