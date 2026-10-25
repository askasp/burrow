defmodule Burrow.TeamKeysTest do
  use Burrow.DataCase

  import Burrow.AccountsFixtures

  alias Burrow.{FakeOpenCode, OpenCode, TeamKeys, Teams}
  alias Burrow.TeamKeys.Key

  # Not a real key: what the fake opencode holds as one.
  @value "sk-test-not-a-real-key"

  setup do
    owner = user_scope_fixture()
    mate = user_scope_fixture()
    for s <- [owner, mate], do: start_supervised!({FakeOpenCode, s.user.id})

    {:ok, team} = Teams.create(owner, %{"name" => "Ops"})
    {:ok, _} = Teams.add_member(owner, team, mate.user.email)
    :ok = OpenCode.connect_key(owner.user.id, "openrouter", @value)
    TeamKeys.subscribe(mate.user.id)

    %{owner: owner, mate: mate, team: team}
  end

  defp person(team, owner) do
    scope = user_scope_fixture()
    start_supervised!({FakeOpenCode, scope.user.id})
    {:ok, _} = Teams.add_member(owner, team, scope.user.email)
    TeamKeys.subscribe(scope.user.id)
    scope
  end

  defp synced(%{user: %{id: id}}), do: assert_receive({:team_keys, ^id}, 2_000)

  defp team_logins(%{user: user}),
    do: Enum.filter(FakeOpenCode.credentials(user.id), &TeamKeys.team_login?(%{id: &1["id"]}))

  defp in_use(%{user: user}, provider),
    do:
      Enum.find(
        FakeOpenCode.credentials(user.id),
        &(&1["integrationID"] == provider and &1["active"])
      )

  test "sharing a key gives it to everyone in the team, never its value", ctx do
    %{owner: owner, mate: mate, team: team} = ctx

    assert :ok = TeamKeys.share(owner, "openrouter", team.id)
    synced(mate)

    assert [%{"value" => %{"type" => "key", "key" => @value}, "active" => true} = login] =
             team_logins(mate)

    assert login["label"] == "Team key from #{owner.user.email}"
    assert team_logins(owner) == []
    assert TeamKeys.shared(owner.user.id) == %{"openrouter" => [team.id]}

    assert %{"openrouter" => [%{shared_by: email, teams: ["Ops"]}] = keys} =
             TeamKeys.available(mate.user.id)

    assert email == owner.user.email
    refute inspect(keys) =~ @value
    refute inspect(Repo.one!(Key)) =~ @value
    assert TeamKeys.available(owner.user.id) == %{}
    assert TeamKeys.shared(mate.user.id) == %{}
  end

  test "one key goes to several teams; it stays while one of them has it", ctx do
    %{owner: owner, mate: mate, team: team} = ctx
    {:ok, infra} = Teams.create(owner, %{"name" => "Infra"})
    {:ok, _} = Teams.add_member(owner, infra, mate.user.email)
    other = person(infra, owner)

    :ok = TeamKeys.share(owner, "openrouter", team.id)
    synced(mate)
    :ok = TeamKeys.share(owner, "openrouter", infra.id)
    synced(mate)
    synced(other)

    assert %{"openrouter" => [%{teams: ["Infra", "Ops"]}]} = TeamKeys.available(mate.user.id)

    assert Enum.sort(TeamKeys.shared(owner.user.id)["openrouter"]) ==
             Enum.sort([team.id, infra.id])

    :ok = TeamKeys.unshare(owner, "openrouter", team.id)
    synced(mate)
    assert [_] = team_logins(mate)
    assert %{"openrouter" => [%{teams: ["Infra"]}]} = TeamKeys.available(mate.user.id)

    :ok = TeamKeys.unshare(owner, "openrouter", infra.id)
    synced(mate)
    synced(other)
    assert team_logins(mate) == []
    assert team_logins(other) == []
    assert TeamKeys.shared(owner.user.id) == %{}
    assert Repo.aggregate(Key, :count) == 0
  end

  test "only the one who connected an API key shares it", ctx do
    %{owner: owner, mate: mate, team: team} = ctx
    :ok = TeamKeys.share(owner, "openrouter", team.id)
    synced(mate)

    # The mate has the key only as the team's.
    assert {:error, :not_a_key} = TeamKeys.share(mate, "openrouter", team.id)
    :ok = TeamKeys.unshare(mate, "openrouter", team.id)
    assert TeamKeys.shared(owner.user.id) == %{"openrouter" => [team.id]}

    # Sign-ins aren't shared.
    FakeOpenCode.add(owner.user.id, "openai", %{
      "type" => "oauth",
      "methodID" => "chatgpt",
      "refresh" => "r",
      "access" => "a",
      "expires" => 0
    })

    assert {:error, :not_a_key} = TeamKeys.share(owner, "openai", team.id)
    assert {:error, :not_a_key} = TeamKeys.share(owner, "anthropic", team.id)

    {:ok, elsewhere} = Teams.create(user_scope_fixture(), %{"name" => "Elsewhere"})
    assert {:error, :not_member} = TeamKeys.share(owner, "openrouter", elsewhere.id)
  end

  test "a teammate's own login wins over the team's key", ctx do
    %{owner: owner, mate: mate, team: team} = ctx
    own = FakeOpenCode.add(mate.user.id, "openrouter", %{"type" => "key", "key" => "sk-test-own"})

    :ok = TeamKeys.share(owner, "openrouter", team.id)
    synced(mate)
    assert [%{"active" => false}] = team_logins(mate)
    assert in_use(mate, "openrouter")["id"] == own

    # opencode moved to the team's key, e.g. when another login went
    [%{"id" => team_login}] = team_logins(mate)
    FakeOpenCode.activate(mate.user.id, team_login)
    :ok = TeamKeys.sync(mate.user.id)
    assert in_use(mate, "openrouter")["id"] == own

    # Without a login of their own, the team's key is used.
    :ok = OpenCode.remove_login(mate.user.id, own)
    :ok = TeamKeys.sync(mate.user.id)
    assert in_use(mate, "openrouter")["id"] == team_login
  end

  test "replacing or removing the key ends its sharing", ctx do
    %{owner: owner, mate: mate, team: team} = ctx
    :ok = TeamKeys.share(owner, "openrouter", team.id)
    synced(mate)

    :ok = OpenCode.connect_key(owner.user.id, "openrouter", "sk-test-replacement")
    :ok = TeamKeys.sync(owner.user.id)
    synced(mate)
    assert team_logins(mate) == []
    assert TeamKeys.shared(owner.user.id) == %{}
    assert TeamKeys.available(mate.user.id) == %{}

    # The new key is shared anew, then removed.
    :ok = TeamKeys.share(owner, "openrouter", team.id)
    synced(mate)
    assert [%{"value" => %{"key" => "sk-test-replacement"}}] = team_logins(mate)

    for %{"id" => id, "integrationID" => "openrouter"} <- FakeOpenCode.credentials(owner.user.id),
        do: :ok = OpenCode.remove_login(owner.user.id, id)

    :ok = TeamKeys.sync(owner.user.id)
    synced(mate)
    assert team_logins(mate) == []
    assert Repo.aggregate(Key, :count) == 0
  end

  test "leaving the team ends access, for a teammate and for the key's owner", ctx do
    %{owner: owner, mate: mate, team: team} = ctx
    :ok = TeamKeys.share(owner, "openrouter", team.id)
    synced(mate)

    :ok = Teams.remove_member(owner, team, mate.user.id)
    synced(mate)
    assert team_logins(mate) == []
    assert TeamKeys.available(mate.user.id) == %{}

    # Someone who joins gets it.
    {:ok, _} = Teams.add_member(owner, team, mate.user.email)
    synced(mate)
    assert [_] = team_logins(mate)

    # The team's owner gets the key a member shares, until that member leaves.
    TeamKeys.subscribe(owner.user.id)
    :ok = OpenCode.connect_key(mate.user.id, "anthropic", "sk-test-mates")
    :ok = TeamKeys.share(mate, "anthropic", team.id)
    synced(owner)
    assert [%{"integrationID" => "anthropic"}] = team_logins(owner)

    :ok = Teams.remove_member(mate, team, mate.user.id)
    synced(owner)
    synced(mate)
    assert team_logins(owner) == []
    assert team_logins(mate) == []
    assert TeamKeys.shared(mate.user.id) == %{}
  end
end
