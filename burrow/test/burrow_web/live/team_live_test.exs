defmodule BurrowWeb.TeamLiveTest do
  use BurrowWeb.ConnCase

  # The AI login check has no opencode to talk to in tests.
  @moduletag :capture_log

  import Phoenix.LiveViewTest
  import Burrow.AccountsFixtures

  alias Burrow.{Projects, Teams}

  setup :register_and_log_in_user

  test "creates a team, adds a teammate, and lists projects shared with it", %{
    conn: conn,
    user: user
  } do
    mate = user_fixture()
    {:ok, lv, _html} = live(conn, ~p"/teams")

    lv |> form("#team_form", team: %{name: "Ops"}) |> render_submit()
    [team] = Teams.list(Burrow.Accounts.Scope.for_user(user))
    assert_patch(lv, ~p"/teams?t=#{team.id}")
    assert has_element?(lv, "#selected-team h2", "Ops")

    lv |> form("#member-form", member: %{email: mate.email}) |> render_submit()
    assert has_element?(lv, "#member-#{mate.id}", mate.email)

    lv |> form("#member-form", member: %{email: "nobody@example.com"}) |> render_submit()
    assert render(lv) =~ "No one has registered as nobody@example.com"

    {:ok, _} =
      Projects.create(Burrow.Accounts.Scope.for_user(mate), %{
        "name" => "Procedures",
        "team_id" => to_string(team.id)
      })

    assert has_element?(lv, "#shared-projects", "Procedures")
  end

  test "members see the team but can't add people", %{conn: conn, user: user} do
    {:ok, team} = Teams.create(user_scope_fixture(), %{"name" => "Theirs"})
    owner = hd(Teams.members(team)).user
    {:ok, _} = Teams.add_member(Burrow.Accounts.Scope.for_user(owner), team, user.email)

    {:ok, lv, _html} = live(conn, ~p"/teams")
    assert has_element?(lv, "#selected-team h2", "Theirs")
    refute has_element?(lv, "#member-form")

    lv |> element("#member-#{user.id} button", "Leave") |> render_click()
    assert_patch(lv, ~p"/teams")
    refute has_element?(lv, "#selected-team")
  end
end
