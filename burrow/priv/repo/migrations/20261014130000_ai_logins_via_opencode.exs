defmodule Burrow.Repo.Migrations.AiLoginsViaOpencode do
  use Ecto.Migration

  # AI access now goes through each user's own opencode logins instead of
  # Burrow's LLM proxy.
  def change do
    drop table(:llm_usage)

    alter table(:users) do
      add :ai_model, :string
    end
  end
end
