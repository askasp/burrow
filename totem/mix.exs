defmodule Totem.MixProject do
  use Mix.Project

  def project do
    [
      app: :totem,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      elixirc_paths: if(Mix.env() == :test, do: ["lib", "test/support"], else: ["lib"]),
      description:
        "Lives inside an Elixir app: knows its code, hot-loads new code, reports its health.",
      package: [licenses: ["MIT"], links: %{"GitHub" => "https://github.com/askasp/burrow"}],
      deps: deps()
    ]
  end

  # Plug only for `Totem.Plug` (HTTP and MCP), when the app has Plug.
  defp deps, do: [{:plug, "~> 1.14", optional: true}]

  def application do
    [
      mod: {Totem.Application, []},
      extra_applications: [:logger, :crypto, :runtime_tools, inets: :optional, ssl: :optional]
    ]
  end
end
