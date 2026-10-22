defmodule BurrowWeb.BasicAuthTest do
  use BurrowWeb.ConnCase, async: false

  setup do
    Application.put_env(:burrow, :basic_auth, username: "owner", password: "secret")
    on_exit(fn -> Application.delete_env(:burrow, :basic_auth) end)
  end

  defp login(conn, user, pass),
    do: put_req_header(conn, "authorization", Plug.BasicAuth.encode_basic_auth(user, pass))

  test "the site asks for the login", %{conn: conn} do
    conn = get(conn, ~p"/users/log-in")
    assert conn.status == 401
    assert get_resp_header(conn, "www-authenticate") == [~s(Basic realm="Burrow")]
  end

  test "a wrong password gets nothing", %{conn: conn} do
    assert conn |> login("owner", "nope") |> get(~p"/users/log-in") |> Map.get(:status) == 401
  end

  test "the login opens it", %{conn: conn} do
    assert conn |> login("owner", "secret") |> get(~p"/users/log-in") |> html_response(200)
  end

  test "boards and the manifest stay open", %{conn: conn} do
    refute get(conn, "/design/bad-token/x.html").status == 401
    refute get(conn, ~p"/manifest.webmanifest").status == 401
  end
end
