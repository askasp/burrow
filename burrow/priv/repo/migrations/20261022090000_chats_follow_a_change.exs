defmodule Burrow.Repo.Migrations.ChatsFollowAChange do
  use Ecto.Migration

  # A chat started with "Follow up on #N": its agent starts from change N.
  def change do
    alter table(:chats) do
      add :follows, :integer
    end
  end
end
