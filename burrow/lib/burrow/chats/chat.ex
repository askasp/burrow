defmodule Burrow.Chats.Chat do
  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false}
  schema "chats" do
    belongs_to :project, Burrow.Projects.Project
    field :title, :string, default: ""
    field :created_by, :string
    field :session_id, :string
    # The agent's model (provider/model) and effort; nil for the defaults
    field :model, :string
    field :effort, :string
    # A repo chat's pull request (`Burrow.GitRepo.PullRequest`)
    field :pr_url, :string
    # Runs without use until then (`Burrow.Chat`)
    field :keep_until, :utc_datetime
    # When its first message went in; nil while the chat is empty
    field :started_at, :utc_datetime
    timestamps(type: :utc_datetime)
  end
end
