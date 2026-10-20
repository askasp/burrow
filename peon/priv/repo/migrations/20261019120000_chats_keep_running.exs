defmodule Peon.Repo.Migrations.ChatsKeepRunning do
  use Ecto.Migration

  # Until when a chat's preview stays up without use, e.g. while others test it.
  def change do
    alter table(:conversations) do
      add :keep_until, :utc_datetime
    end
  end
end
