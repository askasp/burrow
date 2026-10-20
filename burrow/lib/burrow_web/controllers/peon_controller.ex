defmodule BurrowWeb.PeonController do
  @moduledoc """
  Each project's Peon, with the token it shares with Burrow
  (`Burrow.PeonAPI`): the projects its user can open, for the project rail
  in the workspace.
  """

  use BurrowWeb, :controller

  alias Burrow.{Accounts, Cell, PeonAPI, Projects}
  alias Burrow.Accounts.Scope

  @doc "The projects `email` can open, if they can open this one."
  def projects(conn, %{"id" => id, "email" => email}) do
    with %{} = project <- Projects.get(id),
         "Bearer " <> given <- conn |> get_req_header("authorization") |> List.first(""),
         true <- Plug.Crypto.secure_compare(given, PeonAPI.token(project)),
         %{} = user <- Accounts.get_user_by_email(email),
         projects = Projects.list(Scope.for_user(user)),
         true <- Enum.any?(projects, &(&1.id == project.id)) do
      json(conn, %{
        "projects" =>
          for p <- projects do
            %{
              "id" => p.id,
              "name" => p.name,
              "slug" => p.slug,
              "status" => status(Cell.status(p.id)),
              "url" => url(~p"/projects/#{p.id}/open"),
              "current" => p.id == project.id
            }
          end
      })
    else
      _ -> conn |> put_status(401) |> json(%{"error" => "unauthorized"})
    end
  end

  defp status(:running), do: "running"
  defp status(:starting), do: "starting"
  defp status({:exited, _}), do: "exited"
  defp status(_), do: "stopped"
end
