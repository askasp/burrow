defmodule PeonTemplateWeb.SiteAccessTest do
  # Not async: the tests set the SITE_PASSWORD environment variable and
  # turn on the password check, which other tests run without.
  use PeonTemplateWeb.ConnCase, async: false

  alias PeonTemplateWeb.SiteAccess

  setup do
    previous = System.get_env("SITE_PASSWORD")
    System.put_env("SITE_PASSWORD", "open sesame")
    Application.put_env(:peon_template, :enforce_site_password, true)

    on_exit(fn ->
      Application.put_env(:peon_template, :enforce_site_password, false)

      if previous,
        do: System.put_env("SITE_PASSWORD", previous),
        else: System.delete_env("SITE_PASSWORD")
    end)
  end

  defp browser_conn(conn, path) do
    conn
    |> Map.put(:request_path, path)
    |> Map.put(:path_info, String.split(path, "/", trim: true))
    |> init_test_session(%{})
    |> fetch_flash()
  end

  describe "shared password" do
    test "sends visitors to /unlock and remembers where they were going", %{conn: conn} do
      conn = conn |> browser_conn("/things") |> SiteAccess.check_site_password(:shared_password)

      assert conn.halted
      assert redirected_to(conn) == ~p"/unlock"
      assert get_session(conn, :site_return_to) == "/things"
    end

    test "lets the unlock page itself through", %{conn: conn} do
      conn = conn |> browser_conn("/unlock") |> SiteAccess.check_site_password(:shared_password)
      refute conn.halted
    end

    test "lets visitors through once they entered the password", %{conn: conn} do
      conn =
        conn
        |> browser_conn("/things")
        |> SiteAccess.unlock()
        |> SiteAccess.check_site_password(:shared_password)

      refute conn.halted
    end

    test "a new password locks everyone out again", %{conn: conn} do
      conn = conn |> browser_conn("/things") |> SiteAccess.unlock()
      System.put_env("SITE_PASSWORD", "new one")

      assert conn |> SiteAccess.check_site_password(:shared_password) |> Map.get(:halted)
    end

    test "without SITE_PASSWORD nobody gets in", %{conn: conn} do
      System.delete_env("SITE_PASSWORD")
      refute SiteAccess.valid_password?("")
      refute SiteAccess.valid_password?("open sesame")

      assert conn |> get(~p"/unlock") |> html_response(200) =~ "been set."
    end
  end

  test "other modes don't ask for the password", %{conn: conn} do
    for mode <- [:login, :public] do
      refute conn
             |> browser_conn("/things")
             |> SiteAccess.check_site_password(mode)
             |> Map.get(:halted)
    end
  end

  test "login mode requires a user on the app's pages; public doesn't", %{conn: conn} do
    conn = conn |> browser_conn("/things") |> assign(:current_scope, nil)

    assert SiteAccess.check_app_access(conn, [], :login).halted
    refute SiteAccess.check_app_access(conn, [], :public).halted
    refute SiteAccess.check_app_access(conn, [], :shared_password).halted
  end

  describe "/unlock" do
    test "the right password unlocks and returns to the page", %{conn: conn} do
      conn =
        conn
        |> init_test_session(%{site_return_to: "/things"})
        |> post(~p"/unlock", %{"password" => "open sesame"})

      assert redirected_to(conn) == "/things"
      assert get_session(conn, "site_password")
    end

    test "a wrong password doesn't", %{conn: conn} do
      conn = post(conn, ~p"/unlock", %{"password" => "nope"})

      assert html_response(conn, 401) =~ "not the password"
      refute get_session(conn, "site_password")
    end
  end
end
