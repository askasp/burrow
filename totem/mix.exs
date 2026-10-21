defmodule Totem.MixProject do
  use Mix.Project

  def project do
    [
      app: :totem,
      version: "0.1.0",
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      description:
        "Lives inside an Elixir app: knows its code, hot-loads new code, reports its health.",
      package: [licenses: ["MIT"], links: %{"GitHub" => "https://github.com/askasp/burrow"}],
      deps: []
    ]
  end

  def application do
    [mod: {Totem.Application, []}, extra_applications: [:logger, :crypto]]
  end
end
