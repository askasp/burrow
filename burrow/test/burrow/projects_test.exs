defmodule Burrow.ProjectsTest do
  use Burrow.DataCase

  import Burrow.AccountsFixtures

  alias Burrow.{Projects, Teams}
  alias Burrow.Projects.Project

  test "create assigns a unique slug and its own ports" do
    scope = user_scope_fixture()
    {:ok, a} = Projects.create(scope, %{"name" => "Sauna Booking"})
    {:ok, b} = Projects.create(scope, %{"name" => "Sauna booking!"})

    assert a.slug == "sauna_booking"
    assert b.slug == "sauna_booking_2"
    assert a.port != b.port
    assert a.preview_ports != b.preview_ports
    assert {:error, %Ecto.Changeset{}} = Projects.create(scope, %{"name" => "1"})
  end

  test "the owner hands a shared project to a teammate" do
    owner = user_scope_fixture()
    mate = user_scope_fixture()
    outsider = user_scope_fixture()
    {:ok, team} = Teams.create(owner, %{"name" => "Crew"})
    {:ok, _} = Teams.add_member(owner, team, mate.user.email)
    {:ok, project} = Projects.create(owner, %{"name" => "Tower", "team_id" => team.id})

    assert {:error, :not_a_teammate} = Projects.hand_over(owner, project, outsider.user.id)
    assert {:error, :not_owner} = Projects.hand_over(mate, project, mate.user.id)

    assert {:ok, handed} = Projects.hand_over(owner, project, to_string(mate.user.id))
    assert handed.user_id == mate.user.id
    assert Projects.owner?(mate, handed)
    assert handed.team_id == team.id
  end

  test "staging and prod get ports a browser opens" do
    assert Burrow.Cell.split_ports("5000-5009") == {"5000-5007", 5008, 5009}
    # 5060 and 5061 are blocked (SIP); the range end is fine, previews skip them in Peon.
    assert Burrow.Cell.split_ports("5060-5069") == {"5060-5067", 5068, 5069}
    assert Burrow.Cell.split_ports("6660-6669") == {"6660-6662", 6663, 6664}
  end

  test "a project from a git repo has no envs, so its whole range is previews" do
    scope = user_scope_fixture()

    assert {:error, changeset} =
             Projects.create(scope, %{"name" => "Amino", "repo_url" => "git@github.com:a/b"})

    assert %{repo_url: [_]} = errors_on(changeset)

    {:ok, project} =
      Projects.create(scope, %{"name" => "Amino", "repo_url" => " https://github.com/a/b.git "})

    assert project.repo_url == "https://github.com/a/b.git"
    assert Project.repo?(project)
    refute Project.live_only?(project)
    assert Burrow.Cell.split_ports(project) == {project.preview_ports, "", ""}
  end

  describe "the new app's login" do
    test "is user accounts unless picked" do
      {:ok, project} = Projects.create(user_scope_fixture(), %{"name" => "Default"})
      assert project.auth == "accounts"
      assert Burrow.Cell.auth_env(project) == %{"PEON_AUTH" => "accounts"}

      {:ok, open} = Projects.create(user_scope_fixture(), %{"name" => "Open", "auth" => "open"})
      assert Projects.get(open.id).auth == "open"

      assert {:error, changeset} =
               Projects.create(user_scope_fixture(), %{"name" => "Odd", "auth" => "sso"})

      assert %{auth: [_]} = errors_on(changeset)
    end

    test "basic auth needs a username and password, which go to Peon and aren't stored" do
      scope = user_scope_fixture()

      assert {:error, changeset} =
               Projects.create(scope, %{"name" => "Gate", "auth" => "basic"})

      assert %{basic_username: [_], basic_password: [_]} = errors_on(changeset)

      assert {:error, changeset} =
               Projects.create(scope, %{
                 "name" => "Gate",
                 "auth" => "basic",
                 "basic_username" => "a:b",
                 "basic_password" => "short"
               })

      assert %{basic_username: [_], basic_password: [_]} = errors_on(changeset)

      attrs = %{
        "name" => "Gate",
        "auth" => "basic",
        "basic_username" => " ada ",
        "basic_password" => "correct horse"
      }

      # What the Peon is started with.
      {:ok, made} = attrs |> Projects.change() |> Ecto.Changeset.apply_action(:insert)

      assert Burrow.Cell.auth_env(made) == %{
               "PEON_AUTH" => "basic",
               "PEON_BASIC_AUTH_USERNAME" => "ada",
               "PEON_BASIC_AUTH_PASSWORD" => "correct horse"
             }

      refute inspect(made) =~ "correct horse"

      {:ok, project} = Projects.create(scope, attrs)
      assert project.auth == "basic"
      assert project.basic_password == nil
      stored = Projects.get(project.id)
      assert stored.auth == "basic" and stored.basic_password == nil
      # Restarts don't have it: Peon kept it as the app's secrets.
      assert Burrow.Cell.auth_env(stored) == %{"PEON_AUTH" => "basic"}
    end

    test "doesn't apply to a repo project" do
      {:ok, project} =
        Projects.create(user_scope_fixture(), %{
          "name" => "Repo",
          "repo_url" => "https://github.com/a/b",
          "auth" => "basic"
        })

      assert project.auth == "accounts"
    end
  end

  test "projects are only visible to their owner" do
    {:ok, project} = Projects.create(user_scope_fixture(), %{"name" => "Mine"})
    other = user_scope_fixture()

    assert Projects.list(other) == []
    assert_raise Ecto.NoResultsError, fn -> Projects.get!(other, project.id) end
  end

  test "a project shared with a team is visible to its members, and only the owner shares it" do
    owner = user_scope_fixture()
    mate = user_scope_fixture()
    {:ok, team} = Teams.create(owner, %{"name" => "Ops"})
    {:ok, _} = Teams.add_member(owner, team, mate.user.email)
    {:ok, project} = Projects.create(owner, %{"name" => "Procedures"})

    assert Projects.list(mate) == []
    assert {:error, :not_owner} = Projects.share(mate, project, team.id)

    {:ok, shared} = Projects.share(owner, project, to_string(team.id))
    assert shared.team.name == "Ops"
    assert [%{id: id}] = Projects.list(mate)
    assert id == project.id
    assert Projects.get!(mate, project.id).user.email == owner.user.email
    assert Projects.owned(mate) == []

    {:ok, _} = Projects.share(owner, project, "")
    assert Projects.list(mate) == []
  end

  test "projects can only be shared with your own teams" do
    owner = user_scope_fixture()
    {:ok, theirs} = Teams.create(user_scope_fixture(), %{"name" => "Theirs"})
    {:ok, project} = Projects.create(owner, %{"name" => "Mine"})

    assert {:error, :not_member} = Projects.share(owner, project, theirs.id)
    assert {:error, :not_member} = Projects.share(owner, project, "nope")

    assert {:error, %Ecto.Changeset{errors: [team_id: _]}} =
             Projects.create(owner, %{"name" => "Other", "team_id" => to_string(theirs.id)})
  end

  test "the Peon link carries a token Peon can verify with the shared secret" do
    {:ok, project} = Projects.create(user_scope_fixture(), %{"name" => "SSO"})
    url = Projects.peon_url(project, "a@b.no")
    [_, token] = String.split(url, "token=")

    assert {:ok, "a@b.no"} =
             Phoenix.Token.verify(Projects.secret(project, "sso"), "peon sso", token, max_age: 60)
  end

  test "workspaces open under Burrow's own site, at /w/<port>" do
    Application.put_env(:burrow, :port_url, "https://peon-{port}.example.com")
    on_exit(fn -> Application.delete_env(:burrow, :port_url) end)
    {:ok, project} = Projects.create(user_scope_fixture(), %{"name" => "Home"})

    assert Projects.peon_url(project, "a@b.no", nil, "dark") =~
             ~r"^#{BurrowWeb.Endpoint.url()}/w/#{project.port}/sso\?token=.+&theme=dark$"

    assert Burrow.Ports.peon_path(project.port) == "/w/#{project.port}"
    # Previews keep their own hosts.
    assert Burrow.Ports.url(project.port) == "https://peon-#{project.port}.example.com"
    assert Burrow.Ports.host(project.port) == "peon-#{project.port}.example.com"
  end

  test "BURROW_PEON_URL can give workspaces their port's own address instead" do
    Application.put_env(:burrow, :peon_url, "https://peon-{port}.example.com")
    on_exit(fn -> Application.delete_env(:burrow, :peon_url) end)
    {:ok, project} = Projects.create(user_scope_fixture(), %{"name" => "Own host"})

    assert Projects.peon_url(project, "a@b.no") =~
             "https://peon-#{project.port}.example.com/sso?token="

    assert Burrow.Ports.peon_path(project.port) == nil
  end
end
