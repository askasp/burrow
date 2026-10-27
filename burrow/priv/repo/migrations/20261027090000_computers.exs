defmodule Burrow.Repo.Migrations.Computers do
  use Ecto.Migration

  # Computers paired through Burrow Bridge, for Peon to work on their files.
  # A row starts unclaimed (no user) while its pairing code waits for
  # someone to approve it in Burrow.
  def change do
    create table(:computers) do
      add :user_id, references(:users, on_delete: :delete_all)
      add :name, :string, null: false
      add :os, :string, null: false
      add :arch, :string, null: false
      add :version, :string
      add :user_code, :string
      add :device_code_hash, :binary
      add :token_hash, :binary
      add :pair_expires_at, :utc_datetime
      add :approved_at, :utc_datetime
      add :last_seen_at, :utc_datetime
      add :folders, {:array, :map}, null: false, default: []
      add :can_pick, :boolean, null: false, default: false
      timestamps(type: :utc_datetime)
    end

    create index(:computers, [:user_id])
    create unique_index(:computers, [:user_code])
    create unique_index(:computers, [:device_code_hash])
    create unique_index(:computers, [:token_hash])
  end
end
