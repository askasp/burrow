defmodule Burrow.ProjectsTest do
  use Burrow.DataCase

  import Burrow.AccountsFixtures

  alias Burrow.{Projects, Teams}
  alias Burrow.Projects.Project

  test "create assigns a unique slug and its own port range" do
    scope = user_scope_fixture()
    {:ok, a} = Projects.create(scope, %{"name" => "Sauna Booking"})
    {:ok, b} = Projects.create(scope, %{"name" => "Sauna booking!"})

    assert a.slug == "sauna_booking"
    assert b.slug == "sauna_booking_2"
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
    ports = &Burrow.Cell.ports(%Project{preview_ports: &1})
    assert ports.("5000-5009") == {5000..5007, %{"staging" => 5008, "prod" => 5009}}
    # 5060 and 5061 are blocked (SIP); the range end is fine, previews skip them.
    assert ports.("5060-5069") == {5060..5067, %{"staging" => 5068, "prod" => 5069}}
    assert ports.("6660-6669") == {6660..6662, %{"staging" => 6663, "prod" => 6664}}
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
    [first, last] = project.preview_ports |> String.split("-") |> Enum.map(&String.to_integer/1)
    assert Burrow.Cell.ports(project) == {first..last, %{}}
    assert Burrow.Secrets.value(project.id, "GITHUB_TOKEN") == nil

    # A token given with it is there before the first clone; an app has no use for one.
    {:ok, other} =
      Projects.create(scope, %{
        "name" => "Shop",
        "repo_url" => "https://github.com/a/shop.git",
        "github_token" => " ghp_x "
      })

    assert Burrow.Secrets.value(other.id, "GITHUB_TOKEN") == "ghp_x"
    {:ok, app} = Projects.create(scope, %{"name" => "Plain", "github_token" => "ghp_x"})
    assert Burrow.Secrets.value(app.id, "GITHUB_TOKEN") == nil
  end

  describe "the new app's login" do
    test "is user accounts unless picked" do
      {:ok, project} = Projects.create(user_scope_fixture(), %{"name" => "Default"})
      assert project.auth == "accounts"
      assert Project.basic_login(project) == nil

      {:ok, open} = Projects.create(user_scope_fixture(), %{"name" => "Open", "auth" => "open"})
      assert Projects.get(open.id).auth == "open"

      assert {:error, changeset} =
               Projects.create(user_scope_fixture(), %{"name" => "Odd", "auth" => "sso"})

      assert %{auth: [_]} = errors_on(changeset)
    end

    test "basic auth needs a username and password, which become the app's secrets and aren't stored" do
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

      # What the new app is set up with.
      {:ok, made} = attrs |> Projects.change() |> Ecto.Changeset.apply_action(:insert)

      assert made.auth == "basic"
      assert Project.basic_login(made) == {"ada", "correct horse"}

      refute inspect(made) =~ "correct horse"

      {:ok, project} = Projects.create(scope, attrs)
      assert project.auth == "basic"
      assert project.basic_password == nil
      stored = Projects.get(project.id)
      assert stored.auth == "basic" and stored.basic_password == nil
      # Restarts don't have it: it became the app's secrets.
      assert Project.basic_login(stored) == nil
    end

    test "with accounts, sign-ups are off unless picked, and only handed to the new app" do
      scope = user_scope_fixture()

      {:ok, closed} = Projects.create(scope, %{"name" => "Closed"})
      refute closed.signups

      {:ok, open} = Projects.create(scope, %{"name" => "Signups", "signups" => "true"})
      assert open.auth == "accounts" and open.signups

      # Other logins have no accounts to sign up for.
      {:ok, public} =
        Projects.create(scope, %{"name" => "Public", "auth" => "open", "signups" => "true"})

      refute public.signups
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
end
