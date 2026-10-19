defmodule PeonTemplateWeb.PageControllerTest do
  use PeonTemplateWeb.ConnCase

  test "GET / without logging in follows the site's access mode", %{conn: conn} do
    conn = get(conn, ~p"/")

    if PeonTemplate.SiteAccess.accounts?(),
      do: assert(redirected_to(conn) == ~p"/users/log-in"),
      else: assert(html_response(conn, 200))
  end

  test "only the configured origins may show the app in a frame", %{conn: conn} do
    previous = Application.get_env(:peon_template, :frame_ancestors)
    Application.put_env(:peon_template, :frame_ancestors, "'self' https://burrow.example")
    on_exit(fn -> Application.put_env(:peon_template, :frame_ancestors, previous) end)

    [csp] = conn |> get(~p"/") |> get_resp_header("content-security-policy")
    assert csp =~ "frame-ancestors 'self' https://burrow.example;"
  end

  describe "logged in" do
    setup :register_and_log_in_user

    test "GET /", %{conn: conn} do
      conn = get(conn, ~p"/")
      assert html_response(conn, 200) =~ "Peace of mind from prototype to production"
    end
  end
end
