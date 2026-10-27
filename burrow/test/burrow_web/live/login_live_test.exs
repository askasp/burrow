defmodule BurrowWeb.LoginLiveTest do
  use BurrowWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Burrow.Accounts

  setup :register_and_log_in_user

  test "an admin makes a login whose password works, once", %{conn: conn, user: user} do
    user |> Ecto.Changeset.change(admin: true) |> Burrow.Repo.update!()
    {:ok, lv, html} = live(conn, ~p"/logins")
    assert html =~ "Logins"

    lv |> form("#login-form", login: %{email: " friend@example.com "}) |> render_submit()
    message = lv |> element("#new-login-message") |> render()
    [_, password] = Regex.run(~r/Password: (\w+)/, message)

    assert message =~ "/users/log-in"

    assert %{email: "friend@example.com"} =
             friend = Accounts.get_user_by_email("friend@example.com")

    assert friend.confirmed_at
    assert Accounts.get_user_by_email_and_password("friend@example.com", password)
    assert has_element?(lv, "#user-#{friend.id}", "friend@example.com")

    lv |> form("#login-form", login: %{email: "friend@example.com"}) |> render_submit()
    assert render(lv) =~ "has already been taken"
    refute has_element?(lv, "#new-login")
  end

  test "an admin deletes someone else's login, not their own", %{conn: conn, user: user} do
    user |> Ecto.Changeset.change(admin: true) |> Burrow.Repo.update!()
    other = Burrow.AccountsFixtures.user_fixture()
    {:ok, lv, _html} = live(conn, ~p"/logins")

    refute has_element?(lv, "#delete-user-#{user.id}")
    lv |> element("#delete-user-#{other.id}") |> render_click()

    refute has_element?(lv, "#user-#{other.id}")
    refute Accounts.get_user_by_email(other.email)
  end

  test "someone who isn't an admin can't open it or make logins", %{conn: conn, user: user} do
    assert {:error, {:live_redirect, %{to: "/projects"}}} = live(conn, ~p"/logins")
    assert {:error, :not_admin} = Accounts.create_login(user, "friend@example.com")
    refute Accounts.get_user_by_email("friend@example.com")
  end
end
