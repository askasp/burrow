defmodule PeonTemplateWeb.HealthController do
  use PeonTemplateWeb, :controller

  @doc "200 when the database answers, 503 otherwise. Used by Peon's health window."
  def show(conn, _params) do
    case Ecto.Adapters.SQL.query(PeonTemplate.Repo, "SELECT 1") do
      {:ok, _} -> text(conn, "ok")
      {:error, _} -> conn |> put_status(503) |> text("database unavailable")
    end
  end
end
