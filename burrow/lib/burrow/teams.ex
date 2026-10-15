defmodule Burrow.Teams do
  @moduledoc """
  Teams: people who share projects. A project shared with a team can be seen,
  opened and restarted by everyone in it; only its owner changes who it is
  shared with.

  Whoever creates a team owns it. Owners add people by the email they
  registered with and remove them; anyone can leave, except a team's last
  owner. Leaving a team takes your projects out of it.
  """

  import Ecto.Query

  alias Burrow.Repo
  alias Burrow.Accounts
  alias Burrow.Accounts.Scope
  alias Burrow.Projects.Project
  alias Burrow.Teams.{Member, Team}

  def subscribe, do: Phoenix.PubSub.subscribe(Burrow.PubSub, "teams")

  @doc "The teams the user is in, by name."
  def list(%Scope{user: user}) do
    Repo.all(
      from t in Team,
        join: m in Member,
        on: m.team_id == t.id and m.user_id == ^user.id,
        order_by: [asc: t.name, asc: t.id]
    )
  end

  @doc "Ids of the teams the user is in, as a query (for `in subquery(...)`)."
  def ids_query(user_id), do: from(m in Member, where: m.user_id == ^user_id, select: m.team_id)

  def get!(%Scope{user: user}, id) do
    Repo.one!(
      from t in Team,
        join: m in Member,
        on: m.team_id == t.id and m.user_id == ^user.id,
        where: t.id == ^id
    )
  end

  @doc "Whether user `user_id` is in team `team_id`."
  def member_id?(team_id, user_id),
    do: Repo.exists?(from m in Member, where: m.team_id == ^team_id and m.user_id == ^user_id)

  def member?(%Scope{user: user}, team_id),
    do: Repo.exists?(from m in Member, where: m.team_id == ^team_id and m.user_id == ^user.id)

  def owner?(%Scope{user: user}, %Team{id: team_id}),
    do: role(user.id, team_id) == "owner"

  defp role(user_id, team_id),
    do:
      Repo.one(
        from m in Member, where: m.team_id == ^team_id and m.user_id == ^user_id, select: m.role
      )

  @doc "Members with their users, owners first."
  def members(%Team{id: team_id}) do
    Repo.all(
      from m in Member,
        join: u in assoc(m, :user),
        where: m.team_id == ^team_id,
        order_by: [desc: m.role == "owner", asc: u.email],
        preload: [user: u]
    )
  end

  def change(attrs \\ %{}), do: Team.changeset(%Team{}, attrs)

  @doc "Creates a team owned by the user."
  def create(%Scope{user: user}, attrs) do
    Repo.transaction(fn ->
      with {:ok, team} <- Repo.insert(Team.changeset(%Team{}, attrs)) do
        Repo.insert!(%Member{team_id: team.id, user_id: user.id, role: "owner"})
        team
      else
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
    |> broadcast()
  end

  @doc "Owners add a registered user by email."
  def add_member(%Scope{} = scope, %Team{} = team, email) do
    with :ok <- check_owner(scope, team),
         %Accounts.User{} = user <-
           Accounts.get_user_by_email(String.trim(email)) || {:error, :no_user},
         nil <- role(user.id, team.id) do
      member = Repo.insert!(%Member{team_id: team.id, user_id: user.id, role: "member"})
      broadcast({:ok, team})
      {:ok, member}
    else
      role when is_binary(role) -> {:error, :already_member}
      error -> error
    end
  end

  @doc """
  Removes someone from a team: owners can remove anyone, everyone can remove
  themselves. The last owner can't leave.
  """
  def remove_member(%Scope{user: me} = scope, %Team{} = team, user_id) do
    with :ok <- if(user_id == me.id, do: :ok, else: check_owner(scope, team)),
         %Member{} = member <-
           Repo.get_by(Member, team_id: team.id, user_id: user_id) || {:error, :not_member},
         :ok <- check_not_last_owner(member) do
      Repo.transaction(fn ->
        Repo.update_all(
          from(p in Project, where: p.team_id == ^team.id and p.user_id == ^user_id),
          set: [team_id: nil]
        )

        Repo.delete!(member)
      end)

      broadcast({:ok, team})
      :ok
    end
  end

  defp check_owner(scope, team), do: if(owner?(scope, team), do: :ok, else: {:error, :not_owner})

  defp check_not_last_owner(%Member{role: "owner", team_id: team_id}) do
    owners =
      Repo.aggregate(
        from(m in Member, where: m.team_id == ^team_id and m.role == "owner"),
        :count
      )

    if owners > 1, do: :ok, else: {:error, :last_owner}
  end

  defp check_not_last_owner(_member), do: :ok

  defp broadcast({:ok, team} = result) do
    Phoenix.PubSub.broadcast(Burrow.PubSub, "teams", {:team_changed, team.id})
    result
  end

  defp broadcast(error), do: error
end
