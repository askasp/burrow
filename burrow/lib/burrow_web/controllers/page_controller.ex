defmodule BurrowWeb.PageController do
  use BurrowWeb, :controller

  alias Burrow.Projects

  # Signed in, Burrow opens the workspace of the project opened last; the
  # project list is for when there is none.
  def home(conn, _params) do
    case conn.assigns.current_scope do
      %{user: %{} = user} = scope ->
        if user.last_project_id && Projects.visible?(scope, user.last_project_id),
          do: redirect(conn, to: ~p"/projects/#{user.last_project_id}/open"),
          else: redirect(conn, to: ~p"/projects")

      _ ->
        render(conn, :home)
    end
  end
end
