defmodule Burrow.Repo.Migrations.UsersFoldDaysOfChats do
  use Ecto.Migration

  # The chat drawer's day groups the user folded: "Yesterday", "This week",
  # "Older" show only the chats still open.
  def change do
    alter table(:users) do
      add :folded_days, {:array, :string}, null: false, default: []
    end
  end
end
