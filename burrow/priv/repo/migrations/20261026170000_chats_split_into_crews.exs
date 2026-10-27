defmodule Burrow.Repo.Migrations.ChatsSplitIntoCrews do
  use Ecto.Migration

  # "Split into a crew" in the chat's + menu: Peon splits big tasks into a
  # crew of peons by itself (`Burrow.Crews`), this many at a time; nil is off.
  def change do
    alter table(:chats) do
      add :crew_at_once, :integer
    end
  end
end
