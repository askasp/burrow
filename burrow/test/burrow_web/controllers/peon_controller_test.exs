defmodule BurrowWeb.PeonControllerTest do
  use BurrowWeb.ConnCase

  import Burrow.AccountsFixtures

  alias Burrow.Accounts.Scope
  alias Burrow.{Accounts, PeonAPI, Projects, Teams}

  setup do
    # No Peon runs; one that is asked answers as a stopped one would.
    Req.Test.stub(PeonAPI, &Plug.Conn.send_resp(&1, 503, ""))
    user = user_fixture()
    scope = Scope.for_user(user)
    {:ok, team} = Teams.create(scope, %{"name" => "Ops"})
    {:ok, project} = Projects.create(scope, %{"name" => "Watchtower"})
    %{user: user, scope: scope, team: team, project: project}
  end

  defp peon(project),
    do: put_req_header(build_conn(), "authorization", "Bearer " <> PeonAPI.token(project))

  test "the rail: each project with its tile, the user's rail choice and this project's sharing",
       %{user: user, project: project, team: team} do
    body =
      peon(project)
      |> get(~p"/api/peon/#{project.id}/projects?email=#{user.email}")
      |> json_response(200)

    # No Peon runs in tests, so the tile says stopped.
    assert [%{"current" => true, "state" => "stopped", "label" => "stopped", "pct" => 8}] =
             body["projects"]

    assert body["rail_open"] == false

    assert body["project"] == %{
             "owner" => true,
             "live_only" => true,
             "team" => nil,
             "teams" => [%{"id" => team.id, "name" => "Ops"}],
             "teammates" => []
           }
  end

  test "the rail choice is remembered", %{user: user, project: project} do
    assert peon(project)
           |> post(~p"/api/peon/#{project.id}/prefs", %{email: user.email, rail_open: true})
           |> response(204)

    assert Accounts.get_user!(user.id).rail_open
  end

  test "a new project from the workspace", %{user: user, project: project, team: team} do
    assert %{"id" => id, "url" => url} =
             peon(project)
             |> post(~p"/api/peon/#{project.id}/projects", %{
               email: user.email,
               name: "Field notes",
               team_id: to_string(team.id),
               auth: "open"
             })
             |> json_response(200)

    assert url =~ "/projects/#{id}/open"
    assert %{name: "Field notes", team_id: team_id, auth: "open"} = Projects.get(id)
    assert team_id == team.id

    assert %{"error" => "Name can't be blank"} =
             peon(project)
             |> post(~p"/api/peon/#{project.id}/projects", %{email: user.email, name: ""})
             |> json_response(422)
  end

  test "sharing and handing over from the workspace", %{user: user, project: project, team: team} do
    mate = user_fixture()
    {:ok, _} = Teams.add_member(Scope.for_user(user), team, mate.email)

    assert peon(project)
           |> post(~p"/api/peon/#{project.id}/share", %{email: user.email, team_id: team.id})
           |> response(204)

    assert Projects.get(project.id).team_id == team.id

    # A teammate sees it but can't share it on.
    assert %{"error" => "Only the project's owner can share it."} =
             peon(project)
             |> post(~p"/api/peon/#{project.id}/share", %{email: mate.email, team_id: nil})
             |> json_response(422)

    assert %{"error" => _} =
             peon(project)
             |> post(~p"/api/peon/#{project.id}/hand-over", %{email: user.email, user_id: "x"})
             |> json_response(422)
  end

  test "a Peon reports its activity with its own token only", %{project: project} do
    activity = %{state: "working", label: "working", pct: 40}

    assert peon(project) |> post(~p"/api/peon/#{project.id}/status", activity) |> response(204)

    assert build_conn()
           |> put_req_header("authorization", "Bearer nope")
           |> post(~p"/api/peon/#{project.id}/status", activity)
           |> json_response(401)
  end

  test "after login Burrow opens the project opened last", %{user: user, project: project} do
    conn = log_in_user(build_conn(), user)
    assert conn |> get(~p"/") |> redirected_to() == ~p"/projects"

    assert conn |> get(~p"/projects/#{project.id}/open") |> redirected_to() =~ "/sso?"
    assert Accounts.get_user!(user.id).last_project_id == project.id

    assert log_in_user(build_conn(), user) |> get(~p"/") |> redirected_to() ==
             ~p"/projects/#{project.id}/open"
  end

  test "the theme: set in Burrow's header, pinned on every page, passed to Peon", %{
    user: user,
    project: project
  } do
    conn = log_in_user(build_conn(), user)
    assert get(conn, ~p"/projects") |> html_response(200) =~ ~s(data-theme="system")

    conn =
      conn
      |> put_req_header("referer", "http://localhost/teams")
      |> post(~p"/users/theme", %{theme: "dark"})

    assert redirected_to(conn) == "/teams"
    assert Accounts.get_user!(user.id).theme == "dark"

    conn = log_in_user(build_conn(), Accounts.get_user!(user.id))
    assert get(conn, ~p"/projects") |> html_response(200) =~ ~s(data-theme="dark")
    assert get(conn, ~p"/projects/#{project.id}/open") |> redirected_to() =~ "theme=dark"

    # From a workspace, through its Peon
    assert peon(project)
           |> post(~p"/api/peon/#{project.id}/prefs", %{email: user.email, theme: "light"})
           |> response(204)

    assert %{"theme" => "light"} =
             peon(project)
             |> get(~p"/api/peon/#{project.id}/projects?email=#{user.email}")
             |> json_response(200)

    assert peon(project)
           |> post(~p"/api/peon/#{project.id}/prefs", %{email: user.email, theme: "pink"})
           |> json_response(422)
  end
end
