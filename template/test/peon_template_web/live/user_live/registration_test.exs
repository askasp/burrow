# peon:accounts-only: Peon leaves this file out of apps made without accounts.
# peon:not-burrow: nor out of internal apps, where Burrow logs people in.
defmodule PeonTemplateWeb.UserLive.RegistrationTest do
  use PeonTemplateWeb.ConnCase

  import Phoenix.LiveViewTest
  import PeonTemplate.AccountsFixtures

  alias PeonTemplate.{Accounts, SiteAccess}

  describe "Registration page" do
    test "renders registration page", %{conn: conn} do
      {:ok, _lv, html} = live(conn, ~p"/users/register")

      assert html =~ "Register"
      assert html =~ "Log in"
    end

    test "redirects if already logged in", %{conn: conn} do
      result =
        conn
        |> log_in_user(user_fixture())
        |> live(~p"/users/register")
        |> follow_redirect(conn, ~p"/")

      assert {:ok, _conn} = result
    end

    test "renders errors for invalid data", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      result =
        lv
        |> element("#registration_form")
        |> render_change(user: %{"email" => "with spaces"})

      assert result =~ "Register"
      assert result =~ "must have the @ sign and no spaces"
    end
  end

  describe "register user" do
    test "creates account and logs the user in", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      email = unique_user_email()

      form =
        form(lv, "#registration_form", user: %{email: email, password: valid_user_password()})

      render_submit(form)
      conn = follow_trigger_action(form, conn)

      assert redirected_to(conn) == ~p"/"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) == "Account created successfully!"
    end

    test "the first account is the admin", %{conn: conn} do
      {:ok, lv, html} = live(conn, ~p"/users/register")
      assert html =~ "this account is the admin"

      email = unique_user_email()

      lv
      |> form("#registration_form", user: %{email: email, password: valid_user_password()})
      |> render_submit()

      assert Accounts.get_user_by_email(email).admin
    end
  end

  # The tests follow the switch, so they pass whichever way it is set.
  if SiteAccess.signups?() do
    describe "with sign-ups open" do
      test "anyone can register, but only the first account is the admin", %{conn: conn} do
        user_fixture()

        {:ok, lv, html} = live(conn, ~p"/users/register")
        refute html =~ "this account is the admin"

        email = unique_user_email()

        lv
        |> form("#registration_form", user: %{email: email, password: valid_user_password()})
        |> render_submit()

        refute Accounts.get_user_by_email(email).admin
      end

      test "renders errors for duplicated email", %{conn: conn} do
        {:ok, lv, _html} = live(conn, ~p"/users/register")

        user = user_fixture(%{email: "test@email.com"})

        result =
          lv
          |> form("#registration_form",
            user: %{"email" => user.email, "password" => valid_user_password()}
          )
          |> render_submit()

        assert result =~ "has already been taken"
      end
    end
  else
    describe "with sign-ups closed" do
      test "nobody else can register once the admin exists", %{conn: conn} do
        user_fixture()

        assert {:error, {:redirect, %{to: path, flash: flash}}} = live(conn, ~p"/users/register")
        assert path == ~p"/users/log-in"
        assert flash["error"] =~ "Sign-ups are closed"
      end

      test "a form opened before the admin registered is turned away", %{conn: conn} do
        {:ok, lv, _html} = live(conn, ~p"/users/register")

        user_fixture()
        email = unique_user_email()

        result =
          lv
          |> form("#registration_form",
            user: %{"email" => email, "password" => valid_user_password()}
          )
          |> render_submit()

        assert {:error, {:redirect, %{to: "/users/log-in"}}} = result
        refute Accounts.get_user_by_email(email)
      end
    end
  end

  describe "registration navigation" do
    test "redirects to login page when the Log in button is clicked", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      {:ok, _login_live, login_html} =
        lv
        |> element("main a", "Log in")
        |> render_click()
        |> follow_redirect(conn, ~p"/users/log-in")

      assert login_html =~ "Log in"
    end
  end
end
