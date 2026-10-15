defmodule BurrowWeb.ProjectLiveTest do
  use BurrowWeb.ConnCase

  # The AI login check has no opencode to talk to in tests.
  @moduletag :capture_log

  import Phoenix.LiveViewTest
  import Burrow.AccountsFixtures

  alias Burrow.Accounts.Scope
  alias Burrow.{Projects, Teams}

  setup :register_and_log_in_user

  test "creates a project and shows the slug it gets", %{conn: conn} do
    {:ok, lv, _html} = live(conn, ~p"/projects")

    assert lv |> form("#project_form", project: %{name: "Sauna Booking"}) |> render_change() =~
             "slug: sauna_booking"

    lv |> form("#project_form", project: %{name: "Sauna Booking"}) |> render_submit()
    assert has_element?(lv, "#selected-project h2", "Sauna Booking")
    assert has_element?(lv, "#selected-project", "Only you can see it.")
  end

  test "the owner shares a project with a team; teammates see it", %{conn: conn, user: user} do
    scope = Scope.for_user(user)
    {:ok, team} = Teams.create(scope, %{"name" => "Ops"})
    mate = user_fixture()
    {:ok, _} = Teams.add_member(scope, team, mate.email)
    {:ok, project} = Projects.create(scope, %{"name" => "Procedures"})

    {:ok, lv, _html} = live(conn, ~p"/projects?p=#{project.id}")
    lv |> form("#share-form", share: %{team_id: team.id}) |> render_change()
    assert has_element?(lv, "#project-#{project.id}", "shared")
    assert Projects.get!(scope, project.id).team_id == team.id

    {:ok, mate_lv, _html} = live(log_in_user(build_conn(), mate), ~p"/projects")
    assert has_element?(mate_lv, "#project-#{project.id}", user.email)
    assert has_element?(mate_lv, "#selected-project", "Owned by #{user.email}")
    refute has_element?(mate_lv, "#share-form")
  end
end
