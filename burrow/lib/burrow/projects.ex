defmodule Burrow.Projects do
  @moduledoc """
  Users' projects. Every project gets its own Peon, run by a `Burrow.Cell`.

  Per-project secrets (Peon's secret key, the SSO secret shared with Peon) are
  derived from Burrow's secret, so none are stored.
  """

  import Ecto.Query

  alias Burrow.Repo
  alias Burrow.Accounts.Scope
  alias Burrow.Projects.Project

  @peon_port_base 4100
  @preview_port_base 5000
  @previews_per_project 10

  def subscribe, do: Phoenix.PubSub.subscribe(Burrow.PubSub, "projects")

  def list(%Scope{user: user}),
    do: Repo.all(from p in Project, where: p.user_id == ^user.id, order_by: [desc: p.id])

  def all, do: Repo.all(Project)

  def get!(%Scope{user: user}, id), do: Repo.get_by!(Project, id: id, user_id: user.id)

  def get(id), do: Repo.get(Project, id)

  def change(attrs \\ %{}), do: Project.create_changeset(%Project{}, attrs)

  @doc "Creates a project and starts its Peon."
  def create(%Scope{user: user}, attrs) do
    Repo.transaction(fn ->
      changeset = Project.create_changeset(%Project{user_id: user.id}, attrs)

      with {:ok, _} <- Ecto.Changeset.apply_action(changeset, :insert) do
        name = Ecto.Changeset.get_field(changeset, :name)
        index = (Repo.one(from p in Project, select: max(p.id)) || 0) + 1
        first = @preview_port_base + index * @previews_per_project

        changeset
        |> Ecto.Changeset.change(
          slug: unique_slug(name),
          port: @peon_port_base + index,
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

  defp unique_slug(name) do
    base =
      name
      |> String.downcase()
      |> String.replace(~r/[^a-z0-9]+/, "_")
      |> String.trim("_")
      |> String.slice(0, 30)

    base = if base =~ ~r/^[a-z]/, do: base, else: "app_" <> base

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

  @doc "A short-lived link that signs the user into the project's Peon."
  def peon_url(project, email) do
    token = Phoenix.Token.sign(secret(project, "sso"), "peon sso", email)
    "http://#{Application.fetch_env!(:burrow, :peon_host)}:#{project.port}/sso?token=#{token}"
  end
end
