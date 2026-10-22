defmodule Burrow.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children = [
      BurrowWeb.Telemetry,
      Burrow.Repo,
      {Ecto.Migrator,
       repos: Application.fetch_env!(:burrow, :ecto_repos), skip: skip_migrations?()},
      {DNSCluster, query: Application.get_env(:burrow, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: Burrow.PubSub},
      {Task.Supervisor, name: Burrow.TaskSupervisor},
      {Registry, keys: :unique, name: Burrow.CellRegistry},
      {Registry, keys: :unique, name: Burrow.ProjectRegistry},
      {Registry, keys: :unique, name: Burrow.ChatRegistry},
      {DynamicSupervisor, name: Burrow.ChatSupervisor, strategy: :one_for_one},
      {DynamicSupervisor, name: Burrow.CellSupervisor, strategy: :one_for_one},
      # The agents' tools, on one Unix socket every agent container mounts.
      Burrow.Agent.MCP,
      {Registry, keys: :unique, name: Burrow.OpenCodeRegistry},
      {DynamicSupervisor, name: Burrow.OpenCodeSupervisor, strategy: :one_for_one},
      Burrow.Activity,
      # Deps built once, for new checkouts to copy.
      Burrow.BuildCache,
      # Desired state is the projects table: start every project.
      {Task,
       fn ->
         if start_cells?(), do: Enum.each(Burrow.Projects.all(), &Burrow.Cell.ensure_started/1)
       end},
      # Start to serve requests, typically the last entry
      BurrowWeb.Endpoint
    ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Burrow.Supervisor]
    Supervisor.start_link(children, opts)
  end

  defp start_cells?, do: Application.get_env(:burrow, :start_cells, true)

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    BurrowWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  defp skip_migrations?() do
    # By default, sqlite migrations are run when using a release
    System.get_env("RELEASE_NAME") == nil
  end
end
