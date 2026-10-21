defmodule Totem.Application do
  @moduledoc false
  use Application

  # Its own application, not a child in the app's tree: it outlives the app
  # stopping, so it can stop and start the app (a warm load).
  @impl true
  def start(_type, _args) do
    children =
      if Application.get_env(:totem, :server, true),
        do: [Totem.Server, Totem.Monitor, Totem.Link],
        else: []

    Supervisor.start_link(children, strategy: :one_for_one, name: Totem.Supervisor)
  end
end
