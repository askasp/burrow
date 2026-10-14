defmodule Peon.Repo.Migrations.CreateConversations do
  use Ecto.Migration

  def change do
    create table(:conversations, primary_key: false) do
      add :id, :string, primary_key: true
      add :title, :string, null: false
      add :created_by, :string
      timestamps(type: :utc_datetime)
    end

    create table(:messages) do
      add :conversation_id, references(:conversations, type: :string), null: false
      add :role, :string, null: false
      add :content, :text
      add :tool_calls, :map
      add :tool_call_id, :string
      add :name, :string
      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:messages, [:conversation_id, :id])
    create index(:changesets, [:conversation_id])
  end
end
