defmodule Peon.Sandbox do
  @moduledoc """
  Runs app code in Docker containers: one-off commands for checks, and
  long-running containers for each chat (the preview and the opencode agent).
  App code is never run on the host.

  Containers run as the host user so files they write into the mounted
  working directory stay manageable, with CPU and memory limits.
  """

  require Logger

  @memory_mb 3072

  @doc """
  Runs `script` with `sh -c` in a fresh container with `dir` mounted at /app.
  Returns `{exit_status, output, duration_ms}`; a timeout kills the container
  and returns status `:timeout`.

  Options: `:env` (map), `:timeout` (ms, default 10 min), `:name`.
  """
  def run(dir, script, opts \\ []) do
    name = Keyword.get(opts, :name, "peon-#{System.unique_integer([:positive])}")
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
  (`{name, address}` entries for /etc/hosts), `:hostname`, and `:label`
  (default `peon.project=<slug>`, which `remove_all/0` cleans up).
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
  def create_network(name) do
    System.cmd("docker", ["network", "create", "--label", "peon.project=#{project()}", name],
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
  killed (e.g. by a Peon restart); otherwise every later fetch fails on them.
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

  @doc "Runs a command inside a running container."
  def exec(name, script) do
    System.cmd("docker", ["exec", name, "sh", "-c", script], stderr_to_stdout: true)
  end

  def stop(name) do
    System.cmd("docker", ["rm", "-f", name], stderr_to_stdout: true)
    :ok
  end

  @doc "The memory each container may use, in MB."
  def memory_mb, do: @memory_mb

  defp common_args(dir, opts) do
    hex_cache = Path.join(Peon.Instance.fetch!(:data_dir), "cache/hex")
    File.mkdir_p!(hex_cache)

    env =
      opts
      |> Keyword.get(:env, %{})
      |> Enum.flat_map(fn {k, v} -> ["-e", "#{k}=#{v}"] end)

    ["--label", Keyword.get(opts, :label, "peon.project=#{project()}")] ++
      ["--user", host_user(), "--cpus", "2", "--memory", "#{@memory_mb}m", "--pids-limit", "512"] ++
      ["-v", "#{dir}:/app", "-v", "#{hex_cache}:/cache/hex", "-w", "/app"] ++ env
  end

  @doc "Removes every container this project left behind, e.g. after a crash."
  def remove_all do
    {ids, _} =
      System.cmd("docker", ["ps", "-aq", "--filter", "label=peon.project=#{project()}"])

    case String.split(ids) do
      [] -> :ok
      ids -> System.cmd("docker", ["rm", "-f" | ids], stderr_to_stdout: true)
    end

    System.cmd(
      "docker",
      ["network", "prune", "-f", "--filter", "label=peon.project=#{project()}"],
      stderr_to_stdout: true
    )

    :ok
  end

  defp project, do: Peon.Instance.fetch!(:slug)

  defp image, do: Application.fetch_env!(:peon, :sandbox_image)

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
