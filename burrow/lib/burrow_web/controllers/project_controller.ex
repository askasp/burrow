defmodule BurrowWeb.ProjectController do
  use BurrowWeb, :controller

  alias Burrow.Projects

  @doc "Signs the user into the project's Peon."
  def open(conn, %{"id" => id}) do
    scope = conn.assigns.current_scope
    project = Projects.get!(scope, id)
    redirect(conn, external: Projects.peon_url(project, scope.user.email))
  end
end
