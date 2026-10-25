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

      assert Template.variant("x.ex", text, true) == {:ok, "a\nb\nd\n"}
      assert Template.variant("x.ex", text, false) == {:ok, "a\nc\nd\n"}

      only = "# peon:accounts-only: note\ndefmodule X do\nend\n"
      assert Template.variant("x.ex", only, true) == {:ok, "defmodule X do\nend\n"}
      assert Template.variant("x.ex", only, false) == :skip
    end

    test "leave text that only mentions peon: alone" do
      text = "see peon:if-accounts in Peon.Template\n"
      assert Template.variant("x.md", text, false) == {:ok, text}
    end

    test "must be balanced" do
      assert_raise ArgumentError, ~r/x.ex/, fn ->
        Template.variant("x.ex", "# peon:if-accounts\na\n", false)
      end

      assert_raise ArgumentError, fn -> Template.variant("x.ex", "# peon:end\n", false) end

      assert_raise ArgumentError, fn ->
        Template.variant("x.ex", "# peon:if-accounts\n# peon:if-accounts\n", true)
      end
    end
  end
end
