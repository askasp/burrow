defmodule BurrowWeb.ProjectController do
  use BurrowWeb, :controller

  alias Burrow.Projects

  @doc "Opens the project's workspace (`BurrowWeb.WorkspaceLive`), at chat `chat` when given."
  def open(conn, %{"id" => id} = params) do
    project = Projects.get!(conn.assigns.current_scope, id)

    if is_binary(params["chat"]) and params["chat"] =~ ~r/\A[a-z0-9]+\z/,
      do: redirect(conn, to: ~p"/projects/#{project.id}/c/#{params["chat"]}"),
      else: redirect(conn, to: ~p"/projects/#{project.id}")
  end

  @doc "A workspace's address from when each Peon had its own (`/w/<port>/…`)."
  def old_workspace(conn, %{"port" => port} = params) do
    with {port, ""} <- Integer.parse(port),
         %{} = project <- Projects.get_by_port(port),
         true <- Projects.visible?(conn.assigns.current_scope, project.id) do
      case params["rest"] do
        ["c", chat] -> open(conn, %{"id" => project.id, "chat" => chat})
        _ -> open(conn, %{"id" => project.id})
      end
    else
      _ -> redirect(conn, to: ~p"/projects")
    end
  end
end
