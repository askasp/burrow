defmodule Burrow.Repo.Migrations.GeneralChats do
  use Ecto.Migration

  # Chats outside projects (the Chats space): a user's own, to ask, search
  # and think. A project chat can start from one.
  def change do
    create table(:general_chats, primary_key: false) do
      add :id, :string, primary_key: true
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :title, :string, null: false, default: ""
      add :session_id, :string
      add :model, :string
      add :effort, :string
      add :web, :boolean, null: false, default: true
      add :sources, :integer, null: false, default: 0
      add :started_at, :utc_datetime
      timestamps(type: :utc_datetime)
    end

    create index(:general_chats, [:user_id])

    alter table(:chats) do
      add :from_chat, :string
    end
  end
end
