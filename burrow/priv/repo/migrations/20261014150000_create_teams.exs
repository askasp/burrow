defmodule Burrow.Repo.Migrations.CreateTeams do
  use Ecto.Migration

  def change do
    create table(:teams) do
      add :name, :string, null: false
      timestamps(type: :utc_datetime)
    end

    create table(:team_members) do
      add :team_id, references(:teams, on_delete: :delete_all), null: false
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :role, :string, null: false, default: "member"
      timestamps(type: :utc_datetime)
    end

    create unique_index(:team_members, [:team_id, :user_id])
    create index(:team_members, [:user_id])

    # A project with a team is shared with everyone in it; without one it is private.
    alter table(:projects) do
      add :team_id, references(:teams, on_delete: :nilify_all)
    end

    create index(:projects, [:team_id])
  end
end
