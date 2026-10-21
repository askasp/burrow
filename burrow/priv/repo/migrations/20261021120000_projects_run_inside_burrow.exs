defmodule Burrow.Repo.Migrations.ProjectsRunInsideBurrow do
  use Ecto.Migration

  # What each project's Peon kept in a database of its own now lives here;
  # its code lives in a Totem history per project (Totem.Repo).
  def change do
    drop_if_exists index(:projects, [:port])

    alter table(:projects) do
      add :settings, :map, default: %{}
      # Each project's Peon had a port of its own; it runs inside Burrow now.
      remove :port
    end

    create table(:chats, primary_key: false) do
      add :id, :string, primary_key: true
      add :project_id, references(:projects, on_delete: :delete_all), null: false
      add :title, :string, null: false, default: ""
      add :created_by, :string
      add :session_id, :string
      add :model, :string
      add :effort, :string
      add :pr_url, :string
      add :keep_until, :utc_datetime
      add :started_at, :utc_datetime
      timestamps(type: :utc_datetime)
    end

    create index(:chats, [:project_id])

    create table(:secrets) do
      add :project_id, references(:projects, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :value, :binary
      add :why, :string
      add :chat_id, :string
      add :set_by, :string
      timestamps(type: :utc_datetime)
    end

    create unique_index(:secrets, [:project_id, :name])

    create table(:incidents) do
      add :project_id, references(:projects, on_delete: :delete_all), null: false
      add :env, :string, null: false
      add :fingerprint, :string, null: false
      add :title, :string
      add :detail, :text
      add :status, :string, null: false, default: "open"
      add :count, :integer, null: false, default: 1
      add :chat_id, :string
      add :change_id, :integer
      add :last_seen_at, :utc_datetime
      timestamps(type: :utc_datetime)
    end

    create unique_index(:incidents, [:project_id, :env, :fingerprint])

    # Main checks and deploys, for the deploys panel and incidents.
    create table(:runs) do
      add :project_id, references(:projects, on_delete: :delete_all), null: false
      add :kind, :string, null: false
      add :env, :string
      add :change_id, :integer
      add :status, :string, null: false
      add :mode, :string
      add :detail, :text
      timestamps(type: :utc_datetime)
    end

    create index(:runs, [:project_id, :kind, :env])
  end
end
