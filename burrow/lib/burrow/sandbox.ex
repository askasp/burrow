defmodule Burrow.Sandbox do
  @moduledoc """
  Runs app code in Docker containers: one-off commands for checks, and
  long-running containers for each chat (the preview and the opencode agent)
  and each environment. App code is never run on the host (a repo project's
  own dev stack aside, `Burrow.GitRepo.HostPreview`).

  Every container carries its project's label (`project: slug` option), so
  `remove_all/1` finds what a project left behind; all mount Totem's source
  at TOTEM_PATH, where the apps' mix.exs looks for it.

  Containers run as the host user so files they write into the mounted
  working directory stay manageable, with CPU and memory limits.
  """

  require Logger

  @memory_mb 3072

  # Public resolvers, not the host's: a host on a tailnet resolves names (its
  # own Tailscale Funnel's too) to tailnet addresses, which containers can't
  # reach. On a chat's own network Docker still answers container names.
  @dns ["1.1.1.1", "8.8.8.8"]

  @doc """
  Runs `script` with `sh -c` in a fresh container with `dir` mounted at /app.
  Returns `{exit_status, output, duration_ms}`; a timeout kills the container
  and returns status `:timeout`.

  Options: `:project` (slug, required) or `:label` (instead of the
  project's), `:env` (map), `:timeout` (ms, default 10 min), `:name`.
  """
  def run(dir, script, opts \\ []) do
    name = Keyword.get(opts, :name, "burrow-#{System.unique_integer([:positive])}")
    timeout = Keyword.get(opts, :timeout, :timer.minutes(10))

    args =
      ["run", "--rm", "--name", name] ++ common_args(dir, opts) ++ [image(), "sh", "-c", script]

    started = System.monotonic_time(:millisecond)

    task = Task.async(fn -> System.cmd("docker", args, stderr_to_stdout: true) end)

    {status, output} =
      case Task.yield(task, timeout) || Task.shutdown(task) do
        {:ok, {output, status}} ->
          {status, output}

        nil ->
          System.cmd("docker", ["kill", name], stderr_to_stdout: true)
          {:timeout, "timed out after #{div(timeout, 1000)}s"}
      end

    {status, output, System.monotonic_time(:millisecond) - started}
  end

  @doc """
  Starts a long-running container and returns a Port streaming its output.
  The container is removed when it stops.

  Options: `:env`, `:name` (required), `:ports` (`{host_port, container_port}`,
  published on 127.0.0.1), `:network` and `:alias` (name on that network),
  `:mounts` (`{host_path, container_path, :ro | :rw}`), `:hosts`
  (`{name, address}` entries for /etc/hosts), `:hostname`, `:project`
  (slug, required) and `:label` (instead of the project's).
  `outlive: true` keeps the container running when this process dies (the
  `docker run` client no longer passes signals on), so it can be adopted.
  """
  def start(dir, script, opts) do
    name = Keyword.fetch!(opts, :name)
    stop(name)

    extra =
      Enum.flat_map(Keyword.get(opts, :ports, []), fn {host, container} ->
        ["-p", "127.0.0.1:#{host}:#{container}"]
      end) ++
        Enum.flat_map(Keyword.get(opts, :mounts, []), fn {host, container, mode} ->
          ["-v", "#{host}:#{container}:#{mode}"]
        end) ++
        Enum.flat_map(Keyword.get(opts, :hosts, []), fn {host, address} ->
          ["--add-host", "#{host}:#{address}"]
        end) ++
        if(opts[:network], do: ["--network", opts[:network]], else: []) ++
        if(opts[:alias], do: ["--network-alias", opts[:alias]], else: []) ++
        if(opts[:hostname], do: ["--hostname", opts[:hostname]], else: []) ++
        if(opts[:outlive], do: ["--sig-proxy=false"], else: [])

    args =
      ["run", "--rm", "--init", "--name", name] ++
        extra ++ common_args(dir, opts) ++ [image(), "sh", "-c", script]

    Port.open({:spawn_executable, System.find_executable("docker")}, [
      :binary,
      :exit_status,
      :stderr_to_stdout,
      args: args
    ])
  end

  @doc "Creates a private network (idempotent)."
  def create_network(slug, name) do
    System.cmd("docker", ["network", "create", "--label", "burrow.project=#{slug}", name],
      stderr_to_stdout: true
    )

    :ok
  end

  def remove_network(name) do
    System.cmd("docker", ["network", "rm", name], stderr_to_stdout: true)
    :ok
  end

  @doc "Returns a Port following a running container's output from now on."
  def follow_logs(name) do
    Port.open({:spawn_executable, System.find_executable("docker")}, [
      :binary,
      :exit_status,
      :stderr_to_stdout,
      args: ["logs", "--follow", "--tail", "0", name]
    ])
  end

  def running?(name) do
    case System.cmd("docker", ["inspect", "-f", "{{.State.Running}}", name],
           stderr_to_stdout: true
         ) do
      {"true\n", 0} -> true
      _ -> false
    end
  end

  @doc """
  Shell that removes git lock files left in deps/ by a `mix deps.get` that was
  killed (e.g. by a Burrow restart); otherwise every later fetch fails on them.
  Only for containers that just started, where no git runs yet.
  """
  def unlock_deps, do: "find deps -path '*/.git/*.lock' -delete 2>/dev/null; "

  @doc "A container's environment variables."
  def env(name) do
    case System.cmd("docker", ["inspect", "-f", "{{json .Config.Env}}", name],
           stderr_to_stdout: true
         ) do
      {json, 0} ->
        json
        |> Jason.decode!()
        |> Map.new(fn var -> var |> String.split("=", parts: 2) |> List.to_tuple() end)

      _ ->
        %{}
    end
  end

  @doc "Runs `script` inside a running container: `{output, exit_status}`. Option `:env`."
  def exec(name, script, opts \\ []) do
    env = Enum.flat_map(Keyword.get(opts, :env, %{}), fn {k, v} -> ["-e", "#{k}=#{v}"] end)
    System.cmd("docker", ["exec"] ++ env ++ [name, "sh", "-c", script], stderr_to_stdout: true)
  end

  def stop(name) do
    System.cmd("docker", ["rm", "-f", name], stderr_to_stdout: true)
    :ok
  end

  @doc """
  A directory for Unix sockets to mount into containers: `dir`, unless a
  socket in it could pass the 107 bytes a socket's path may have; then one
  in the temp dir, the same for the same `dir`.
  """
  def socket_dir(dir) do
    if byte_size(dir) <= 96 do
      dir
    else
      hash = :crypto.hash(:sha, dir) |> Base.url_encode64(padding: false) |> binary_part(0, 16)
      Path.join(System.tmp_dir!(), "burrow-" <> hash)
    end
  end

  @doc "The memory each container may use, in MB."
  def memory_mb, do: @memory_mb

  defp common_args(dir, opts) do
    hex_cache = Path.join(Application.fetch_env!(:burrow, :data_dir), "cache/hex")
    File.mkdir_p!(hex_cache)

    env =
      opts
      |> Keyword.get(:env, %{})
      |> Enum.flat_map(fn {k, v} -> ["-e", "#{k}=#{v}"] end)

    ["--label", opts[:label] || "burrow.project=#{Keyword.fetch!(opts, :project)}"] ++
      ["--user", host_user(), "--cpus", "2", "--memory", "#{@memory_mb}m", "--pids-limit", "512"] ++
      Enum.flat_map(@dns, &["--dns", &1]) ++
      ["-v", "#{dir}:/app", "-v", "#{hex_cache}:/cache/hex", "-w", "/app"] ++
      ["-v", "#{Totem.source_dir()}:/opt/totem:ro", "-e", "TOTEM_PATH=/opt/totem"] ++ env
  end

  @doc """
  Removes every container project `slug` left behind, e.g. after a crash;
  with `label` "burrow.env", its environments.
  """
  def remove_all(slug, label \\ "burrow.project") do
    {ids, _} = System.cmd("docker", ["ps", "-aq", "--filter", "label=#{label}=#{slug}"])

    case String.split(ids) do
      [] -> :ok
      ids -> System.cmd("docker", ["rm", "-f" | ids], stderr_to_stdout: true)
    end

    System.cmd(
      "docker",
      ["network", "prune", "-f", "--filter", "label=burrow.project=#{slug}"],
      stderr_to_stdout: true
    )

    :ok
  end

  defp image, do: Application.fetch_env!(:burrow, :sandbox_image)

  defp host_user do
    case :persistent_term.get({__MODULE__, :user}, nil) do
      nil ->
        {uid, 0} = System.cmd("id", ["-u"])
        {gid, 0} = System.cmd("id", ["-g"])
        user = "#{String.trim(uid)}:#{String.trim(gid)}"
        :persistent_term.put({__MODULE__, :user}, user)
        user

      user ->
        user
    end
  end
end
