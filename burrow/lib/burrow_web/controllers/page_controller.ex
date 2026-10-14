defmodule BurrowWeb.PageController do
  use BurrowWeb, :controller

  def home(conn, _params) do
    if conn.assigns.current_scope && conn.assigns.current_scope.user,
      do: redirect(conn, to: ~p"/projects"),
      else: render(conn, :home)
  end
end
