defmodule Burrow.Projects.Project do
  use Ecto.Schema
  import Ecto.Changeset

  schema "projects" do
    field :name, :string
    field :slug, :string
    field :port, :integer
    field :preview_ports, :string
    belongs_to :user, Burrow.Accounts.User
    timestamps(type: :utc_datetime)
  end

  def create_changeset(project, attrs) do
    project
    |> cast(attrs, [:name])
    |> validate_required([:name])
    |> validate_length(:name, min: 2, max: 60)
    |> validate_format(:name, ~r/[a-zA-Z]/, message: "must contain a letter")
  end
end
