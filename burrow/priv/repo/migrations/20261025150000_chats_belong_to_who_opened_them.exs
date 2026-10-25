defmodule Burrow.Repo.Migrations.ChatsBelongToWhoOpenedThem do
  use Ecto.Migration

  # A chat is seen only by the user who opened it; Peon's (no user) by the
  # project's owner. Existing chats go to the user whose email opened them.
  def up do
    alter table(:chats) do
      add :user_id, references(:users, on_delete: :nilify_all)
    end

    create index(:chats, [:project_id, :user_id])

    execute "UPDATE chats SET user_id = (SELECT id FROM users WHERE users.email = chats.created_by)"
  end

  def down do
    drop index(:chats, [:project_id, :user_id])

    alter table(:chats) do
      remove :user_id
    end
  end
end
