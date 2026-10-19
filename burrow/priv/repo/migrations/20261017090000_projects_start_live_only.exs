defmodule Burrow.Repo.Migrations.ProjectsStartLiveOnly do
  use Ecto.Migration

  # "live": main is live, no staging (how new projects start); "pipeline":
  # staging and prod. Projects made before this have both already.
  def change do
    alter table(:projects) do
      add :envs, :string, null: false, default: "pipeline"
    end
  end
end
