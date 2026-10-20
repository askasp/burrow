defmodule PeonWeb.BurrowTest do
  use PeonWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    for {key, value} <- [
          burrow_api: "http://burrow.test/api/peon/7",
          burrow_url: "http://burrow.test",
          api_token: "shared"
        ] do
      previous = Application.get_env(:peon, key)
      Application.put_env(:peon, key, value)
      on_exit(fn -> Application.put_env(:peon, key, previous) end)
    end

    File.write!(Path.join(dir, "mix.exs"), "defmodule App.MixProject do end")

    {:ok, _} =
      Peon.Store.import_dir(dir, "watchtower", "Watchtower", %{kind: :human, id: "aksel"})

    :ok
  end

  test "the rail shows the user's projects from Burrow, with their health", %{conn: conn} do
    Req.Test.stub(Peon.Burrow, fn conn ->
      assert conn.request_path == "/api/peon/7/projects"
      # The signed-in user (tests sign in as "dev").
      assert Plug.Conn.fetch_query_params(conn).query_params["email"] == "dev"
      assert Plug.Conn.get_req_header(conn, "authorization") == ["Bearer shared"]
      Req.Test.json(conn, rail())
    end)

    {:ok, view, _html} = open(conn)
    render_async(view)
    assert has_element?(view, ".rail a.ritem[href='http://b/8'][title='Sauna Booking · working']")

    assert has_element?(
             view,
             ".rail a.ritem[href='http://b/8'] .rhp.working i[style='width: 40%']"
           )

    assert has_element?(view, ".rail .ritem[aria-current=page]", "watchtower")
    assert has_element?(view, ".pbar-meta", "shared with Ops")
    refute has_element?(view, ".rail.open")
  end

  test "the rail opens and Burrow remembers it", %{conn: conn} do
    parent = self()

    Req.Test.stub(Peon.Burrow, fn
      %{method: "GET"} = conn ->
        Req.Test.json(conn, rail())

      conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(parent, {conn.request_path, JSON.decode!(body)})
        Plug.Conn.send_resp(conn, 204, "")
    end)

    {:ok, view, _html} = open(conn)
    render_async(view)
    view |> element(".rcollapse") |> render_click()
    assert has_element?(view, ".rail.open")
    assert_receive {"/api/peon/7/prefs", %{"email" => "dev", "rail_open" => true}}
  end

  test "a burrow push fetches the rail again", %{conn: conn} do
    test = self()

    Req.Test.stub(Peon.Burrow, fn conn ->
      send(test, :fetched)
      Req.Test.json(conn, rail())
    end)

    {:ok, view, _html} = open(conn)
    assert_receive :fetched

    assert build_conn()
           |> put_req_header("authorization", "Bearer shared")
           |> post(~p"/api/burrow/rail", %{})
           |> response(204)

    render(view)
    assert_receive :fetched
  end

  test "a new project from the rail is created in Burrow and opened", %{conn: conn} do
    parent = self()

    Req.Test.stub(Peon.Burrow, fn
      %{method: "GET"} = conn ->
        Req.Test.json(conn, rail())

      %{request_path: "/api/peon/7/projects"} = conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        send(parent, {:created, JSON.decode!(body)})
        Req.Test.json(conn, %{"id" => 9, "url" => "http://burrow.test/projects/9/open"})
    end)

    {:ok, view, _html} = open(conn)
    render_async(view)
    view |> element("#new-project-btn") |> render_click()
    assert has_element?(view, "#new-project[phx-hook]")
    assert has_element?(view, "#new-project button[type=submit][disabled]")

    view
    |> element("#new-project-form")
    |> render_change(%{"project" => %{"name" => "Field notes"}})

    assert has_element?(view, "#np-slug", "slug: field_notes")
    view |> element("#new-project button.disc") |> render_click()
    assert has_element?(view, "#np-share option", "Ops")

    view
    |> element("#new-project-form")
    |> render_submit(%{
      "project" => %{"name" => "Field notes", "team_id" => "3", "auth" => "open"}
    })

    assert_receive {:created,
                    %{
                      "email" => "dev",
                      "name" => "Field notes",
                      "team_id" => "3",
                      "auth" => "open"
                    }}

    assert_redirect(view, "http://burrow.test/projects/9/open")
  end

  test "without Burrow the rail holds just this project", %{conn: conn} do
    Application.put_env(:peon, :burrow_api, nil)
    Application.put_env(:peon, :burrow_url, nil)
    {:ok, view, _html} = open(conn)
    render_async(view)
    assert has_element?(view, ".rail .ritem[aria-current=page]")
    refute has_element?(view, "#new-project-btn")
  end

  test "this Peon reports what its project is doing" do
    parent = self()

    Req.Test.stub(Peon.Burrow, fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      send(parent, {conn.request_path, JSON.decode!(body)})
      Plug.Conn.send_resp(conn, 204, "")
    end)

    assert :ok = Peon.Burrow.report(%{"state" => "working", "label" => "working", "pct" => 40})
    assert_receive {"/api/peon/7/status", %{"state" => "working", "pct" => 40}}
  end

  defp rail do
    %{
      "projects" => [
        %{
          "id" => 8,
          "name" => "Sauna Booking",
          "url" => "http://b/8",
          "state" => "working",
          "label" => "working",
          "pct" => 40
        },
        %{
          "id" => 7,
          "name" => "watchtower",
          "current" => true,
          "state" => "done",
          "label" => "live"
        }
      ],
      "rail_open" => false,
      "project" => %{
        "owner" => true,
        "team" => %{"id" => 3, "name" => "Ops"},
        "teams" => [%{"id" => 3, "name" => "Ops"}],
        "teammates" => []
      }
    }
  end

  # "/" opens the first chat.
  defp open(conn) do
    {:error, {:live_redirect, %{to: to}}} = live(conn, ~p"/")
    live(conn, to)
  end

  test "Burrow adds staging and prod with the shared token", %{conn: conn} do
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
