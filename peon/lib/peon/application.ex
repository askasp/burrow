defmodule Peon.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  @impl true
  def start(_type, _args) do
    children =
      [
        PeonWeb.Telemetry,
        Peon.Repo,
        {Ecto.Migrator, repos: Application.fetch_env!(:peon, :ecto_repos), skip: false},
        {DNSCluster, query: Application.get_env(:peon, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: Peon.PubSub},
        {Task.Supervisor, name: Peon.TaskSupervisor},
        {Registry, keys: :unique, name: Peon.ChatRegistry},
        {DynamicSupervisor, name: Peon.ChatSupervisor, strategy: :one_for_one},
        Peon.Store
      ] ++
        workers() ++
        [
          # Start to serve requests, typically the last entry
          PeonWeb.Endpoint
        ]

    # See https://elixir.hexdocs.pm/Supervisor.html
    # for other strategies and supported options
    opts = [strategy: :one_for_one, name: Peon.Supervisor]
    Supervisor.start_link(children, opts)
  end

  # Bootstrap, checks and previews touch Docker and the template; tests start
  # them explicitly when needed.
  defp workers do
    if Application.get_env(:peon, :start_workers, true),
      do: [Peon.Bootstrap, Peon.Checks, Peon.Agent.MCP],
      else: []
  end

  # Tell Phoenix to update the endpoint configuration
  # whenever the application is updated.
  @impl true
  def config_change(changed, _new, removed) do
    PeonWeb.Endpoint.config_change(changed, removed)
    :ok
  end
end
