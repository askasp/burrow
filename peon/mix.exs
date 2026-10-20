defmodule Peon.MixProject do
  use Mix.Project

  # Peon, the engine behind each project: its code store, checks, chats and
  # environments (`Peon.Instance`). Burrow hosts the instances and their
  # workspace.
  def project do
    [
      app: :peon,
      version: "0.1.0",
      elixir: "~> 1.17",
      elixirc_paths: elixirc_paths(Mix.env()),
      start_permanent: Mix.env() == :prod,
      aliases: aliases(),
      deps: deps()
    ]
  end

  # Configuration for the OTP application.
  #
  # Type `mix help compile.app` for more information.
  def application do
    [
      mod: {Peon.Application, []},
      extra_applications: [:logger, :runtime_tools]
    ]
  end

  def cli do
    [
      preferred_envs: [precommit: :test]
    ]
  end

  # Specifies which paths to compile per environment.
  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  # Specifies your project dependencies.
  #
  # Type `mix help deps` for examples and options.
  defp deps do
    [
      {:phoenix_pubsub, "~> 2.1"},
      {:ecto_sql, "~> 3.13"},
      {:ecto_sqlite3, ">= 0.0.0"},
      {:jason, "~> 1.2"},
      # MCP for the agent, on a Unix socket
      {:bandit, "~> 1.5"},
      {:plug, "~> 1.16"},
      {:req, "~> 0.5"},
      {:peon_core, path: "../peon_core"}
    ]
  end

  # Aliases are shortcuts or tasks specific to the current project.
  defp aliases do
    [
      test: ["ecto.create --quiet", "ecto.migrate --quiet", "test"],
      precommit: ["compile --warnings-as-errors", "deps.unlock --unused", "format", "test"]
    ]
  end
end
