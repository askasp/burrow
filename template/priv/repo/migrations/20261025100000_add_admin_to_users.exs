# peon:accounts-only: Peon leaves this file out of apps made without accounts.
defmodule PeonTemplate.Repo.Migrations.AddAdminToUsers do
  use Ecto.Migration

  # The first account is the admin; admins add the other accounts.
  def change do
    alter table(:users) do
      add :admin, :boolean, null: false, default: false
    end
  end
end
