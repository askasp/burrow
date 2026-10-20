defmodule PeonTemplateWeb.SiteAccessTest do
  # Not async: the tests set the SITE_PASSWORD and BASIC_AUTH_* environment
  # variables and turn on the password check, which other tests run without.
  use PeonTemplateWeb.ConnCase, async: false

  alias PeonTemplateWeb.SiteAccess

  @env %{
    "SITE_PASSWORD" => "open sesame",
    "BASIC_AUTH_USERNAME" => "ada",
    "BASIC_AUTH_PASSWORD" => "lovelace"
  }

  setup do
    previous = Map.new(@env, fn {name, _} -> {name, System.get_env(name)} end)
    System.put_env(@env)
    Application.put_env(:peon_template, :enforce_site_password, true)

    on_exit(fn ->
      Application.put_env(:peon_template, :enforce_site_password, false)

      for {name, value} <- previous do
        if value, do: System.put_env(name, value), else: System.delete_env(name)
      end
    end)
  end

  defp browser_conn(conn, path) do
    conn
    |> Map.put(:request_path, path)
    |> Map.put(:path_info, String.split(path, "/", trim: true))
    |> init_test_session(%{})
    |> fetch_flash()
  end

  defp with_login(conn, user, pw),
    do: put_req_header(conn, "authorization", Plug.BasicAuth.encode_basic_auth(user, pw))

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

      # The page itself, whatever this app's mode is.
      Application.put_env(:peon_template, :enforce_site_password, false)
      assert conn |> get(~p"/unlock") |> html_response(200) =~ "been set."
    end
  end

  describe "basic auth" do
    test "asks the browser for the login", %{conn: conn} do
      conn = conn |> browser_conn("/things") |> SiteAccess.check_site_password(:basic_auth)

      assert conn.halted
      assert conn.status == 401
      assert [~s(Basic realm="This site")] = get_resp_header(conn, "www-authenticate")
    end

    test "lets the right login through and remembers it for LiveViews", %{conn: conn} do
      conn =
        conn
        |> browser_conn("/things")
        |> with_login("ada", "lovelace")
        |> SiteAccess.check_site_password(:basic_auth)

      refute conn.halted
      session = get_session(conn)

      assert {:cont, _socket} =
               SiteAccess.on_mount({:app, :basic_auth}, %{}, session, %Phoenix.LiveView.Socket{})

      System.put_env("BASIC_AUTH_PASSWORD", "new one")

      assert {:halt, _socket} =
               SiteAccess.on_mount({:app, :basic_auth}, %{}, session, %Phoenix.LiveView.Socket{})
    end

    test "turns away a wrong username or password", %{conn: conn} do
      for {user, pw} <- [{"ada", "nope"}, {"bob", "lovelace"}, {"", ""}] do
        conn =
          conn
          |> browser_conn("/things")
          |> with_login(user, pw)
          |> SiteAccess.check_site_password(:basic_auth)

        assert conn.halted and conn.status == 401
      end
    end

    test "until both secrets are set nobody gets in", %{conn: conn} do
      System.delete_env("BASIC_AUTH_PASSWORD")

      conn =
        conn
        |> browser_conn("/things")
        |> with_login("ada", "lovelace")
        |> SiteAccess.check_site_password(:basic_auth)

      assert conn.halted and conn.status == 401
    end

    test "/health needs no login", %{conn: conn} do
      assert conn |> get(~p"/health") |> response(200)
    end
  end

  test "public mode asks for nothing", %{conn: conn} do
    conn = conn |> browser_conn("/things")

    refute SiteAccess.check_site_password(conn, :public).halted
    refute SiteAccess.check_app_access(conn, [], :public).halted
  end

  # peon:if-accounts
  test "login mode doesn't ask for a password", %{conn: conn} do
    refute conn
           |> browser_conn("/things")
           |> SiteAccess.check_site_password(:login)
           |> Map.get(:halted)
  end

  test "login mode requires a user on the app's pages; the others don't", %{conn: conn} do
    conn = conn |> browser_conn("/things") |> assign(:current_scope, nil)

    assert SiteAccess.check_app_access(conn, [], :login).halted
    refute SiteAccess.check_app_access(conn, [], :public).halted
    refute SiteAccess.check_app_access(conn, [], :shared_password).halted
    refute SiteAccess.check_app_access(conn, [], :basic_auth).halted
  end

  # peon:end
  describe "/unlock" do
    # The page itself, whatever this app's mode is.
    setup do: Application.put_env(:peon_template, :enforce_site_password, false)

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
