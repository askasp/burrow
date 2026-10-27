defmodule Burrow.TeamKeys do
  @moduledoc """
  API keys shared with teams. Whoever connected an API key on the AI page
  can share it with any of the teams they are in, and unshare it; nobody
  else can. Everyone in those teams then has the key among their own
  opencode logins (`Burrow.OpenCode`), so their Peons can use it, but they
  never see its value. Their own login for the same provider wins.

  Sign-ins (OAuth) are not shared: opencode stores a new refresh token each
  time it refreshes one, so copies refreshing on their own could log each
  other out, and the token is the owner's whole account (an OpenCode Console
  sign-in carries its organization, MCP servers and web search). OpenCode Go
  is shared with the API key the OpenCode Console gives for it instead.

  Burrow keeps a key's value only while it is shared, and writes it into
  each teammate's opencode as a login of its own (`team_login?/1`). Agents
  use their user's opencode data directory, so a running one picks a shared
  key up, or loses it, at once, as it does a login the user connects.

  Sharing ends when the owner unshares the key, removes or replaces it (the
  key is no longer the login they use for its provider), or leaves the
  team; for a teammate, when they leave the team or are removed. `sync/1`
  brings someone's opencode up to date; after a change, everyone it
  concerns is synced in the background and gets `{:team_keys, user_id}` on
  their `"team_keys:<user id>"` topic.
  """

  import Ecto.Query

  require Logger

  alias Burrow.{OpenCode, Repo, Teams}
  alias Burrow.Accounts.Scope
  alias Burrow.TeamKeys.{Key, Share}
  alias Burrow.Teams.Member

  # The id of a shared key's login in a teammate's opencode: "cred_team_<key id>"
  @prefix "cred_team_"

  def subscribe(user_id), do: Phoenix.PubSub.subscribe(Burrow.PubSub, "team_keys:#{user_id}")

  @doc "Whether an opencode login (`Burrow.OpenCode.logins/1`) is a key a team shares."
  def team_login?(%{id: id}), do: String.starts_with?(id, @prefix)

  @doc "The teams the user shares their keys with: `%{provider => [team_id]}`."
  def shared(user_id) do
    Repo.all(
      from k in Key,
        join: s in assoc(k, :shares),
        where: k.user_id == ^user_id,
        select: {k.provider, s.team_id}
    )
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
  end

  @doc """
  The keys others share with the user's teams, without their values:
  `%{provider => [%{id, shared_by, teams}]}`, `shared_by` the owner's email
  and `teams` the names of the user's teams the key is shared with.
  """
  def available(user_id) do
    Repo.all(
      from k in Key,
        join: s in assoc(k, :shares),
        join: t in assoc(s, :team),
        join: m in Member,
        on: m.team_id == t.id and m.user_id == ^user_id,
        join: u in assoc(k, :user),
        where: k.user_id != ^user_id,
        order_by: [asc: k.id, asc: t.name],
        select: {k.id, k.provider, u.email, t.name}
    )
    |> Enum.chunk_by(&elem(&1, 0))
    |> Enum.map(fn [{id, provider, email, _} | _] = rows ->
      %{id: id, provider: provider, shared_by: email, teams: Enum.map(rows, &elem(&1, 3))}
    end)
    |> Enum.group_by(& &1.provider)
  end

  @doc """
  Shares the API key the user uses for `provider` with one of their teams.
  `{:error, :not_a_key}` when that login is a sign-in, a team's key, or
  there is none.
  """
  def share(%Scope{user: user}, provider, team_id) do
    with true <- Teams.member_id?(team_id, user.id) || {:error, :not_member},
         {:ok, key} <- own_key(user.id, provider) do
      Repo.insert!(%Share{team_key_id: key.id, team_id: team_id}, on_conflict: :nothing)
      sync_later(member_ids(team_id) -- [user.id])
    end
  end

  @doc "Stops sharing the user's key for `provider` with a team."
  def unshare(%Scope{user: user}, provider, team_id) do
    if key = Repo.get_by(Key, user_id: user.id, provider: provider) do
      Repo.delete_all(from s in Share, where: s.team_key_id == ^key.id and s.team_id == ^team_id)
      delete_unshared(user.id)
      sync_later(member_ids(team_id) -- [user.id])
    end

    :ok
  end

  @doc "Someone joined a team: they get the keys shared with it."
  def joined(team_id, user_id) do
    if Repo.exists?(from s in Share, where: s.team_id == ^team_id), do: sync_later([user_id])
    :ok
  end

  @doc """
  Someone left a team, or was removed: their keys are no longer shared with
  it, and they lose the keys shared with it (unless another team of theirs
  has them too).
  """
  def left(team_id, user_id) do
    mine =
      from s in Share,
        join: k in assoc(s, :team_key),
        where: s.team_id == ^team_id and k.user_id == ^user_id,
        select: s.id

    {unshared, _} = Repo.delete_all(from s in Share, where: s.id in subquery(mine))
    delete_unshared(user_id)

    if unshared > 0, do: sync_later(member_ids(team_id))
    if Repo.exists?(from s in Share, where: s.team_id == ^team_id), do: sync_later([user_id])
    :ok
  end

  @doc "An account is being deleted: its keys stop being shared, and teammates lose them."
  def deleted(user_id) do
    Repo.all(from k in Key, where: k.user_id == ^user_id) |> Enum.each(&forget/1)
  end

  @doc """
  Brings the user's opencode up to date, now: the sharing of their own keys
  ends where a key is no longer the login they use, and they get the keys
  their teams share and lose the ones no longer shared. Per provider, their
  own login is the one used; a team's key only when they have none.
  """
  def sync(user_id) do
    :global.trans({{__MODULE__, user_id}, self()}, fn -> do_sync(user_id) end, [node()])
  end

  defp do_sync(user_id) do
    with {:ok, logins} <- OpenCode.logins(user_id) do
      forget_replaced(user_id, logins)

      wanted = Map.new(wanted(user_id), &{@prefix <> to_string(&1.id), &1})
      have = MapSet.new(logins, & &1.id)
      stale = for l <- logins, team_login?(l), not Map.has_key?(wanted, l.id), do: l.id
      new = for {id, key} <- wanted, id not in have, do: {id, key}

      with :ok <- each(stale, &OpenCode.remove_login(user_id, &1)),
           :ok <-
             each(new, fn {id, key} ->
               label = "Team key from #{key.user.email}"
               OpenCode.add_key(user_id, id, key.provider, label, key.value, false)
             end),
           {:ok, logins} <-
             if(stale == [] and new == [], do: {:ok, logins}, else: OpenCode.logins(user_id)),
           do: pick_logins(user_id, logins)
    end
  end

  # The keys others share with the user's teams.
  defp wanted(user_id) do
    Repo.all(
      from k in Key,
        join: s in assoc(k, :shares),
        where: s.team_id in subquery(Teams.ids_query(user_id)) and k.user_id != ^user_id,
        distinct: true,
        preload: :user
    )
  end

  # Where a team's key is among a provider's logins, the one opencode uses:
  # the user's own, else a team's. opencode moves to the newest login when the
  # one in use goes, which may be a team's.
  defp pick_logins(user_id, logins) do
    logins
    |> Enum.group_by(& &1.provider)
    |> Enum.filter(fn {_provider, logins} -> Enum.any?(logins, &team_login?/1) end)
    |> each(fn {_provider, logins} ->
      {team, own} = Enum.split_with(logins, &team_login?/1)
      active = Enum.find(logins, & &1.active?)

      cond do
        own != [] and (active == nil or team_login?(active)) ->
          OpenCode.use_login(user_id, hd(own).id)

        active == nil ->
          OpenCode.use_login(user_id, hd(team).id)

        true ->
          :ok
      end
    end)
  end

  # The user's key for the provider, from the login they use for it; one kept
  # from a login they no longer use was replaced, and its sharing ends.
  defp own_key(user_id, provider) do
    with {:ok, logins} <- OpenCode.logins(user_id),
         %{type: "key", id: id} <-
           Enum.find(logins, &(&1.provider == provider and &1.active? and not team_login?(&1))) ||
             {:error, :not_a_key} do
      case Repo.get_by(Key, user_id: user_id, provider: provider) do
        %Key{credential_id: ^id} = key ->
          {:ok, key}

        replaced ->
          if replaced, do: forget(replaced)

          # Not logged: the query log would show the value.
          with {:ok, value} <- OpenCode.key(user_id, id),
               do:
                 {:ok,
                  Repo.insert!(
                    %Key{user_id: user_id, provider: provider, credential_id: id, value: value},
                    log: false
                  )}
      end
    else
      %{} -> {:error, :not_a_key}
      error -> error
    end
  end

  defp forget_replaced(user_id, logins) do
    in_use = for l <- logins, l.active?, do: l.id

    Repo.all(from k in Key, where: k.user_id == ^user_id and k.credential_id not in ^in_use)
    |> Enum.each(&forget/1)
  end

  defp forget(%Key{} = key) do
    team_ids = Repo.all(from s in Share, where: s.team_key_id == ^key.id, select: s.team_id)
    Repo.delete!(key)
    sync_later(member_ids(team_ids) -- [key.user_id])
  end

  defp delete_unshared(user_id) do
    Repo.delete_all(
      from k in Key,
        where:
          k.user_id == ^user_id and
            k.id not in subquery(from s in Share, select: s.team_key_id)
    )
  end

  defp member_ids(team_ids) do
    Repo.all(
      from m in Member,
        where: m.team_id in ^List.wrap(team_ids),
        distinct: true,
        select: m.user_id
    )
  end

  defp sync_later(user_ids) do
    for user_id <- Enum.uniq(user_ids) do
      Task.Supervisor.start_child(Burrow.TaskSupervisor, fn ->
        with {:error, reason} <- sync(user_id),
             do: Logger.warning("Team keys for user #{user_id} not synced: #{inspect(reason)}")

        Phoenix.PubSub.broadcast(Burrow.PubSub, "team_keys:#{user_id}", {:team_keys, user_id})
      end)
    end

    :ok
  end

  # Runs `fun` on each item until one fails.
  defp each(items, fun) do
    Enum.reduce_while(items, :ok, fn item, :ok ->
      case fun.(item) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end
end
