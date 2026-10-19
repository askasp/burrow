defmodule Peon.HostPreview do
  @moduledoc """
  Runs a repo's preview pack (`Peon.PreviewPack`) on the host, in a chat's
  checkout. Unlike the template's preview this is not sandboxed: the repo's
  own dev tooling (often `docker compose`) needs the host's Docker, and the
  repo is the user's own code.

  The start command runs in its own process group with a clean environment:
  Peon's own variables (its secrets, its database) are left out, the pack's
  environment and the project's secrets are put in. Its output comes to the
  caller as Port messages, like a sandbox container's.
  """

  # The host environment a dev stack needs; everything else of Peon's is unset.
  @keep ~w(PATH HOME USER LOGNAME SHELL LANG TERM TMPDIR XDG_RUNTIME_DIR DOCKER_HOST
           DOCKER_CONFIG DOCKER_CONTEXT)

  @doc "Starts `command` in `dir`; returns the Port."
  def start(dir, command, env) do
    # A Port's program leads its own process group, so stop/4 can end the
    # whole tree it starts.
    Port.open({:spawn_executable, "/bin/sh"}, [
      :binary,
      :exit_status,
      :stderr_to_stdout,
      cd: dir,
      args: ["-c", command],
      env: port_env(env)
    ])
  end

  @doc """
  Stops a preview: kills what is left of the start command's process group
  and runs the pack's stop command, if any. Returns the stop command's output.
  """
  def stop(dir, port, stop_command, env) do
    with port when is_port(port) <- port,
         {:os_pid, pid} <- Port.info(port, :os_pid) do
      System.cmd("kill", ["-TERM", "-#{pid}"], stderr_to_stdout: true)
    end

    if stop_command && File.dir?(dir) do
      case run(dir, stop_command, env, :timer.minutes(2)) do
        {:ok, output} -> output
        {:error, output} -> output
        :timeout -> "stop timed out"
      end
    end
  end

  @doc """
  Runs a pack command in `dir` with the preview's environment and waits for
  it: `{:ok, output}`, `{:error, output}` (it failed) or `:timeout`.
  """
  def run(dir, command, env, timeout) do
    task =
      Task.async(fn ->
        System.cmd("/bin/sh", ["-c", command],
          cd: dir,
          env: env_changes(env),
          stderr_to_stdout: true
        )
      end)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, {output, 0}} -> {:ok, output}
      {:ok, {output, _status}} -> {:error, output}
      _ -> :timeout
    end
  end

  @doc "Whether the preview answers on `port` at `path` (any status below 500)."
  def up?(port, path) do
    case Req.get("http://127.0.0.1:#{port}#{path}",
           retry: false,
           redirect: false,
           receive_timeout: 2_000,
           connect_options: [timeout: 1_000]
         ) do
      {:ok, %{status: status}} -> status < 500
      {:error, _} -> false
    end
  end

  defp port_env(env) do
    for {name, value} <- env_changes(env),
        do: {String.to_charlist(name), if(value, do: String.to_charlist(value), else: false)}
  end

  # nil unsets a variable (Port wants false for that instead).
  defp env_changes(env) do
    unset =
      for {name, _} <- System.get_env(),
          name not in @keep and not Map.has_key?(env, name),
          do: {name, nil}

    unset ++ Enum.to_list(env)
  end
end
