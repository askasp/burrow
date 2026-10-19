defmodule Peon.Repo.Migrations.ChatsPickModelAndEffort do
  use Ecto.Migration

  def change do
    alter table(:conversations) do
      # nil: the project's model, at its default effort
      add :model, :string
      add :effort, :string
    end
  end
end
