defmodule Burrow.Repo.Migrations.PeonsTakeTickets do
  use Ecto.Migration

  # A crew runs its chat's tk queue (`Burrow.Crews`): each peon takes one
  # ticket, and starts once the tickets it depends on have shipped.
  def change do
    alter table(:crew_peons) do
      add :ticket, :string
      add :deps, {:array, :string}, null: false, default: []
    end
  end
end
