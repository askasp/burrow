defmodule Burrow.Cell do
  @moduledoc """
  Runs one project and restarts it when it stops: first its setup (a new
  app's first change from the template, `Burrow.Bootstrap`; containers and
  repo previews a previous run left behind), then its main checks and
  shipping (`Burrow.Ship`), its hordes (`Burrow.Hordes.Runner`) and its
  environments (`Burrow.Env`); a repo project's instead closes the chats
  whose PR was merged (`Burrow.GitRepo.Merged`). Its chats
  run under `Burrow.ChatSupervisor`, started when used. Containers (agents,
  previews, environments) stay out of Burrow, in Docker.

  Status is kept in the registry, so reading it never waits on the cell:
  `:starting` (a new project's setup can take minutes), `:running` or
  `{:exited, reason}`. Broadcasts `{:cell, project_id, status}` on `"cells"`.
  """

  use GenServer, restart: :transient

  require Logger

  alias Burrow.{Chat, Hordes, Env, Projects, Sandbox, Ship}

  @registry Burrow.CellRegistry
  @restart_delay :timer.seconds(5)

  def ensure_started(project) do
    if Application.get_env(:burrow, :start_cells, true) do
      case DynamicSupervisor.start_child(Burrow.CellSupervisor, {__MODULE__, project}) do
        {:error, {:already_started, pid}} -> {:ok, pid}
        other -> other
      end
    else
      {:ok, nil}
    end
  end

  @doc "A process name within the project (`Burrow.ProjectRegistry`)."
  def via(project_id, name), do: {:via, Registry, {Burrow.ProjectRegistry, {project_id, name}}}

  def child_spec(project),
    do: %{
      id: {__MODULE__, project.id},
      start: {__MODULE__, :start_link, [project]},
      restart: :transient,
      shutdown: :timer.minutes(2)
    }

  def start_link(project),
    do:
      GenServer.start_link(__MODULE__, project,
        name: {:via, Registry, {@registry, project.id, :starting}}
      )

  def subscribe, do: Phoenix.PubSub.subscribe(Burrow.PubSub, "cells")

  @doc """
  Starts `spec` in the running project's tree, unless it runs: a part
  added since the cell started (as `Burrow.Hordes.Runner` was).
  """
  def ensure(project_id, spec) do
    case Registry.lookup(@registry, project_id) do
      [{pid, :running}] -> GenServer.call(pid, {:ensure, spec})
      _ -> {:error, :not_running}
    end
  end

  @doc "`:starting`, `:running`, `{:exited, reason}`, or `:stopped` without a cell."
  def status(project_id) do
    case Registry.lookup(@registry, project_id) do
      [{_pid, status}] -> status
      [] -> :stopped
    end
  end

  @doc "Restarts the project and its chats, e.g. on a new owner's AI login."
  def restart(project_id) do
    case Registry.lookup(@registry, project_id) do
      [{pid, _}] -> send(pid, :restart)
      [] -> :ok
    end

    :ok
  end

  @doc "Stops the project for good: its processes, chats and every container it has."
  def stop(project) do
    Chat.stop_all(project.id)

    case Registry.lookup(@registry, project.id) do
      [{pid, _}] -> DynamicSupervisor.terminate_child(Burrow.CellSupervisor, pid)
      [] -> :ok
    end

    Sandbox.remove_all(project.slug)
    Sandbox.remove_all(project.slug, "burrow.env")
  end

  ## Server

  @impl true
  def init(project) do
    Process.flag(:trap_exit, true)
    File.mkdir_p!(Projects.dir(project))
    {:ok, %{project: project, sup: nil}, {:continue, :start}}
  end

  @impl true
  def handle_continue(:start, state), do: {:noreply, start_tree(state)}

  @impl true
  def handle_call({:ensure, _spec}, _from, %{sup: nil} = state),
    do: {:reply, {:error, :not_running}, state}

  def handle_call({:ensure, spec}, _from, state) do
    case Supervisor.start_child(state.sup, spec) do
      {:ok, pid} ->
        {:reply, {:ok, pid}, state}

      {:error, {:already_started, pid}} ->
        {:reply, {:ok, pid}, state}

      {:error, :already_present} ->
        {:reply, Supervisor.restart_child(state.sup, elem(spec, 0)), state}

      error ->
        {:reply, error, state}
    end
  end

  @impl true
  def handle_info({:EXIT, pid, reason}, %{sup: pid} = state) do
    Logger.warning("#{state.project.slug} stopped (#{inspect(reason)}); restarting")
    Process.send_after(self(), :start, @restart_delay)
    {:noreply, set_status(%{state | sup: nil}, {:exited, short(reason)})}
  end

  def handle_info(:start, %{sup: nil} = state), do: {:noreply, start_tree(reload(state))}

  def handle_info(:restart, state) do
    Chat.stop_all(state.project.id)
    {:noreply, state |> stop_tree() |> reload() |> start_tree()}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state), do: stop_tree(state)

  # The owner (whose AI login the chats use) or the envs may have changed.
  defp reload(state), do: %{state | project: Projects.get(state.project.id) || state.project}

  defp start_tree(state) do
    state = set_status(state, :starting)
    project = state.project

    children =
      [%{id: :setup, start: {__MODULE__, :setup, [project]}}] ++
        if(Projects.Project.repo?(project),
          do: [{Burrow.GitRepo.Merged, project}],
          else: [{Ship, project}, {Hordes.Runner, project}]
        ) ++
        Enum.map(Env.names(project), &{Env, {project, &1}}) ++
        [
          Supervisor.child_spec({Task, fn -> Chat.start_kept_running(project) end},
            id: :kept_running
          )
        ]

    case Supervisor.start_link(children, strategy: :one_for_one) do
      {:ok, sup} ->
        set_status(%{state | sup: sup}, :running)

      {:error, reason} ->
        Logger.error("#{project.slug} did not start: #{inspect(reason)}")
        Process.send_after(self(), :start, @restart_delay)
        set_status(state, {:exited, short(reason)})
    end
  end

  @doc false
  # Runs before the project's other processes, so they see its history.
  def setup(project) do
    Sandbox.remove_all(project.slug)

    if Projects.Project.repo?(project) do
      Chat.stop_left_behind(project)
      if Burrow.Chats.list(project.id) == [], do: Burrow.Chats.create_empty(project.id, "peon")
    else
      Burrow.Bootstrap.run(project)
    end

    :ignore
  end

  defp stop_tree(%{sup: nil} = state), do: state

  defp stop_tree(%{sup: sup} = state) do
    Supervisor.stop(sup, :shutdown, :timer.minutes(2))
    %{state | sup: nil}
  catch
    :exit, _ -> %{state | sup: nil}
  end

  defp set_status(state, status) do
    Registry.update_value(@registry, state.project.id, fn _ -> status end)
    Phoenix.PubSub.broadcast(Burrow.PubSub, "cells", {:cell, state.project.id, status})
    Burrow.Activity.push()
    state
  end

  defp short({:shutdown, reason}), do: short(reason)
  defp short(reason) when is_atom(reason), do: reason
  defp short(_reason), do: :crashed

  @doc """
  The project's port range: chat previews, then the last ports a browser
  will open, one per env (`Burrow.Env.names/1`). A repo project has no envs,
  so its whole range is previews.
  """
  def ports(%Projects.Project{preview_ports: range} = project) do
    [first, last] = range |> String.split("-") |> Enum.map(&String.to_integer/1)
    # prod (or live) on the last one, staging below it
    names = Enum.reverse(Env.names(project))

    ports =
      last..first//-1 |> Enum.filter(&Burrow.Ports.browser_safe?/1) |> Enum.take(length(names))

    if names == [],
      do: {first..last, %{}},
      else: {first..(List.last(ports) - 1)//1, Map.new(Enum.zip(names, ports))}
  end
end
