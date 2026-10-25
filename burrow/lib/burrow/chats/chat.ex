defmodule Burrow.Chats.Chat do
  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false}
  schema "chats" do
    belongs_to :project, Burrow.Projects.Project
    field :title, :string, default: ""
    field :created_by, :string
    # Who sees it; nil for one Peon opened, which the project's owner sees (`Burrow.Chats.list/2`)
    belongs_to :user, Burrow.Accounts.User
    field :session_id, :string
    # The agent's model (provider/model) and effort, one of the model's
    # opencode variants (its thinking levels); nil for the defaults
    field :model, :string
    field :effort, :string
    # The agent it talks to: "plan", "design" or nil for build (`Burrow.Chats.agents/0`)
    field :agent, :string
    # A repo chat's pull request (`Burrow.GitRepo.PullRequest`)
    field :pr_url, :string
    # Runs without use until then (`Burrow.Chat`)
    field :keep_until, :utc_datetime
    # When its first message went in; nil while the chat is empty
    field :started_at, :utc_datetime
    # The change it follows up on ("Follow up on #N"); its agent starts from it
    field :follows, :integer
    # The general chat it starts from (`Burrow.GeneralChats`); its agent reads that conversation
    field :from_chat, :string
    # "/goal <condition>": the agent keeps going until it holds (`Burrow.Chat.KeepGoing`)
    field :goal, :string
    timestamps(type: :utc_datetime)
  end
end
