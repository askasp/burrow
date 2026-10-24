defmodule Burrow.Repo.Migrations.UsersCanBeAdmins do
  use Ecto.Migration

  # Sign-ups are closed: admins make the logins (`BurrowWeb.LoginLive.Index`).
  def change do
    alter table(:users) do
      add :admin, :boolean, null: false, default: false
    end
  end
end
