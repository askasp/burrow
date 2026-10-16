defmodule PeonTemplateWeb.PageControllerTest do
  use PeonTemplateWeb.ConnCase

  test "GET / without logging in follows the site's access mode", %{conn: conn} do
    conn = get(conn, ~p"/")

    if PeonTemplate.SiteAccess.accounts?(),
      do: assert(redirected_to(conn) == ~p"/users/log-in"),
      else: assert(html_response(conn, 200))
  end

  describe "logged in" do
    setup :register_and_log_in_user

    test "GET /", %{conn: conn} do
      conn = get(conn, ~p"/")
      assert html_response(conn, 200) =~ "Peace of mind from prototype to production"
    end
  end
end
