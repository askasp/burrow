defmodule BurrowWeb.ProjectController do
  use BurrowWeb, :controller

  alias Burrow.{Accounts, Cell, Projects}

  @doc """
  Signs the user into the project's Peon, at chat `chat` when given, and
  remembers it as the project to open after the next login. While the Peon
  is still starting (a new project), a page says so and tries again.
  """
  def open(conn, %{"id" => id} = params) do
    scope = conn.assigns.current_scope
    project = Projects.get!(scope, id)
    Accounts.opened_project(scope.user, project.id)

    to =
      if is_binary(params["chat"]) and params["chat"] =~ ~r/\A[a-z0-9]+\z/,
        do: "/c/#{params["chat"]}"

    case Cell.status(project.id) do
      status when status in [:running, :stopped] ->
        redirect(conn,
          external: Projects.peon_url(project, scope.user.email, to, scope.user.theme)
        )

      status ->
        conn
        |> put_view(BurrowWeb.PageHTML)
        |> render(:opening, project: project, exited?: match?({:exited, _}, status))
    end
  end
end
