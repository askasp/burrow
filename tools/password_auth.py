#!/usr/bin/env python3
"""Turn Phoenix 1.8 phx.gen.auth (magic link first) into email + password login.

Usage: password_auth.py <app_dir> <Module> <otp_app>

- Registration asks for email + password, confirms the account immediately and
  logs the user in.
- The login page shows only the email + password form.
"""
import re
import sys
from pathlib import Path

app_dir, mod, otp = Path(sys.argv[1]), sys.argv[2], sys.argv[3]
web = f"{mod}Web"


def edit(rel, fn):
    path = app_dir / rel
    old = path.read_text()
    new = fn(old)
    if new == old:
        sys.exit(f"no change applied to {rel}")
    path.write_text(new)


def must_replace(text, old, new):
    if old not in text:
        sys.exit(f"pattern not found: {old[:80]!r}")
    return text.replace(old, new, 1)


# Accounts: register with password, confirmed at once. The generated
# email-only register_user/1 stays for the magic link backend and fixtures.
edit(f"lib/{otp}/accounts.ex", lambda s: must_replace(
    s,
    """  def register_user(attrs) do
    %User{}
    |> User.email_changeset(attrs)
    |> Repo.insert()
  end
""",
    """  def register_user(attrs) do
    %User{}
    |> User.email_changeset(attrs)
    |> Repo.insert()
  end

  @doc \"\"\"
  Registers a user with email and password. The account is confirmed at once.
  \"\"\"
  def register_user_with_password(attrs) do
    %User{}
    |> User.email_changeset(attrs)
    |> User.password_changeset(attrs)
    |> User.confirm_changeset()
    |> Repo.insert()
  end

  @doc \"\"\"
  Returns a changeset for the registration form (email and password).
  \"\"\"
  def change_user_registration(%User{} = user, attrs \\\\ %{}, opts \\\\ []) do
    user
    |> User.email_changeset(attrs, Keyword.put_new(opts, :validate_unique, false))
    |> User.password_changeset(attrs, hash_password: false)
  end
"""))

# Session controller: flash for freshly registered users.
edit(f"lib/{otp}_web/controllers/user_session_controller.ex", lambda s: must_replace(
    s,
    """  def create(conn, %{"_action" => "confirmed"} = params) do""",
    """  def create(conn, %{"_action" => "registered"} = params) do
    create(conn, params, "Account created successfully!")
  end

  def create(conn, %{"_action" => "confirmed"} = params) do"""))

# Registration LiveView.
registration = f'''defmodule {web}.UserLive.Registration do
  use {web}, :live_view

  alias {mod}.Accounts
  alias {mod}.Accounts.User

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={{@flash}} current_scope={{@current_scope}}>
      <div class="mx-auto max-w-sm">
        <div class="text-center">
          <.header>
            Register for an account
            <:subtitle>
              Already registered?
              <.link navigate={{~p"/users/log-in"}} class="font-semibold text-brand hover:underline">
                Log in
              </.link>
              to your account now.
            </:subtitle>
          </.header>
        </div>

        <.form
          for={{@form}}
          id="registration_form"
          phx-submit="save"
          phx-change="validate"
          phx-trigger-action={{@trigger_submit}}
          action={{~p"/users/log-in?_action=registered"}}
          method="post"
        >
          <.input
            field={{@form[:email]}}
            type="email"
            label="Email"
            autocomplete="username"
            spellcheck="false"
            required
            phx-mounted={{JS.focus()}}
          />
          <.input
            field={{@form[:password]}}
            type="password"
            label="Password"
            autocomplete="new-password"
            required
          />

          <.button phx-disable-with="Creating account..." class="btn btn-primary w-full">
            Create an account
          </.button>
        </.form>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, %{{assigns: %{{current_scope: %{{user: user}}}}}} = socket)
      when not is_nil(user) do
    {{:ok, redirect(socket, to: {web}.UserAuth.signed_in_path(socket))}}
  end

  def mount(_params, _session, socket) do
    changeset = Accounts.change_user_registration(%User{{}})

    {{:ok, socket |> assign(trigger_submit: false) |> assign_form(changeset)}}
  end

  @impl true
  def handle_event("save", %{{"user" => user_params}}, socket) do
    case Accounts.register_user_with_password(user_params) do
      {{:ok, user}} ->
        changeset = Accounts.change_user_registration(user, user_params)
        {{:noreply, socket |> assign(trigger_submit: true) |> assign_form(changeset)}}

      {{:error, %Ecto.Changeset{{}} = changeset}} ->
        {{:noreply, assign_form(socket, changeset)}}
    end
  end

  def handle_event("validate", %{{"user" => user_params}}, socket) do
    changeset = Accounts.change_user_registration(%User{{}}, user_params)
    {{:noreply, assign_form(socket, Map.put(changeset, :action, :validate))}}
  end

  defp assign_form(socket, %Ecto.Changeset{{}} = changeset) do
    assign(socket, form: to_form(changeset, as: "user"))
  end
end
'''
(app_dir / f"lib/{otp}_web/live/user_live/registration.ex").write_text(registration)


# Login LiveView: drop the magic link form and the local mailbox notice.
def login(s):
    s = re.sub(r'\n        <div :if=\{local_mail_adapter\?\(\)\}.*?\n        </div>\n', "\n", s, count=1, flags=re.S)
    s = re.sub(r'\n        <\.form\n          :let=\{f\}\n          for=\{@form\}\n          id="login_form_magic".*?</\.form>\n\n        <div class="divider">or</div>\n',
               "\n", s, count=1, flags=re.S)
    s = re.sub(r'\n  def handle_event\("submit_magic".*?\n  end\n', "\n", s, count=1, flags=re.S)
    s = re.sub(r'\n  defp local_mail_adapter\? do.*?\n  end\n', "\n", s, count=1, flags=re.S)
    s = s.replace("\n  alias %s.Accounts\n" % mod, "\n", 1)
    s = s.replace("""            required
          />
          <.input
            field={@form[:password]}""", """            required
            phx-mounted={JS.focus()}
          />
          <.input
            field={@form[:password]}""", 1)
    if "login_form_magic" in s or "submit_magic" in s:
        sys.exit("login.ex: magic link parts not fully removed")
    return s


edit(f"lib/{otp}_web/live/user_live/login.ex", login)


def registration_test(s):
    s = must_replace(s, '''    test "creates account but does not log in", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      email = unique_user_email()
      form = form(lv, "#registration_form", user: valid_user_attributes(email: email))

      {:ok, _lv, html} =
        render_submit(form)
        |> follow_redirect(conn, ~p"/users/log-in")

      assert html =~
               ~r/An email was sent to .*, please access it to confirm your account/
    end''', '''    test "creates account and logs the user in", %{conn: conn} do
      {:ok, lv, _html} = live(conn, ~p"/users/register")

      email = unique_user_email()

      form =
        form(lv, "#registration_form", user: %{email: email, password: valid_user_password()})

      render_submit(form)
      conn = follow_trigger_action(form, conn)

      assert redirected_to(conn) == ~p"/"
      assert Phoenix.Flash.get(conn.assigns.flash, :info) == "Account created successfully!"
    end''')
    return must_replace(s, '''          user: %{"email" => user.email}
        )''', '''          user: %{"email" => user.email, "password" => valid_user_password()}
        )''')


def login_test(s):
    s = must_replace(s, '''      assert html =~ "Log in with email"
    end
  end''', '''      assert html =~ "Log in and stay logged in"
    end
  end''')
    s = re.sub(r'\n  describe "user login - magic link" do.*?\n  end\n', "\n", s, count=1, flags=re.S)
    s = must_replace(s, '''      refute html =~ "Register"
      assert html =~ "Log in with email"
''', '''      refute html =~ "Register"
''')
    return must_replace(s, 'id="login_form_magic_email"', 'id="login_form_password_email"')


edit(f"test/{otp}_web/live/user_live/registration_test.exs", registration_test)
edit(f"test/{otp}_web/live/user_live/login_test.exs", login_test)
print("password auth applied")
