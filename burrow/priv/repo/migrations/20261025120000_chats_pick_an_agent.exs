defmodule Burrow.Repo.Migrations.ChatsPickAnAgent do
  use Ecto.Migration

  # The chat's opencode agent: plan, build (nil) or design.
  def change do
    alter table(:chats) do
      add :agent, :string
    end
  end
end
