defmodule Burrow.Repo.Migrations.HordesFromTheQueueOnly do
  use Ecto.Migration

  # Hordes run the chat's tk queue (`Burrow.Hordes.run_queue/2`): no plans of
  # their own any more, so no groups and no plans left waiting.
  def up do
    execute "DELETE FROM horde_peons WHERE horde_id IN (SELECT id FROM hordes WHERE status = 'planned')"
    execute "DELETE FROM hordes WHERE status = 'planned'"

    alter table(:horde_peons) do
      remove :group
    end
  end

  def down do
    alter table(:horde_peons) do
      add :group, :string
    end
  end
end
