defmodule BurrowWeb.PreviewPassTest do
  # Changes :port_url
  use BurrowWeb.ConnCase, async: false

  import Burrow.AccountsFixtures
  import Burrow.ProjectFixtures

  setup do
    port_url = Application.get_env(:burrow, :port_url)
    Application.put_env(:burrow, :port_url, "https://peon-{port}.localhost")
    on_exit(fn -> Application.put_env(:burrow, :port_url, port_url) end)
  end

  defp logged_in(conn), do: conn |> log_in_user(user_fixture()) |> get(~p"/")

  test "a page gives the logged-in user a pass for every port's address", %{conn: conn} do
    pass = logged_in(conn).resp_cookies["burrow_preview"]

    assert %{domain: "localhost", secure: true, http_only: true, same_site: "Lax"} = pass
    refute get(conn, ~p"/").resp_cookies["burrow_preview"]
  end

  test "a preview lets in the pass and sends anyone else to log in", %{conn: conn} do
    with_pass = logged_in(conn) |> recycle() |> get("/previews/auth?port=21003")
    assert with_pass.status == 204

    without = get(conn, "/previews/auth?port=21003")
    assert without.status == 302
    assert get_resp_header(without, "location") == [BurrowWeb.Endpoint.url() <> "/users/log-in"]
  end

  test "a prod app is open to everyone, its staging isn't", %{conn: conn} do
    project_fixture()

    assert get(conn, "/previews/auth?port=21049").status == 204
    assert get(conn, "/previews/auth?port=21048").status == 302
  end

  test "an internal app's live is only for the people who see its project", %{conn: conn} do
    owner = user_fixture()
    project_fixture(%{auth: "burrow", user_id: owner.id})

    assert get(conn, "/previews/auth?port=21049").status == 302

    assert logged_in(conn) |> recycle() |> get("/previews/auth?port=21049") |> Map.get(:status) ==
             302

    owners = conn |> log_in_user(owner) |> get(~p"/") |> recycle()
    assert get(owners, "/previews/auth?port=21049").status == 204
  end

  test "a running chat's key lets in its own preview's ports", %{conn: conn} do
    Registry.register(Burrow.ChatRegistry, {0, "c"}, %{ports: [21003], busy?: false, key: "k3y"})

    assert Burrow.Ports.url(21003, "k3y") == "https://peon-21003-k3y.localhost"
    assert get(conn, "/previews/auth?port=21003&key=k3y").status == 204
    assert get(conn, "/previews/auth?port=21004&key=k3y").status == 302
    assert get(conn, "/previews/auth?port=21003&key=other").status == 302
    assert get(conn, "/previews/auth?port=21003&key=").status == 302
  end

  test "logging out takes the pass back", %{conn: conn} do
    conn = logged_in(conn) |> recycle() |> delete(~p"/users/log-out")

    assert %{domain: "localhost", max_age: 0} = conn.resp_cookies["burrow_preview"]
  end

  test "ports on plain localhost addresses get no pass or key", %{conn: conn} do
    Application.put_env(:burrow, :port_url, "http://localhost:{port}")

    refute logged_in(conn).resp_cookies["burrow_preview"]
    assert Burrow.Ports.url(21003, "k3y") == "http://localhost:21003"
  end
end
