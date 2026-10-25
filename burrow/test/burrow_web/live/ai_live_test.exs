defmodule BurrowWeb.AILiveTest do
  use BurrowWeb.ConnCase

  import Phoenix.LiveViewTest
  import Burrow.AccountsFixtures

  alias Burrow.{FakeOpenCode, OpenCode, TeamKeys, Teams}
  alias Burrow.Accounts.Scope

  # Not a real key: what the fake opencode holds as one.
  @value "sk-test-not-a-real-key"

  setup :register_and_log_in_user

  setup %{user: user} do
    mate = user_fixture()
    for u <- [user, mate], do: start_supervised!({FakeOpenCode, u.id})

    {:ok, team} = Teams.create(Scope.for_user(user), %{"name" => "Ops"})
    {:ok, _} = Teams.add_member(Scope.for_user(user), team, mate.email)
    TeamKeys.subscribe(mate.id)
    %{mate: mate, team: team}
  end

  test "shares an API key with a team, whose members see who shared it but not the key", ctx do
    %{conn: conn, user: user, mate: mate, team: team} = ctx
    :ok = OpenCode.connect_key(user.id, "openrouter", @value)

    {:ok, lv, _html} = live(conn, ~p"/ai")
    render_async(lv)
    assert has_element?(lv, "#provider-openrouter", "Your API key")
    refute has_element?(lv, "#share-openrouter-#{team.id}[checked]")

    lv |> element("#share-openrouter-#{team.id}") |> render_click()
    assert render(lv) =~ "Everyone in Ops can use this key now."
    assert has_element?(lv, "#share-openrouter-#{team.id}[checked]")
    mate_id = mate.id
    assert_receive {:team_keys, ^mate_id}, 2_000

    mate_conn = log_in_user(build_conn(), mate)
    {:ok, mate_lv, _html} = live(mate_conn, ~p"/ai")
    html = render_async(mate_lv)
    [%{id: key_id}] = TeamKeys.available(mate.id)["openrouter"]
    assert has_element?(mate_lv, "#team-key-#{key_id}", "Ops")
    assert has_element?(mate_lv, "#team-key-#{key_id}", "shared by #{user.email}")
    assert has_element?(mate_lv, "#team-key-#{key_id}", "Your Peons can use it.")
    refute has_element?(mate_lv, "#share-openrouter")
    refute html =~ @value

    # Unsharing takes it away, and the teammate's page follows.
    lv |> element("#share-openrouter-#{team.id}") |> render_click()
    assert render(lv) =~ "Ops no longer gets this key."
    assert_receive {:team_keys, ^mate_id}, 2_000
    render_async(mate_lv)
    refute has_element?(mate_lv, "#team-key-#{key_id}")
    assert TeamKeys.shared(user.id) == %{}
  end

  test "a teammate's own login wins over the team's key", ctx do
    %{conn: conn, user: user, mate: mate, team: team} = ctx
    :ok = OpenCode.connect_key(user.id, "openrouter", @value)
    :ok = TeamKeys.share(Scope.for_user(user), "openrouter", team.id)
    mate_id = mate.id
    assert_receive {:team_keys, ^mate_id}, 2_000
    :ok = OpenCode.connect_key(mate.id, "openrouter", "sk-test-own")

    {:ok, lv, _html} = live(log_in_user(conn, mate), ~p"/ai")
    render_async(lv)
    assert has_element?(lv, "#provider-openrouter", "Your API key")
    assert has_element?(lv, "#provider-openrouter", "Your own login wins.")
  end

  test "removing the key ends its sharing", ctx do
    %{conn: conn, user: user, mate: mate, team: team} = ctx
    :ok = OpenCode.connect_key(user.id, "openrouter", @value)
    :ok = TeamKeys.share(Scope.for_user(user), "openrouter", team.id)
    mate_id = mate.id
    assert_receive {:team_keys, ^mate_id}, 2_000

    {:ok, lv, _html} = live(conn, ~p"/ai")
    render_async(lv)
    lv |> element("#provider-openrouter button", "Remove") |> render_click()
    render_async(lv)
    assert_receive {:team_keys, ^mate_id}, 2_000
    refute has_element?(lv, "#provider-openrouter", "Your API key")
    assert TeamKeys.shared(user.id) == %{}
    assert TeamKeys.available(mate.id) == %{}
  end

  test "OpenCode Go is shared with its API key, not the Console sign-in", ctx do
    %{conn: conn, user: user, mate: mate, team: team} = ctx

    FakeOpenCode.add(user.id, "opencode", %{
      "type" => "oauth",
      "methodID" => "device",
      "refresh" => "r",
      "access" => "a",
      "expires" => 0
    })

    {:ok, lv, _html} = live(conn, ~p"/ai")
    render_async(lv)
    assert has_element?(lv, "#sign-in-hint-opencode", "connect it under OpenCode Go")
    refute has_element?(lv, "#share-opencode")
    assert {:error, :not_a_key} = TeamKeys.share(Scope.for_user(user), "opencode", team.id)

    lv
    |> form("#provider-opencode-go form", %{"provider" => "opencode-go", "key" => @value})
    |> render_submit()

    render_async(lv)
    lv |> element("#share-opencode-go-#{team.id}") |> render_click()
    mate_id = mate.id
    assert_receive {:team_keys, ^mate_id}, 2_000

    assert [%{"integrationID" => "opencode-go", "value" => %{"type" => "key"}, "active" => true}] =
             Enum.filter(
               FakeOpenCode.credentials(mate.id),
               &TeamKeys.team_login?(%{id: &1["id"]})
             )

    {:ok, mate_lv, _html} = live(log_in_user(build_conn(), mate), ~p"/ai")
    html = render_async(mate_lv)
    assert has_element?(mate_lv, "#provider-opencode-go [id^='team-key-']", user.email)
    refute html =~ @value
  end

  test "sign-ins aren't shared", %{conn: conn, user: user} do
    FakeOpenCode.add(user.id, "openai", %{
      "type" => "oauth",
      "methodID" => "chatgpt",
      "refresh" => "r",
      "access" => "a",
      "expires" => 0
    })

    {:ok, lv, _html} = live(conn, ~p"/ai")
    render_async(lv)
    assert has_element?(lv, "#provider-openai", "Your sign-in")
    assert has_element?(lv, "#sign-in-hint-openai", "Sign-ins can't be shared with a team")
    refute has_element?(lv, "#sign-in-hint-openai", "OpenCode Go")
    refute has_element?(lv, "#share-openai")
  end
end
