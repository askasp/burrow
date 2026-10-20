defmodule Peon.Application do
  # See https://elixir.hexdocs.pm/Application.html
  # for more information on OTP Applications
  @moduledoc false

  use Application

  # What every project's Peon (`Peon.Instance`) shares. The instances
  # themselves are started by their host, Burrow.
  @impl true
  def start(_type, _args) do
    children =
      [
        {Phoenix.PubSub, name: Peon.PubSub},
        {Task.Supervisor, name: Peon.TaskSupervisor},
        {Registry, keys: :unique, name: Peon.Registry}
      ] ++ test_repo()

    Supervisor.start_link(children, strategy: :one_for_one, name: Peon.Supervisor)
  end

  # Tests run one instance on `Peon.Repo` itself, in the SQL sandbox.
  defp test_repo do
    if Application.get_env(:peon, :test_repo, false),
      do: [Peon.Repo, {Ecto.Migrator, repos: [Peon.Repo], skip: false}],
      else: []
  end
end
