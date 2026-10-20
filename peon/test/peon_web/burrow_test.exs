defmodule PeonWeb.BurrowTest do
  use PeonWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  setup do
    for {key, value} <- [burrow_api: "http://burrow.test/api/peon/7", api_token: "shared"] do
      previous = Application.get_env(:peon, key)
      Application.put_env(:peon, key, value)
      on_exit(fn -> Application.put_env(:peon, key, previous) end)
    end

    :ok
  end

  test "the rail shows the user's projects from Burrow, this one marked", %{conn: conn} do
    Req.Test.stub(Peon.Burrow, fn conn ->
      assert conn.request_path == "/api/peon/7/projects"
      # The signed-in user (tests sign in as "dev").
      assert Plug.Conn.fetch_query_params(conn).query_params["email"] == "dev"
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer shared"]

      Req.Test.json(conn, %{
        "projects" => [
          %{"id" => 8, "name" => "Sauna Booking", "status" => "running", "url" => "http://b/8"},
          %{"id" => 7, "name" => "watchtower", "status" => "running", "current" => true}
        ]
      })
    end)

    {:ok, view, _html} = live(conn, ~p"/")
    render_async(view)
    assert has_element?(view, ".ws-rail a.ws-tile[href='http://b/8']", "SB")
    assert has_element?(view, ".ws-rail .ws-tile.current[aria-current=page]", "Wa")

    view |> element(".ws-rail-fold") |> render_click()
    assert has_element?(view, ".ws-left.folded")
  end

  test "without Burrow the rail has no projects", %{conn: conn} do
    Req.Test.stub(Peon.Burrow, &Plug.Conn.send_resp(&1, 503, ""))
    {:ok, view, _html} = live(conn, ~p"/")
    render_async(view)
    refute has_element?(view, ".ws-rail .ws-tile:not(.ws-rail-fold)")
  end

  @tag :tmp_dir
  test "Burrow adds staging and prod with the shared token", %{conn: conn, tmp_dir: dir} do
    File.write!(Path.join(dir, "mix.exs"), "defmodule App.MixProject do end")
    {:ok, _} = Peon.Store.import_dir(dir, "app", "App", %{kind: :human, id: "aksel"})
    Peon.Project.put_settings(%{"envs" => "live"})

    assert conn |> post(~p"/api/burrow/add-envs", %{"user" => "a@b.c"}) |> json_response(401)

    assert build_conn()
           |> put_req_header("authorization", "Bearer shared")
           |> post(~p"/api/burrow/add-envs", %{"user" => "a@b.c"})
           |> response(204)

    assert Peon.Project.settings()["envs"] == "pipeline"
  end

  test "signing in from Burrow can open a chat, and only a chat" do
    Application.put_env(:peon, :sso_secret, "sso-secret-at-least-twenty-bytes-long-0123456789")
    on_exit(fn -> Application.delete_env(:peon, :sso_secret) end)

    token =
      Phoenix.Token.sign("sso-secret-at-least-twenty-bytes-long-0123456789", "peon sso", "a@b")

    assert build_conn() |> get(~p"/sso?#{[token: token, to: "/c/abc12"]}") |> redirected_to() ==
             "/c/abc12"

    assert build_conn()
           |> get(~p"/sso?#{[token: token, to: "//evil.example"]}")
           |> redirected_to() ==
             "/"
  end
end
