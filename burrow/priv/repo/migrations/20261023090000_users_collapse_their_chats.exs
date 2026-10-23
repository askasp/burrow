defmodule Burrow.Repo.Migrations.UsersCollapseTheirChats do
  use Ecto.Migration

  # The workspace's chat drawer replaced the project rail: whether it is
  # collapsed to a strip, in place of whether the rail showed names.
  def change do
    alter table(:users) do
      remove :rail_open, :boolean, null: false, default: false
      add :chats_collapsed, :boolean, null: false, default: false
    end
  end
end
