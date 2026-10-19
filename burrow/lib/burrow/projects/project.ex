defmodule Burrow.Projects.Project do
  use Ecto.Schema
  import Ecto.Changeset

  schema "projects" do
    field :name, :string
    field :slug, :string
    field :port, :integer
    field :preview_ports, :string
    # "live" (main is live, no staging) or "pipeline" (staging and prod)
    field :envs, :string, default: "live"
    # An existing git repo to work on instead of a new app from the template
    field :repo_url, :string
    belongs_to :user, Burrow.Accounts.User
    belongs_to :team, Burrow.Teams.Team
    timestamps(type: :utc_datetime)
  end

  def create_changeset(project, attrs) do
    project
    |> cast(attrs, [:name, :repo_url])
    |> validate_required([:name])
    |> validate_length(:name, min: 2, max: 60)
    |> validate_format(:name, ~r/[a-zA-Z]/, message: "must contain a letter")
    |> update_change(:repo_url, &String.trim/1)
    |> validate_format(:repo_url, ~r{\Ahttps://[^\s/]+/[^\s]+\z},
      message: "must be an https:// git URL"
    )
  end

  def shared?(%__MODULE__{team_id: team_id}), do: team_id != nil

  @doc "Made from an existing git repo: chats open PRs, there are no envs."
  def repo?(%__MODULE__{repo_url: url}), do: url not in [nil, ""]

  def live_only?(%__MODULE__{envs: envs} = project), do: envs == "live" and not repo?(project)
end
