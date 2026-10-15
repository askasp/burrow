defmodule Burrow.Projects do
  @moduledoc """
  Users' projects. Every project gets its own Peon, run by a `Burrow.Cell`.

  A project is private to its owner, or shared with one of the owner's teams
  (`team_id`): then everyone in that team can see, open and restart it. Its
  Peon still runs on the owner's AI login.

  Per-project secrets (Peon's secret key, the SSO secret shared with Peon) are
  derived from Burrow's secret, so none are stored.
  """

  import Ecto.Query

  alias Burrow.Repo
  alias Burrow.Accounts.Scope
  alias Burrow.Projects.Project
  alias Burrow.Teams

  @peon_port_base 4100
  @preview_port_base 5000
  @previews_per_project 10

  def subscribe, do: Phoenix.PubSub.subscribe(Burrow.PubSub, "projects")

  @doc "The user's own projects and those shared with their teams, newest first."
  def list(%Scope{} = scope),
    do: Repo.all(from p in visible(scope), order_by: [desc: p.id], preload: [:user, :team])

  @doc "Only the projects the user owns."
  def owned(%Scope{user: user}), do: Repo.all(from p in Project, where: p.user_id == ^user.id)

  def all, do: Repo.all(Project)

  def get!(%Scope{} = scope, id),
    do: Repo.one!(from p in visible(scope), where: p.id == ^id, preload: [:user, :team])

  defp visible(%Scope{user: user}) do
    from p in Project,
      where: p.user_id == ^user.id or p.team_id in subquery(Teams.ids_query(user.id))
  end

  def owner?(%Scope{user: user}, %Project{user_id: user_id}), do: user.id == user_id

  def get(id), do: Repo.get(Project, id)

  def change(attrs \\ %{}), do: Project.create_changeset(%Project{}, attrs)

  @doc """
  Creates a project and starts its Peon. A `"team_id"` in `attrs` shares it
  with that team, which must be one of the user's.
  """
  def create(%Scope{user: user} = scope, attrs) do
    Repo.transaction(fn ->
      changeset =
        %Project{user_id: user.id}
        |> Project.create_changeset(attrs)
        |> put_team(scope, attrs["team_id"] || attrs[:team_id])

      with {:ok, _} <- Ecto.Changeset.apply_action(changeset, :insert) do
        name = Ecto.Changeset.get_field(changeset, :name)
        index = (Repo.one(from p in Project, select: max(p.id)) || 0) + 1
        first = @preview_port_base + index * @previews_per_project

        changeset
        |> Ecto.Changeset.change(
          slug: unique_slug(name),
          port: peon_port(@peon_port_base + index),
          preview_ports: "#{first}-#{first + @previews_per_project - 1}"
        )
        |> Repo.insert!()
      else
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
    |> case do
      {:ok, project} ->
        Burrow.Cell.ensure_started(project)
        Phoenix.PubSub.broadcast(Burrow.PubSub, "projects", {:project_created, project})
        {:ok, project}

      error ->
        error
    end
  end

  defp put_team(changeset, _scope, team_id) when team_id in [nil, ""], do: changeset

  defp put_team(changeset, scope, team_id) do
    with id when is_integer(id) <- parse_id(team_id),
         true <- Teams.member?(scope, id) do
      Ecto.Changeset.put_change(changeset, :team_id, id)
    else
      _ -> Ecto.Changeset.add_error(changeset, :team_id, "is not one of your teams")
    end
  end

  @doc "The owner shares the project with one of their teams, or makes it private (`nil`)."
  def share(%Scope{} = scope, %Project{} = project, team_id) do
    team_id = parse_id(team_id)

    cond do
      not owner?(scope, project) ->
        {:error, :not_owner}

      team_id == :invalid or (team_id && not Teams.member?(scope, team_id)) ->
        {:error, :not_member}

      true ->
        {1, _} =
          Repo.update_all(from(p in Project, where: p.id == ^project.id), set: [team_id: team_id])

        project = Repo.preload(%{project | team_id: team_id}, [:team], force: true)
        Phoenix.PubSub.broadcast(Burrow.PubSub, "projects", {:project_updated, project})
        {:ok, project}
    end
  end

  @doc """
  The owner hands the project to another member of its team. The project
  keeps its team, and its Peon restarts on the new owner's AI login.
  """
  def hand_over(%Scope{} = scope, %Project{} = project, user_id) do
    user_id = parse_id(user_id)

    cond do
      not owner?(scope, project) ->
        {:error, :not_owner}

      project.team_id == nil or user_id in [nil, :invalid] or user_id == project.user_id or
          not Teams.member_id?(project.team_id, user_id) ->
        {:error, :not_a_teammate}

      true ->
        {1, _} =
          Repo.update_all(from(p in Project, where: p.id == ^project.id), set: [user_id: user_id])

        project = Repo.preload(%{project | user_id: user_id}, [:user, :team], force: true)
        Burrow.Cell.restart(project.id)
        Phoenix.PubSub.broadcast(Burrow.PubSub, "projects", {:project_updated, project})
        {:ok, project}
    end
  end

  defp parse_id(id) when id in [nil, ""], do: nil
  defp parse_id(id) when is_integer(id), do: id

  defp parse_id(id) do
    case Integer.parse(to_string(id)) do
      {id, ""} -> id
      _ -> :invalid
    end
  end

  @doc "The slug a name turns into, before a number is added to make it unique."
  def slug_base(name) do
    base =
      (name || "")
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "_")
      |> String.trim("_")
      |> String.slice(0, 30)

    if base =~ ~r/^[a-z]/, do: base, else: "app_" <> base
  end

  defp unique_slug(name) do
    base = slug_base(name)

    Stream.iterate(1, &(&1 + 1))
    |> Stream.map(fn
      1 -> base
      n -> "#{base}_#{n}"
    end)
    |> Enum.find(&(not Repo.exists?(from p in Project, where: p.slug == ^&1)))
  end

  ## Derived secrets

  def secret(%Project{id: id}, purpose) do
    base = Application.fetch_env!(:burrow, BurrowWeb.Endpoint)[:secret_key_base]
    :crypto.mac(:hmac, :sha256, base, "#{purpose}:#{id}") |> Base.url_encode64(padding: false)
  end

  # The first port from `port` on that a browser opens and no project has.
  defp peon_port(port) do
    if Burrow.Ports.browser_safe?(port) and
         not Repo.exists?(from p in Project, where: p.port == ^port),
       do: port,
       else: peon_port(port + 1)
  end

  @doc "A short-lived link that signs the user into the project's Peon."
  def peon_url(project, email) do
    token = Phoenix.Token.sign(secret(project, "sso"), "peon sso", email)
    "http://#{Application.fetch_env!(:burrow, :peon_host)}:#{project.port}/sso?token=#{token}"
  end
end
