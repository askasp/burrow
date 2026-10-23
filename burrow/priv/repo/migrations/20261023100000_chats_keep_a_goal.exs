defmodule Burrow.Repo.Migrations.ChatsKeepAGoal do
  use Ecto.Migration

  # "/goal <condition>": the agent keeps working until the condition holds.
  def change do
    alter table(:chats) do
      add :goal, :text
    end
  end
end
