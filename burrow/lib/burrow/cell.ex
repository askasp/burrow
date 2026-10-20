defmodule Burrow.Cell do
  @moduledoc """
  Runs one project's Peon (`Peon.Instance`) inside Burrow and restarts it
  when it stops: its database, code store, checks, chats and environments.
  Containers (agents, previews, the app's environments) stay out of Burrow,
  in Docker.

  Starting a new project creates it from the template first, which can take
  minutes; the cell's status says `:starting` meanwhile. Status is kept in
  the registry, so reading it never waits on the cell.

  Broadcasts `{:cell, project_id, status}` on topic `"cells"`, where status is
  `:starting`, `:running` or `{:exited, reason}`.
  """

  use GenServer, restart: :transient

  require Logger

  alias Burrow.Projects

  @registry Burrow.CellRegistry
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
      restart: :transient,
      # Stopping a Peon stops its chats' containers.
      shutdown: :timer.minutes(2)
    }

  def start_link(project),
    do:
      GenServer.start_link(__MODULE__, project,
        name: {:via, Registry, {@registry, project.id, :starting}}
      )

  def subscribe, do: Phoenix.PubSub.subscribe(Burrow.PubSub, "cells")

  @doc "`:starting`, `:running`, `{:exited, reason}`, or `:stopped` without a cell."
  def status(project_id) do
    case Registry.lookup(@registry, project_id) do
      [{_pid, status}] -> status
      [] -> :stopped
    end
  end

  @doc "Restarts the project's Peon, e.g. on a new owner's AI login."
  def restart(project_id) do
    case Registry.lookup(@registry, project_id) do
      [{pid, _}] -> send(pid, :restart)
      [] -> :ok
    end

    :ok
  end

  ## Server

  @impl true
  def init(project) do
    Process.flag(:trap_exit, true)
    dir = Path.join(Application.fetch_env!(:burrow, :data_dir), "projects/#{project.slug}")
    File.mkdir_p!(dir)
    {:ok, %{project: project, dir: dir, sup: nil}, {:continue, :start}}
  end

  @impl true
  def handle_continue(:start, state), do: {:noreply, start_peon(state)}

  @impl true
  def handle_info({:EXIT, pid, reason}, %{sup: pid} = state) do
    Logger.warning("Peon for #{state.project.slug} stopped (#{inspect(reason)}); restarting")
    Process.send_after(self(), :start, @restart_delay)
    {:noreply, set_status(%{state | sup: nil}, {:exited, short(reason)})}
  end

  # Re-read the project: its owner (whose AI login it runs on) may have changed.
  def handle_info(:start, %{sup: nil} = state),
    do:
      {:noreply, start_peon(%{state | project: Projects.get(state.project.id) || state.project})}

  def handle_info(:restart, state) do
    state = stop_peon(state)
    {:noreply, start_peon(%{state | project: Projects.get(state.project.id) || state.project})}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state), do: stop_peon(state)

  defp start_peon(state) do
    kill_stale(state.dir)
    state = set_status(state, :starting)

    case Peon.Instance.start_link(instance(state.project, state.dir)) do
      {:ok, sup} ->
        set_status(%{state | sup: sup}, :running)

      {:error, reason} ->
        Logger.error("Peon for #{state.project.slug} did not start: #{inspect(reason)}")
        Process.send_after(self(), :start, @restart_delay)
        set_status(state, {:exited, short(reason)})
    end
  end

  defp stop_peon(%{sup: nil} = state), do: state

  defp stop_peon(%{sup: sup} = state) do
    Supervisor.stop(sup, :shutdown, :timer.minutes(2))
    %{state | sup: nil}
  catch
    :exit, _ -> %{state | sup: nil}
  end

  @doc false
  # The project as its Peon sees it.
  def instance(project, dir) do
    {previews, envs} = ports(project)

    Peon.Instance.new(
      id: project.id,
      slug: project.slug,
      name: project.name,
      data_dir: Path.join(dir, "peon"),
      repo: if(Projects.Project.repo?(project), do: %{url: project.repo_url, branch: "main"}),
      preview_ports: previews,
      env_ports: envs,
      envs: project.envs,
      auth: project.auth,
      # Only the project `Projects.create/2` just made has one (it isn't
      # stored), so it reaches Peon on the first start alone.
      basic_auth: Projects.Project.basic_login(project),
      opencode_model: Burrow.OpenCode.model(project.user_id),
      opencode_data_dir: Burrow.OpenCode.data_dir(project.user_id),
      secret: Projects.secret(project, "peon-secret-key-base")
    )
  end

  # A Peon left running as its own OS process by a Burrow from before Peons
  # ran inside it would hold the project's containers; stop it first.
  defp kill_stale(dir) do
    pid_file = Path.join(dir, "peon.pid")

    with {:ok, pid} <- File.read(pid_file),
         pid = String.trim(pid),
         {:ok, cmdline} <- File.read("/proc/#{pid}/cmdline"),
         true <- cmdline =~ "peon",
         {_, 0} <- System.cmd("kill", ["-TERM", pid], stderr_to_stdout: true) do
      Process.sleep(2_000)
    end

    File.rm(pid_file)
  end

  defp set_status(state, status) do
    Registry.update_value(@registry, state.project.id, fn _ -> status end)
    Phoenix.PubSub.broadcast(Burrow.PubSub, "cells", {:cell, state.project.id, status})
    state
  end

  defp short({:shutdown, reason}), do: short(reason)
  defp short(reason) when is_atom(reason), do: reason
  defp short(_reason), do: :crashed

  # The project's port range: chat previews, then the last two ports a browser
  # will open for staging and prod (Peon skips blocked ones for previews). A
  # repo project has no envs, so its whole range is previews.
  @doc false
  def ports(%Projects.Project{preview_ports: range} = project) do
    [first, last] = range |> String.split("-") |> Enum.map(&String.to_integer/1)

    if Projects.Project.repo?(project) do
      {first..last, %{}}
    else
      [prod, staging | _] = last..first//-1 |> Enum.filter(&Burrow.Ports.browser_safe?/1)
      {first..(staging - 1)//1, %{"staging" => staging, "prod" => prod}}
    end
  end
end
