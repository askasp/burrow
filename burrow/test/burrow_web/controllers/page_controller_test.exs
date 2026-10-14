defmodule BurrowWeb.PageControllerTest do
  use BurrowWeb.ConnCase

  test "GET /", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert html_response(conn, 200) =~ "Your own Peon writes it"
  end
end
