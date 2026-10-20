defmodule Burrow.Repo.Migrations.ProjectsPickTheirLogin do
  use Ecto.Migration

  # The login a new app starts with: "accounts" (email and password, how
  # every project started before this), "basic" (one username and password,
  # HTTP basic auth) or "open". The basic auth login itself is not stored:
  # it goes to the project's Peon once, as the app's secrets.
  def change do
    alter table(:projects) do
      add :auth, :string, null: false, default: "accounts"
    end
  end
end
