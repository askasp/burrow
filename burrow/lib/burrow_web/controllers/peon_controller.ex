defmodule BurrowWeb.PeonController do
  @moduledoc "Where a project's Peon pushes its inline chat's state (`Burrow.Inline`)."

  use BurrowWeb, :controller

  alias Burrow.{Inline, Projects}

  def inline(conn, %{"id" => id}) do
    with %{} = project <- Projects.get(id),
         "Bearer " <> given <- conn |> get_req_header("authorization") |> List.first(""),
         true <- Plug.Crypto.secure_compare(given, Inline.token(project)) do
      Inline.put(project.id, conn.body_params)
      send_resp(conn, 204, "")
    else
      _ -> conn |> put_status(401) |> json(%{"error" => "unauthorized"})
    end
  end
end
