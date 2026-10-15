defmodule Peon.Repo.Migrations.CreateShipping do
  use Ecto.Migration

  def change do
    alter table(:changesets) do
      add :verify, :map
    end

    create table(:deploys) do
      add :env, :string, null: false
      add :changeset_id, references(:changesets), null: false
      add :from_id, references(:changesets)
      add :mode, :string
      add :status, :string, null: false
      add :detail, :text
      timestamps(type: :utc_datetime)
    end

    create index(:deploys, [:env, :id])

    create table(:incidents) do
      add :env, :string, null: false
      add :fingerprint, :string, null: false
      add :title, :string, null: false
      add :detail, :text, null: false
      add :count, :integer, null: false, default: 1
      add :status, :string, null: false
      add :changeset_id, references(:changesets)
      add :chat_id, :string
      add :last_seen_at, :utc_datetime, null: false
      timestamps(type: :utc_datetime)
    end

    create unique_index(:incidents, [:env, :fingerprint])
  end
end
