defmodule Peon.Repo.Migrations.ChatsStartEmpty do
  use Ecto.Migration

  # A chat can wait empty, without a title, for its first message
  # (`Peon.Chats.started/2`). The chats so far all had one.
  def change do
    alter table(:conversations) do
      add :started_at, :utc_datetime
    end

    execute "UPDATE conversations SET started_at = inserted_at", ""
  end
end
