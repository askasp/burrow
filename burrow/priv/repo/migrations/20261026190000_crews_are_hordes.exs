defmodule Burrow.Repo.Migrations.CrewsAreHordes do
  use Ecto.Migration

  # Crews are hordes now (`Burrow.Hordes`): the peons' own word for it.
  def change do
    rename table(:crews), to: table(:hordes)
    rename table(:crew_peons), to: table(:horde_peons)
    rename table(:horde_peons), :crew_id, to: :horde_id
    rename table(:chats), :crew_id, to: :horde_id
    rename table(:chats), :crew_at_once, to: :horde_at_once
  end
end
