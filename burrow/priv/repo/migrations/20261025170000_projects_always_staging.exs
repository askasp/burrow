defmodule Burrow.Repo.Migrations.ProjectsAlwaysStaging do
  use Ecto.Migration

  # Every app project has staging and prod: there is nothing to choose.
  def change do
    alter table(:projects) do
      remove :envs, :string, null: false, default: "pipeline"
    end
  end
end
