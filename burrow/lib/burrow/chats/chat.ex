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
    # A repo chat's pull request (`Burrow.GitRepo.PullRequest`) and its
    # state as GitHub last said: "open", "merged" or "closed"
    field :pr_url, :string
    field :pr_state, :string
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
    # The horde it works in as one of its peons (`Burrow.Hordes`)
    field :horde_id, :integer
    # How its change ships (`Burrow.Ship`): "review" (a person merges it),
    # "pilot" (on to prod once healthy on staging) or nil, merged when it passes
    field :shipping, :string
    # "Split into a horde": Peon splits big tasks into a horde by itself, this
    # many peons at a time (`Burrow.Hordes`); nil is off
    field :horde_at_once, :integer
    timestamps(type: :utc_datetime)
  end
end
