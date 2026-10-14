defmodule Burrow.Repo.Migrations.CreateProjects do
  use Ecto.Migration

  def change do
    create table(:projects) do
      add :user_id, references(:users, on_delete: :delete_all), null: false
      add :name, :string, null: false
      add :slug, :string, null: false
      add :port, :integer, null: false
      add :preview_ports, :string, null: false
      timestamps(type: :utc_datetime)
    end

    create unique_index(:projects, [:slug])
    create unique_index(:projects, [:port])
    create index(:projects, [:user_id])

    create table(:llm_usage) do
      add :project_id, references(:projects, on_delete: :delete_all), null: false
      add :model, :string
      add :prompt_tokens, :integer, null: false, default: 0
      add :completion_tokens, :integer, null: false, default: 0
      timestamps(type: :utc_datetime, updated_at: false)
    end

    create index(:llm_usage, [:project_id])
  end
end
