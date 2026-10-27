# peon:accounts-only: Peon leaves this file out of apps made without accounts.
# peon:not-burrow: nor out of internal apps, where Burrow logs people in.
defmodule PeonTemplateWeb.UserLive.AdminTest do
  use PeonTemplateWeb.ConnCase

  alias PeonTemplate.Accounts
  import Phoenix.LiveViewTest
  import PeonTemplate.AccountsFixtures

  describe "Users page" do
    setup :register_and_log_in_user

    test "lists the accounts and links to it from the header", %{conn: conn, user: admin} do
      other = user_fixture()

      {:ok, _lv, html} = live(conn, ~p"/users/admin")

      assert html =~ admin.email
      assert html =~ other.email
      assert html =~ "Admin"

      assert conn |> get(~p"/users/admin") |> html_response(200) =~ ~s(href="/users/admin")
    end

    test "adds an account that can log in", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/admin")
      email = unique_user_email()

      html =
        lv
        |> form("#add_user_form", user: %{email: email, password: valid_user_password()})
        |> render_submit()

      assert html =~ "Added #{email}."
      assert has_element?(lv, "#users", email)
      assert Accounts.get_user_by_email_and_password(email, valid_user_password())
    end

    test "shows what is wrong with a new account", %{conn: conn, user: admin} do
      {:ok, lv, _html} = live(conn, ~p"/users/admin")

      assert lv
             |> form("#add_user_form", user: %{email: "with spaces", password: "short"})
             |> render_change() =~ "must have the @ sign and no spaces"

      assert lv
             |> form("#add_user_form",
               user: %{email: admin.email, password: valid_user_password()}
             )
             |> render_submit() =~ "has already been taken"
    end

    test "removes another account, but not your own", %{conn: conn, user: admin} do
      other = user_fixture()
      {:ok, lv, _html} = live(conn, ~p"/users/admin")

      refute has_element?(lv, "#user-#{admin.id} a", "Remove")

      assert lv |> element("#user-#{other.id} a", "Remove") |> render_click() =~
               "Removed #{other.email}."

      refute Accounts.get_user_by_email(other.email)
      refute has_element?(lv, "#user-#{other.id}")
    end
  end

  test "is only for admins", %{conn: conn} do
    _admin = user_fixture()
    user = user_fixture()

    assert {:error, {:redirect, %{to: "/", flash: flash}}} =
             conn |> log_in_user(user) |> live(~p"/users/admin")

    assert flash["error"] == "Only an admin can open that page."
    refute conn |> log_in_user(user) |> get(~p"/") |> html_response(200) =~ "/users/admin"
  end

  test "needs a login", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/users/log-in"}}} = live(conn, ~p"/users/admin")
  end
end
