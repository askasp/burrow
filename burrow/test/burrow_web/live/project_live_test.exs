defmodule BurrowWeb.ProjectLiveTest do
  use BurrowWeb.ConnCase

  # The AI login check has no opencode to talk to in tests.
  @moduletag :capture_log

  import Phoenix.LiveViewTest
  import Burrow.AccountsFixtures

  import Ecto.Query

  alias Burrow.Accounts.Scope
  alias Burrow.{PeonAPI, Projects, Teams}

  setup :register_and_log_in_user

  setup do
    # No Peon runs; one that is asked answers as a stopped one would.
    Req.Test.stub(PeonAPI, &Plug.Conn.send_resp(&1, 503, ""))
    :ok
  end

  test "creates a project and shows the slug it gets", %{conn: conn, user: user} do
    {:ok, lv, _html} = live(conn, ~p"/projects")
    # With no projects yet the form is open.
    refute has_element?(lv, "#new-project")

    assert lv |> form("#project_form", project: %{name: "Sauna Booking"}) |> render_change() =~
             "slug: sauna_booking"

    lv |> form("#project_form", project: %{name: "Sauna Booking"}) |> render_submit()
    assert has_element?(lv, "#selected-project h2", "Sauna Booking")
    assert has_element?(lv, "#project-meta", "sauna_booking · live")
    refute has_element?(lv, "#project_form")

    # With projects, New project opens the form.
    lv |> element("#new-project") |> render_click()
    assert has_element?(lv, "#project_form")
    lv |> element("#project_form button", "Cancel") |> render_click()
    refute has_element?(lv, "#project_form")
    assert [_] = Projects.list(Scope.for_user(user))
  end

  test "a new app can use one basic-auth login instead of accounts", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/projects")
    refute has_element?(lv, "#project_basic_password")

    lv |> form("#project_form", project: %{name: "Stash", auth: "basic"}) |> render_change()
    assert has_element?(lv, "#project_basic_password[type=password]")

    html =
      lv
      |> form("#project_form",
        project: %{name: "Stash", auth: "basic", basic_username: "team", basic_password: "short"}
      )
      |> render_submit()

    assert html =~ "should be at least 8 character"

    lv
    |> form("#project_form",
      project: %{
        name: "Stash",
        auth: "basic",
        basic_username: "team",
        basic_password: "long enough"
      }
    )
    |> render_submit()

    assert has_element?(lv, "#selected-project h2", "Stash")
    assert [%{auth: "basic"}] = Burrow.Repo.all(Burrow.Projects.Project)

    # A repo keeps its own login, so the choice goes away.
    lv |> element("#new-project") |> render_click()

    lv
    |> form("#project_form", project: %{repo_url: "https://github.com/a/b.git"})
    |> render_change()

    refute has_element?(lv, "#project_auth")
  end

  test "the owner shares a project with a team; teammates see it", %{conn: conn, user: user} do
    scope = Scope.for_user(user)
    {:ok, team} = Teams.create(scope, %{"name" => "Ops"})
    mate = user_fixture()
    {:ok, _} = Teams.add_member(scope, team, mate.email)
    {:ok, project} = Projects.create(scope, %{"name" => "Procedures"})

    {:ok, lv, _html} = live(conn, ~p"/projects?p=#{project.id}")
    refute has_element?(lv, "#share-form")
    assert has_element?(lv, "#project-menu-button[aria-expanded='false']")
    lv |> element("#project-menu-button") |> render_click()
    assert has_element?(lv, "#project-menu-button[aria-expanded='true']")
    lv |> element("#project-menu button", "Share") |> render_click()
    lv |> form("#share-form", share: %{team_id: team.id}) |> render_change()
    assert has_element?(lv, "#project-#{project.id}", "shared")
    assert Projects.get!(scope, project.id).team_id == team.id

    {:ok, mate_lv, _html} = live(log_in_user(build_conn(), mate), ~p"/projects")
    assert has_element?(mate_lv, "#project-#{project.id}", user.email)
    refute has_element?(mate_lv, "#project-menu-button")
  end

  test "a project with staging and prod keeps its overview", %{conn: conn, user: user} do
    {:ok, project} = Projects.create(Scope.for_user(user), %{"name" => "Procedures"})
    pipeline!(project)

    {:ok, lv, _html} = live(conn, ~p"/projects?p=#{project.id}")
    assert has_element?(lv, "#restart-peon")
    assert has_element?(lv, "#selected-project", "Only you can see it.")
    assert has_element?(lv, "#project-meta", "staging and prod · Peon on port #{project.port}")

    lv |> element("#project-menu-button") |> render_click()
    refute has_element?(lv, "#add-envs")
  end

  describe "a live-only project" do
    setup %{user: user} do
      {:ok, project} = Projects.create(Scope.for_user(user), %{"name" => "Watchtower"})
      %{project: project}
    end

    test "its row opens its workspace; the arrow shows its details", %{
      conn: conn,
      project: project
    } do
      {:ok, lv, _html} = live(conn, ~p"/projects")

      assert has_element?(
               lv,
               "#project-#{project.id} a.prow[href='/projects/#{project.id}/open']"
             )

      refute has_element?(lv, "#open-workspace")

      lv |> element("#project-#{project.id} .prow-more") |> render_click()
      assert_patch(lv, ~p"/projects?p=#{project.id}")
      assert has_element?(lv, "#selected-project #restart-peon")
    end

    test "add staging and prod turns it into a pipeline project", %{conn: conn, project: project} do
      {:ok, lv, _html} = live(conn, ~p"/projects?p=#{project.id}")
      running!(project)

      Req.Test.stub(PeonAPI, fn conn ->
        assert conn.request_path == "/api/burrow/add-envs"
        Plug.Conn.send_resp(conn, 204, "")
      end)

      lv |> element("#project-menu-button") |> render_click()
      lv |> element("#add-envs") |> render_click()
      assert render(lv) =~ "Watchtower has staging and prod now."
      assert Projects.get(project.id).envs == "pipeline"
    end

    test "its Peon gets the projects the user can open, with the shared token", %{
      project: project,
      user: user
    } do
      {:ok, other} = Projects.create(Scope.for_user(user), %{"name" => "Stash"})
      path = ~p"/api/peon/#{project.id}/projects?email=#{user.email}"

      assert %{"projects" => projects} =
               build_conn()
               |> put_req_header("authorization", "Bearer " <> PeonAPI.token(project))
               |> get(path)
               |> json_response(200)

      assert [
               %{"id" => other_id, "current" => false, "name" => "Stash"},
               %{"id" => id, "current" => true, "url" => url}
             ] = projects

      assert {other_id, id} == {other.id, project.id}
      assert url =~ "/projects/#{project.id}/open"

      assert build_conn()
             |> put_req_header("authorization", "Bearer nope")
             |> get(path)
             |> json_response(401)

      # Someone who can't open this project gets nothing.
      stranger = user_fixture()

      assert build_conn()
             |> put_req_header("authorization", "Bearer " <> PeonAPI.token(project))
             |> get(~p"/api/peon/#{project.id}/projects?email=#{stranger.email}")
             |> json_response(401)
    end
  end

  # Tests run no Peons; tell the page this one runs, as its cell would.
  defp running!(project),
    do: Phoenix.PubSub.broadcast(Burrow.PubSub, "cells", {:cell, project.id, :running})

  defp pipeline!(project) do
    Burrow.Repo.update_all(
      from(p in Burrow.Projects.Project, where: p.id == ^project.id),
      set: [envs: "pipeline"]
    )
  end
end
