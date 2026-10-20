defmodule Burrow.Repo.Migrations.UsersRememberTheirWorkspace do
  use Ecto.Migration

  # The project Burrow opens after login, and whether the workspace's
  # project rail shows names.
  def change do
    alter table(:users) do
      add :last_project_id, :integer
      add :rail_open, :boolean, null: false, default: false
    end
  end
end
