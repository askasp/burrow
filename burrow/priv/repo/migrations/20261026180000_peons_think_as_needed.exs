defmodule Burrow.Repo.Migrations.PeonsThinkAsNeeded do
  use Ecto.Migration

  # Each peon thinks as hard as its task needs (`Burrow.Crews`): the planner
  # rates each task, mapped to one of the model's thinking levels, kept with
  # the crew so a stuck peon can try again thinking harder.
  def change do
    alter table(:crews) do
      add :efforts, {:array, :string}, null: false, default: []
    end

    alter table(:crew_peons) do
      add :effort, :string
    end
  end
end
