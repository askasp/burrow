# peon:accounts-only: Peon leaves this file out of apps made without accounts.
defmodule PeonTemplateWeb.DataLiveTest do
  use PeonTemplateWeb.ConnCase

  import Ecto.Query
  import Phoenix.LiveViewTest
  import PeonTemplate.AccountsFixtures

  alias PeonTemplate.{Accounts, Repo}
  alias PeonTemplate.Accounts.User

  describe "the data pages" do
    setup :register_and_log_in_user

    test "list the app's tables and link to them from the header", %{conn: conn} do
      {:ok, lv, html} = live(conn, ~p"/users/admin/data")

      assert html =~ "Accounts.User"
      assert has_element?(lv, "#schema-users", "1")
      assert has_element?(lv, "#schema-users_tokens")
      assert conn |> get(~p"/") |> html_response(200) =~ ~s(href="/users/admin/data")

      {:ok, _lv, html} =
        lv
        |> element("#schema-users td", "Accounts.User")
        |> render_click()
        |> follow_redirect(conn)

      assert html =~ "1 row in"
    end

    test "show a table's rows without the redacted fields", %{conn: conn, user: admin} do
      other = user_fixture() |> set_password()
      {:ok, lv, html} = live(conn, ~p"/users/admin/data/Accounts.User")

      assert has_element?(lv, "#row-#{admin.id}", admin.email)
      assert has_element?(lv, "#row-#{other.id}", other.email)
      refute html =~ "hashed_password"
      refute html =~ other.hashed_password
    end

    test "search and page through the rows", %{conn: conn, user: admin} do
      other = user_fixture(email: "Sauna.Fan@example.com")
      {:ok, lv, _html} = live(conn, ~p"/users/admin/data/Accounts.User")

      lv |> form("#search", q: "sauna.fan") |> render_change()
      assert_patch(lv, ~p"/users/admin/data/Accounts.User?q=sauna.fan")
      assert has_element?(lv, "#row-#{other.id}")
      refute has_element?(lv, "#row-#{admin.id}")

      {:ok, _lv, html} = live(conn, ~p"/users/admin/data/Accounts.User?q=nobody")
      assert html =~ "No rows."
    end

    test "show a row and the rows it links to", %{conn: conn, user: admin} do
      Accounts.generate_user_session_token(admin)
      [token | _] = Repo.all_by(Accounts.UserToken, user_id: admin.id)

      {:ok, lv, html} = live(conn, ~p"/users/admin/data/Accounts.UserToken/#{token.id}")

      assert html =~ "session"
      # The token is redacted, not shown as "(32 bytes)".
      refute html =~ "bytes)"

      {:ok, _lv, html} =
        lv |> element("#link-user a") |> render_click() |> follow_redirect(conn)

      assert html =~ admin.email
    end

    test "filter by a field", %{conn: conn, user: admin} do
      Accounts.generate_user_session_token(admin)
      Accounts.generate_user_session_token(user_fixture())

      {:ok, lv, html} =
        live(conn, ~p"/users/admin/data/Accounts.UserToken?#{[filter: %{user_id: admin.id}]}")

      mine = Repo.aggregate(from(t in Accounts.UserToken, where: t.user_id == ^admin.id), :count)
      all = Repo.aggregate(Accounts.UserToken, :count)
      assert mine < all

      assert has_element?(lv, "#filter-user_id")
      assert html =~ "#{mine} rows in"

      lv |> element("#filter-user_id") |> render_click()
      assert_patch(lv, ~p"/users/admin/data/Accounts.UserToken")
      assert render(lv) =~ "#{all} rows in"
    end

    test "edit a row", %{conn: conn} do
      other = user_fixture()
      {:ok, lv, _html} = live(conn, ~p"/users/admin/data/Accounts.User/#{other.id}/edit")

      {:ok, _lv, html} =
        lv
        |> form("#row_form", row: %{email: "renamed@example.com", admin: "true"})
        |> render_submit()
        |> follow_redirect(conn, ~p"/users/admin/data/Accounts.User/#{other.id}")

      assert html =~ "Saved."
      assert %User{email: "renamed@example.com", admin: true} = Repo.get!(User, other.id)
    end

    test "add a row, and say what is wrong with it", %{conn: conn, user: admin} do
      {:ok, lv, _html} = live(conn, ~p"/users/admin/data/Accounts.User")

      {:ok, lv, _html} =
        lv |> element("a", "New row") |> render_click() |> follow_redirect(conn)

      assert lv |> form("#row_form", row: %{email: admin.email}) |> render_submit() =~
               "has already been taken"

      assert lv |> form("#row_form", row: %{email: ""}) |> render_submit() =~
               "The database refused it"

      {:ok, _lv, html} =
        lv
        |> form("#row_form", row: %{email: "added@example.com"})
        |> render_submit()
        |> follow_redirect(conn)

      assert html =~ "added@example.com"
      assert Accounts.get_user_by_email("added@example.com")
    end

    test "delete a row", %{conn: conn} do
      # Not one of the admin's own: deleting that logs them out.
      other = user_fixture()
      Accounts.generate_user_session_token(other)
      [token | _] = Repo.all_by(Accounts.UserToken, user_id: other.id)
      {:ok, lv, _html} = live(conn, ~p"/users/admin/data/Accounts.UserToken/#{token.id}")

      {:ok, _lv, html} =
        lv
        |> element("#delete")
        |> render_click()
        |> follow_redirect(conn, ~p"/users/admin/data/Accounts.UserToken")

      assert html =~ "Deleted Accounts.UserToken #{token.id}."
      refute Repo.get(Accounts.UserToken, token.id)
    end

    test "delete an account with its sessions, but not your own", %{conn: conn, user: admin} do
      other = user_fixture()
      other_token = Accounts.generate_user_session_token(other)

      {:ok, lv, _html} = live(conn, ~p"/users/admin/data/Accounts.User/#{admin.id}")
      refute has_element?(lv, "#delete")
      assert render_click(lv, "delete", %{}) =~ "You can&#39;t delete your own account."
      assert Repo.get(User, admin.id)

      {:ok, lv, _html} = live(conn, ~p"/users/admin/data/Accounts.User/#{other.id}")
      lv |> element("#delete") |> render_click()
      assert_redirect(lv, ~p"/users/admin/data/Accounts.User")

      refute Repo.get(User, other.id)
      refute Accounts.get_user_by_session_token(other_token)
    end

    test "send unknown tables and rows back to the list", %{conn: conn} do
      assert {:error, {:live_redirect, %{to: "/users/admin/data", flash: %{"error" => msg}}}} =
               live(conn, ~p"/users/admin/data/Elixir.File")

      assert msg =~ "no Elixir.File"

      assert {:error, {:live_redirect, %{to: "/users/admin/data"}}} =
               live(conn, ~p"/users/admin/data/Accounts.User/0")

      assert {:error, {:live_redirect, %{to: "/users/admin/data"}}} =
               live(conn, ~p"/users/admin/data/Accounts.User/0/edit")
    end
  end

  test "are only for admins", %{conn: conn} do
    _admin = user_fixture()
    conn = log_in_user(conn, user_fixture())

    assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/users/admin/data")

    assert {:error, {:redirect, %{to: "/"}}} =
             live(conn, ~p"/users/admin/data/Accounts.User/1/edit")

    refute conn |> get(~p"/") |> html_response(200) =~ "/users/admin/data"
  end
end
