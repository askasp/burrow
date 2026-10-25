defmodule Burrow.Repo.Migrations.ChatsKnowTheirPrState do
  use Ecto.Migration

  # A repo chat's PR as GitHub last said: "open", "merged" or "closed".
  def change do
    alter table(:chats) do
      add :pr_state, :string
    end
  end
end
