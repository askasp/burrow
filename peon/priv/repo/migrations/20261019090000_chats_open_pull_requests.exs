defmodule Peon.Repo.Migrations.ChatsOpenPullRequests do
  use Ecto.Migration

  # A repo chat's pull request, once its first submit opened one.
  def change do
    alter table(:conversations) do
      add :pr_url, :string
    end
  end
end
