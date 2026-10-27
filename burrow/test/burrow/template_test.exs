defmodule Burrow.TemplateTest do
  use ExUnit.Case, async: true

  alias Burrow.Template

  @template Path.expand("../../../template", __DIR__)

  defp files(auth, opts \\ []) do
    {tree, blobs} = Template.instantiate(@template, "sauna", auth, opts)
    Map.new(tree, fn {path, hash} -> {path, Map.fetch!(blobs, hash)} end)
  end

  defp grep(files, pattern), do: for({path, text} <- files, text =~ pattern, do: path)

  test "user accounts: the template as it is, renamed, without its markers" do
    files = files("accounts")

    assert files["lib/sauna/accounts.ex"] =~ "defmodule Sauna.Accounts do"
    assert files["lib/sauna_web/user_auth.ex"]
    assert files["lib/sauna/site_access.ex"] =~ "def mode, do: :login"
    assert files["lib/sauna_web/router.ex"] =~ "plug :fetch_current_scope_for_user"
    assert files["lib/sauna_web/components/layouts/root.html.heex"] =~ ~s("/users/log-in")
    assert files["mix.exs"] =~ "bcrypt_elixir"
    assert files["AGENTS.md"] =~ "phx.gen.auth, email + password"
    refute files["AGENTS.md"] =~ "There are no user accounts"
    assert grep(files, ~r/peon:(accounts-only|if-accounts|unless-accounts|end)/) == []
    assert grep(files, ~r/PeonTemplate|peon_template/) == []
  end

  test "user accounts: sign-ups are closed unless picked; the first account is the admin" do
    closed = files("accounts")
    assert closed["lib/sauna/site_access.ex"] =~ "def signups?, do: false"
    assert closed["lib/sauna/accounts.ex"] =~ "def registration_open?"
    assert closed["lib/sauna_web/live/user_live/admin.ex"] =~ "defmodule SaunaWeb.UserLive.Admin"
    assert closed["lib/sauna_web/router.ex"] =~ ~s(live "/users/admin")
    assert closed["lib/sauna/backoffice.ex"] =~ "defmodule Sauna.Backoffice"
    assert closed["lib/sauna_web/router.ex"] =~ ~s(live "/users/admin/data/:schema")

    open = files("accounts", signups: true)
    assert open["lib/sauna/site_access.ex"] =~ "def signups?, do: true"
    refute open["lib/sauna/site_access.ex"] =~ "def signups?, do: false"

    assert Map.delete(open, "lib/sauna/site_access.ex") ==
             Map.delete(closed, "lib/sauna/site_access.ex")

    # Without accounts there is nothing to sign up for.
    refute files("open", signups: true)["lib/sauna/site_access.ex"] =~ "signups?"
  end

  for {auth, mode} <- [{"basic", ":basic_auth"}, {"open", ":public"}] do
    test "#{auth}: no accounts code at all, and SiteAccess mode #{mode}" do
      files = files(unquote(auth))

      assert files["lib/sauna/site_access.ex"] =~ "def mode, do: #{unquote(mode)}"
      refute files["lib/sauna/accounts.ex"]
      refute files["lib/sauna/backoffice.ex"]
      refute Enum.any?(Map.keys(files), &(&1 =~ "data_live"))
      refute Enum.any?(Map.keys(files), &(&1 =~ ~r/accounts|user_|users_auth/))

      # Bootstrap unlocks the deps it no longer uses (mix deps.unlock --unused).
      assert grep(files, ~r/UserAuth|AccountsFixtures|bcrypt|current_scope_for_user/) ==
               ["mix.lock"]

      assert grep(files, ~r"/users/") == []
      assert grep(files, ~r/:login\b/) == []
      assert grep(files, ~r/peon:(accounts-only|if-accounts|unless-accounts|end)/) == []

      assert files["AGENTS.md"] =~ "There are no user accounts"
      assert files["AGENTS.md"] =~ "`:basic_auth`"
      refute files["AGENTS.md"] =~ "phoenix-gen-auth"
      assert files["lib/sauna_web/router.ex"] =~ "live_session :app"
      assert files["lib/sauna_web/site_access.ex"] =~ "def check_site_password(conn, :basic_auth)"
      assert files["test/sauna_web/site_access_test.exs"] =~ "basic auth"
      # Still has what phx.new makes without auth.
      assert files["lib/sauna/mailer.ex"]
      assert files["priv/repo/migrations/.formatter.exs"]
    end
  end

  test "burrow: an internal app, with accounts Burrow logs people in to, no password pages" do
    files = files("burrow")

    assert files["lib/sauna/site_access.ex"] =~ "def mode, do: :burrow"
    assert files["lib/sauna/accounts.ex"] =~ "def burrow_user!(email, admin?)"
    assert files["lib/sauna_web/controllers/burrow_login_controller.ex"]
    assert files["test/sauna_web/controllers/burrow_login_controller_test.exs"]
    assert files["lib/sauna_web/router.ex"] =~ ~s(get "/burrow/login")
    assert files["lib/sauna_web/user_auth.ex"] =~ "def log_in(:burrow, path)"
    assert files["lib/sauna_web/router.ex"] =~ ~s(live "/users/admin/data")
    refute Enum.any?(Map.keys(files), &(&1 =~ ~r/user_live|user_session_controller/))

    for path <- ~w(lib/sauna_web/router.ex lib/sauna_web/components/layouts/root.html.heex),
        do: refute(files[path] =~ ~r"/users/(log-in|register|settings|log-out)")

    refute files["lib/sauna_web/user_auth.ex"] =~ "def log_in(_mode"
    assert files["AGENTS.md"] =~ "This is an internal app"
    refute files["AGENTS.md"] =~ "email + password"
    assert grep(files, ~r/peon:[a-z]/) == []

    # The other apps get none of it.
    for auth <- ~w(accounts basic open) do
      assert grep(files(auth), ~r/burrow_user|BurrowLogin|:burrow\b|internal app/) == []
    end
  end

  test "an unknown login is refused" do
    assert_raise FunctionClauseError, fn -> Template.instantiate(@template, "sauna", "sso") end
  end

  describe "markers" do
    test "keep or drop lines and files" do
      text = """
      a
        # peon:if-accounts
      b
        # peon:end
      <%!-- peon:unless-accounts --%>
      c
      <!-- peon:end -->
      d
      """

      assert Template.variant("x.ex", text, "accounts") == {:ok, "a\nb\nd\n"}
      assert Template.variant("x.ex", text, "open") == {:ok, "a\nc\nd\n"}

      only = "# peon:accounts-only: note\ndefmodule X do\nend\n"
      assert Template.variant("x.ex", only, "accounts") == {:ok, "defmodule X do\nend\n"}
      assert Template.variant("x.ex", only, "burrow") == {:ok, "defmodule X do\nend\n"}
      assert Template.variant("x.ex", only, "open") == :skip
    end

    test "burrow blocks nest in accounts blocks; burrow files" do
      text = """
      # peon:if-accounts
      a
      # peon:unless-burrow
      b
      # peon:end
      # peon:end
      # peon:if-burrow
      c
      # peon:end
      """

      assert Template.variant("x.ex", text, "accounts") == {:ok, "a\nb\n"}
      assert Template.variant("x.ex", text, "burrow") == {:ok, "a\nc\n"}
      assert Template.variant("x.ex", text, "open") == {:ok, ""}

      only = "# peon:burrow-only\nx\n"
      assert Template.variant("x.ex", only, "burrow") == {:ok, "x\n"}
      assert Template.variant("x.ex", only, "accounts") == :skip

      both = "# peon:accounts-only\n# peon:not-burrow\nx\n"
      assert Template.variant("x.ex", both, "accounts") == {:ok, "x\n"}
      assert Template.variant("x.ex", both, "burrow") == :skip
      assert Template.variant("x.ex", both, "basic") == :skip
    end

    test "leave text that only mentions peon: alone" do
      text = "see peon:if-accounts in Peon.Template\n"
      assert Template.variant("x.md", text, "open") == {:ok, text}
    end

    test "must be balanced" do
      assert_raise ArgumentError, ~r/x.ex/, fn ->
        Template.variant("x.ex", "# peon:if-accounts\na\n", "open")
      end

      assert_raise ArgumentError, fn -> Template.variant("x.ex", "# peon:end\n", "open") end

      assert_raise ArgumentError, fn ->
        Template.variant("x.ex", "# peon:if-accounts\n# peon:if-accounts\n", "accounts")
      end

      assert_raise ArgumentError, ~r/unexpected peon:burrow-only/, fn ->
        Template.variant("x.ex", "# peon:if-accounts\n# peon:burrow-only\n# peon:end\n", "burrow")
      end
    end
  end
end
