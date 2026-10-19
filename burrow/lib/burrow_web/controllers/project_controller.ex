defmodule BurrowWeb.ProjectController do
  use BurrowWeb, :controller

  alias Burrow.Projects

  @doc "Signs the user into the project's Peon, at chat `chat` when given."
  def open(conn, %{"id" => id} = params) do
    scope = conn.assigns.current_scope
    project = Projects.get!(scope, id)

    to =
      if is_binary(params["chat"]) and params["chat"] =~ ~r/\A[a-z0-9]+\z/,
        do: "/c/#{params["chat"]}"

    redirect(conn, external: Projects.peon_url(project, scope.user.email, to))
  end
end
