defmodule Burrow.TeamsTest do
  use Burrow.DataCase

  import Burrow.AccountsFixtures

  alias Burrow.{Projects, Teams}

  setup do
    owner = user_scope_fixture()
    {:ok, team} = Teams.create(owner, %{"name" => "Ops"})
    %{owner: owner, team: team}
  end

  test "the creator owns the team", %{owner: owner, team: team} do
    assert Teams.owner?(owner, team)
    assert [%{name: "Ops"}] = Teams.list(owner)
    assert [%{role: "owner"}] = Teams.members(team)
    assert {:error, %Ecto.Changeset{}} = Teams.create(owner, %{"name" => " "})
  end

  test "owners add registered users by email", %{owner: owner, team: team} do
    mate = user_scope_fixture()

    assert {:ok, _} = Teams.add_member(owner, team, " #{mate.user.email} ")
    assert {:error, :already_member} = Teams.add_member(owner, team, mate.user.email)
    assert {:error, :no_user} = Teams.add_member(owner, team, "nobody@example.com")
    assert {:error, :not_owner} = Teams.add_member(mate, team, user_fixture().email)
    assert [%{name: "Ops"}] = Teams.list(mate)
    refute Teams.owner?(mate, team)
  end

  test "only owners remove others, anyone can leave, the last owner stays", ctx do
    %{owner: owner, team: team} = ctx
    a = user_scope_fixture()
    b = user_scope_fixture()
    {:ok, _} = Teams.add_member(owner, team, a.user.email)
    {:ok, _} = Teams.add_member(owner, team, b.user.email)

    assert {:error, :not_owner} = Teams.remove_member(a, team, b.user.id)
    assert :ok = Teams.remove_member(a, team, a.user.id)
    assert :ok = Teams.remove_member(owner, team, b.user.id)
    assert {:error, :last_owner} = Teams.remove_member(owner, team, owner.user.id)
    assert Teams.list(a) == []
  end

  test "people outside a team can't see it", %{team: team} do
    assert_raise Ecto.NoResultsError, fn -> Teams.get!(user_scope_fixture(), team.id) end
  end

  test "leaving a team takes your projects out of it", %{owner: owner, team: team} do
    mate = user_scope_fixture()
    {:ok, _} = Teams.add_member(owner, team, mate.user.email)
    {:ok, project} = Projects.create(mate, %{"name" => "Shared", "team_id" => to_string(team.id)})

    assert [_] = Projects.list(owner)
    :ok = Teams.remove_member(mate, team, mate.user.id)
    assert Projects.list(owner) == []
    assert [%{id: id, team_id: nil}] = Projects.list(mate)
    assert id == project.id
  end
end
