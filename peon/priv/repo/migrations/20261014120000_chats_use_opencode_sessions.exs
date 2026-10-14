defmodule Peon.Repo.Migrations.ChatsUseOpencodeSessions do
  use Ecto.Migration

  # Chat history now lives in opencode sessions; Peon keeps only the link.
  def change do
    drop table(:messages)

    alter table(:conversations) do
      add :session_id, :string
    end
  end
end
