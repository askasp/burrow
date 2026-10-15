defmodule Burrow.ProjectsTest do
  use Burrow.DataCase

  import Burrow.AccountsFixtures

  alias Burrow.{Projects, Teams}

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
end
