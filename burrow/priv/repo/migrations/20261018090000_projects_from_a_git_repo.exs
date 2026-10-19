defmodule Burrow.Repo.Migrations.ProjectsFromAGitRepo do
  use Ecto.Migration

  # A project made from an existing git repo instead of the template. Its
  # Peon gives each chat a checkout and runs the repo's preview pack.
  def change do
    alter table(:projects) do
      add :repo_url, :string
    end
  end
end
