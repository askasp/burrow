defmodule Burrow.Repo.Migrations.TeamsShareAiKeys do
  use Ecto.Migration

  # An API key someone connected on the AI page and shares with one or more
  # of their teams (`Burrow.TeamKeys`). Burrow keeps the value only while the
  # key is shared: everyone in those teams gets it in their own opencode.
  def change do
    create table(:team_keys) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :provider, :string, null: false
      # The owner's opencode credential the value came from.
      add :credential_id, :string, null: false
      add :value, :binary, null: false
      timestamps(type: :utc_datetime)
    end

    create unique_index(:team_keys, [:user_id, :provider])

    create table(:team_key_shares) do
      add :team_key_id, references(:team_keys, on_delete: :delete_all), null: false
      add :team_id, references(:teams, on_delete: :delete_all), null: false
      timestamps(type: :utc_datetime)
    end

    create unique_index(:team_key_shares, [:team_key_id, :team_id])
    create index(:team_key_shares, [:team_id])
  end
end
