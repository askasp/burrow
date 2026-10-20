defmodule Peon.Instance.Supervisor do
  @moduledoc """
  One project's tree (`Peon.Instance`): its database, migrated, then its
  store, chats and workers, and last a marker that it is ready
  (`Peon.Instance.lookup/1` finds it from then on). Rest for one: a new
  database restarts everything after it.
  """

  use Supervisor

  alias Peon.Instance

  def start_link(%Instance{} = instance) do
    Supervisor.start_link(__MODULE__, instance, name: Peon.Instance.via(instance, :instance))
  end

  @impl true
  def init(instance) do
    # Children start from this process; they see the instance from here.
    Instance.put(instance)
    File.mkdir_p!(instance.data_dir)

    children =
      [
        {Peon.Repo,
         name: instance.db, database: Path.join(instance.data_dir, "peon.db"), pool_size: 5},
        %{id: :migrate, start: {__MODULE__, :migrate, [instance]}},
        {DynamicSupervisor, name: Instance.via(:chats), strategy: :one_for_one},
        {Peon.Store, instance}
      ] ++ workers(instance) ++ [ready(instance)]

    Supervisor.init(children, strategy: :rest_for_one)
  end

  @doc false
  def migrate(instance) do
    Ecto.Migrator.run(Peon.Repo, migrations(), :up,
      all: true,
      log: false,
      dynamic_repo: instance.db
    )

    :ignore
  end

  # The migration modules, compiled once for every instance in this BEAM
  # (compiling them again redefines them).
  defp migrations do
    :global.trans({__MODULE__, :migrations}, fn ->
      with nil <- :persistent_term.get({__MODULE__, :migrations}, nil) do
        dir = Ecto.Migrator.migrations_path(Peon.Repo)

        migrations =
          for file <- dir |> Path.join("*.exs") |> Path.wildcard() |> Enum.sort(),
              {module, _} <- Code.compile_file(file),
              function_exported?(module, :__migration__, 0) do
            {file |> Path.basename() |> Integer.parse() |> elem(0), module}
          end

        :persistent_term.put({__MODULE__, :migrations}, migrations)
        migrations
      end
    end)
  end

  # Bootstrap, checks, environments and previews touch Docker and the
  # template; tests leave them out (`:start_workers`). A repo project has no
  # store to check, land or deploy: just its repo and the agent's tools.
  defp workers(instance) do
    cond do
      not Application.get_env(:peon, :start_workers, true) ->
        []

      instance.repo != nil ->
        [
          {Peon.Git, instance},
          {Peon.Agent.MCP, instance},
          {Peon.Activity, instance},
          kept_running(instance)
        ]

      true ->
        [
          {Peon.Bootstrap, instance},
          {Peon.Checks, instance},
          {Peon.Verifier, instance},
          {Peon.Agent.MCP, instance}
        ] ++
          Enum.map(Peon.Env.names(instance), &{Peon.Env, {instance, &1}}) ++
          [{Peon.Activity, instance}, kept_running(instance)]
    end
  end

  defp ready(instance) do
    name = {:via, Registry, {Peon.Registry, {instance.id, :ready}, instance}}
    %{id: :ready, start: {Agent, :start_link, [fn -> nil end, [name: name]]}}
  end

  # Chats kept running come back up after a restart, e.g. a shared preview.
  defp kept_running(instance) do
    Supervisor.child_spec(
      {Task,
       fn ->
         Instance.put(instance)
         Peon.Chat.start_kept_running()
       end},
      id: :kept_running
    )
  end
end
