defmodule Peon.Repo.Migrations.CreateSecrets do
  use Ecto.Migration

  def change do
    create table(:secrets, primary_key: false) do
      add :name, :string, primary_key: true
      # nil while the agent has asked for it and nobody has set it yet
      add :value, :binary
      add :why, :text
      add :chat_id, :string
      add :set_by, :string
      timestamps(type: :utc_datetime)
    end
  end
end
