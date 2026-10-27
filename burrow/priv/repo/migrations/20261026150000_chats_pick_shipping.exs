defmodule Burrow.Repo.Migrations.ChatsPickShipping do
  use Ecto.Migration

  # How a chat's change ships (`Burrow.Ship`): "review" waits for a person to
  # merge it, "pilot" also ships it to prod once staging runs it healthily;
  # nil merges it when its checks pass.
  def change do
    alter table(:chats) do
      add :shipping, :string
    end
  end
end
