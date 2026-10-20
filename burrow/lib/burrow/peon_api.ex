defmodule Burrow.PeonAPI do
  @moduledoc """
  Burrow and each project's Peon talk over HTTP with a token they share
  (`token/1`). Peon asks Burrow for the user's projects, for the project
  rail in its workspace (`BurrowWeb.PeonController`); Burrow asks Peon to
  add staging and prod (`add_envs/2`) and tells it when the rail changed
  (`rail_changed/1`).
  """

  alias Burrow.Projects
  alias Burrow.Projects.Project

  @doc "The token Burrow and the project's Peon use with each other."
  def token(%Project{} = project), do: Projects.secret(project, "peon-api")

  @doc "Where the project's Peon reaches Burrow's API for it."
  def api_url(%Project{id: id}), do: internal_url() <> "/api/peon/#{id}"

  @doc "Has the project's Peon add staging and prod (`Peon.Ship.add_envs/1`)."
  def add_envs(%Project{} = project, user) do
    case post(project, "/api/burrow/add-envs", %{"user" => user}, 15_000) do
      {:ok, %{status: status}} when status in 200..299 -> :ok
      {:ok, %{body: %{"error" => message}}} -> {:error, message}
      {:ok, %{status: status}} -> {:error, "Peon answered #{status}."}
      {:error, _} -> {:error, "Peon isn't running."}
    end
  end

  @doc "Tells the project's Peon that a project in its users' rails changed."
  def rail_changed(%Project{} = project) do
    post(project, "/api/burrow/rail", %{}, 5_000)
    :ok
  end

  defp post(project, path, body, timeout) do
    opts = [
      method: :post,
      url: "http://#{peon_host()}:#{project.port}#{path}",
      auth: {:bearer, token(project)},
      json: body,
      retry: false,
      receive_timeout: timeout
    ]

    # Tests stand in for Peon with `plug: {Req.Test, Burrow.PeonAPI}`.
    Req.request(Keyword.merge(opts, Application.get_env(:burrow, :peon_req, [])))
  end

  # Burrow runs the Peons itself (`Burrow.Cell`), so both sides are local.
  defp peon_host, do: Application.get_env(:burrow, :peon_internal_host, "127.0.0.1")

  defp internal_url do
    Application.get_env(:burrow, :internal_url) ||
      "http://127.0.0.1:#{Application.get_env(:burrow, BurrowWeb.Endpoint)[:http][:port] || 4000}"
  end
end
