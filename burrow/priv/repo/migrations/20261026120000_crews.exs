defmodule Burrow.Repo.Migrations.Crews do
  use Ecto.Migration

  # A crew (`Burrow.Crews`): a chat's big task split into peons, each a chat
  # of its own that ships on its own, so many at a time.
  def change do
    create table(:crews) do
      add :project_id, references(:projects, on_delete: :delete_all), null: false
      # The chat that planned it, where it shows
      add :chat_id, :string, null: false
      # planned, running, paused, stopped, done
      add :status, :string, null: false, default: "planned"
      # Why it is paused: "you" or "main" (main went red)
      add :paused_by, :string
      add :at_once, :integer, null: false, default: 4
      add :started_at, :utc_datetime
      add :finished_at, :utc_datetime
      timestamps(type: :utc_datetime)
    end

    create index(:crews, [:project_id, :status])
    create index(:crews, [:chat_id])

    create table(:crew_peons) do
      add :crew_id, references(:crews, on_delete: :delete_all), null: false
      add :n, :integer, null: false
      add :title, :string, null: false
      add :task, :text, null: false
      add :group, :string
      # Its own chat, once it starts
      add :chat_id, :string
      # queued, working, checking, fixing, held, shipped, needs_you,
      # skipped, stopped, reverted
      add :status, :string, null: false, default: "queued"
      add :fails, :integer, null: false, default: 0
      add :change_id, :integer
      add :log, {:array, :map}, null: false, default: []
      timestamps(type: :utc_datetime)
    end

    create unique_index(:crew_peons, [:crew_id, :n])
    create index(:crew_peons, [:chat_id])

    alter table(:chats) do
      # The crew it works in as a peon (`Burrow.Crews`)
      add :crew_id, :integer
    end
  end
end
