defmodule Burrow.Cell do
  @moduledoc """
  Runs one project's Peon as an OS process (the Peon release) and restarts it
  when it exits. In local mode Burrow plays the host agent itself; on real
  hosts this moves into the host agent and Peon runs in a container.

  Broadcasts `{:cell, project_id, status}` on topic `"cells"`, where status is
  `:starting`, `:running` or `{:exited, code}`.
  """

  use GenServer, restart: :transient

  require Logger

  alias Burrow.Projects

  @registry Burrow.CellRegistry
  @log_lines 300
  @restart_delay :timer.seconds(5)

  def ensure_started(project) do
    if Application.get_env(:burrow, :start_cells, true),
      do: start_child(project),
      else: {:ok, nil}
  end

  defp start_child(project) do
    case DynamicSupervisor.start_child(Burrow.CellSupervisor, {__MODULE__, project}) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      error -> error
    end
  end

  def child_spec(project),
    do: %{
      id: {__MODULE__, project.id},
      start: {__MODULE__, :start_link, [project]},
      restart: :transient
    }

  def start_link(project),
    do: GenServer.start_link(__MODULE__, project, name: {:via, Registry, {@registry, project.id}})

  def subscribe, do: Phoenix.PubSub.subscribe(Burrow.PubSub, "cells")

  def status(project_id), do: call(project_id, :status, :stopped)

  def logs(project_id), do: call(project_id, :logs, "")

  def restart(project_id), do: call(project_id, :restart, :ok)

  defp call(project_id, msg, default) do
    case GenServer.whereis({:via, Registry, {@registry, project_id}}) do
      nil -> default
      pid -> GenServer.call(pid, msg)
    end
  end

  ## Server

  @impl true
  def init(project) do
    Process.flag(:trap_exit, true)
    dir = Path.join(Application.fetch_env!(:burrow, :data_dir), "projects/#{project.slug}")
    File.mkdir_p!(dir)

    state = %{project: project, dir: dir, port: nil, os_pid: nil, status: :starting, logs: []}
    {:ok, state, {:continue, :start}}
  end

  @impl true
  def handle_continue(:start, state), do: {:noreply, start_peon(state)}

  @impl true
  def handle_call(:status, _from, state), do: {:reply, state.status, state}

  def handle_call(:logs, _from, state),
    do: {:reply, Enum.join(Enum.reverse(state.logs), "\n"), state}

  def handle_call(:restart, _from, state) do
    stop_peon(state)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info({port, {:data, data}}, %{port: port} = state) do
    lines = String.split(data, "\n", trim: true)
    state = %{state | logs: Enum.take(Enum.reverse(lines) ++ state.logs, @log_lines)}

    if state.status != :running and data =~ "Running PeonWeb.Endpoint",
      do: {:noreply, set_status(state, :running)},
      else: {:noreply, state}
  end

  def handle_info({port, {:exit_status, code}}, %{port: port} = state) do
    Logger.warning("Peon for #{state.project.slug} exited with #{code}; restarting")
    Process.send_after(self(), :restart, @restart_delay)
    {:noreply, set_status(%{state | port: nil, os_pid: nil}, {:exited, code})}
  end

  def handle_info(:restart, %{port: nil} = state), do: {:noreply, start_peon(state)}
  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state), do: stop_peon(state)

  defp start_peon(state) do
    kill_stale(state.dir)
    project = state.project
    data_dir = Path.join(state.dir, "peon")
    File.mkdir_p!(data_dir)

    env = %{
      "PHX_SERVER" => "true",
      "PHX_HOST" => Application.fetch_env!(:burrow, :peon_host),
      "PORT" => to_string(project.port),
      "DATABASE_PATH" => Path.join(data_dir, "peon.db"),
      "SECRET_KEY_BASE" =>
        Projects.secret(project, "peon-secret-key-base") <> Projects.secret(project, "peon-skb-2"),
      "RELEASE_DISTRIBUTION" => "none",
      "RELEASE_COOKIE" => Projects.secret(project, "cookie"),
      "PEON_DATA_DIR" => data_dir,
      "PEON_PROJECT_SLUG" => project.slug,
      "PEON_PROJECT_NAME" => project.name,
      "PEON_TEMPLATE_DIR" => Application.fetch_env!(:burrow, :template_dir),
      "PEON_PREVIEW_PORTS" => project.preview_ports,
      "PEON_PREVIEW_HOST" => Application.fetch_env!(:burrow, :peon_host),
      "PEON_SSO_SECRET" => Projects.secret(project, "sso"),
      "PEON_OPENCODE_BIN" => Application.fetch_env!(:burrow, :opencode_bin),
      "PEON_OPENCODE_DATA_DIR" => Burrow.OpenCode.data_dir(project.user_id),
      "PEON_OPENCODE_MODEL" => Burrow.OpenCode.model(project.user_id)
    }

    port =
      Port.open({:spawn_executable, Application.fetch_env!(:burrow, :peon_release)}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: ["start"],
        env: Enum.map(env, fn {k, v} -> {to_charlist(k), to_charlist(v)} end)
      ])

    {:os_pid, os_pid} = Port.info(port, :os_pid)
    File.write!(pid_file(state.dir), to_string(os_pid))
    set_status(%{state | port: port, os_pid: os_pid}, :starting)
  end

  defp stop_peon(%{os_pid: nil}), do: :ok

  defp stop_peon(%{os_pid: os_pid}) do
    System.cmd("kill", ["-TERM", to_string(os_pid)], stderr_to_stdout: true)
    :ok
  end

  # A Peon left running by a previous Burrow (e.g. after a crash) would hold
  # the port; stop it before starting a new one.
  defp kill_stale(dir) do
    with {:ok, pid} <- File.read(pid_file(dir)),
         pid = String.trim(pid),
         {:ok, cmdline} <- File.read("/proc/#{pid}/cmdline"),
         true <- cmdline =~ "peon",
         {_, 0} <- System.cmd("kill", ["-TERM", pid], stderr_to_stdout: true) do
      Process.sleep(2_000)
    end

    File.rm(pid_file(dir))
  end

  defp pid_file(dir), do: Path.join(dir, "peon.pid")

  defp set_status(state, status) do
    Phoenix.PubSub.broadcast(Burrow.PubSub, "cells", {:cell, state.project.id, status})
    %{state | status: status}
  end
end
