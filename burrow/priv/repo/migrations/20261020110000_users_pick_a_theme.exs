defmodule Burrow.Repo.Migrations.UsersPickATheme do
  use Ecto.Migration

  # "system" follows the device; "light" or "dark" pin it, in Burrow and
  # every Peon.
  def change do
    alter table(:users) do
      add :theme, :string, null: false, default: "system"
    end
  end
end
