defmodule Burrow.GeneralChats.Chat do
  use Ecto.Schema

  @primary_key {:id, :string, autogenerate: false}
  schema "general_chats" do
    belongs_to :user, Burrow.Accounts.User
    field :title, :string, default: ""
    field :session_id, :string
    # The agent's model (provider/model) and effort; nil for the user's defaults
    field :model, :string
    field :effort, :string
    # Whether Peon may search the web for the next message
    field :web, :boolean, default: true
    # How many sources its latest answer cites
    field :sources, :integer, default: 0
    # When its first message went in; nil while the chat is empty
    field :started_at, :utc_datetime
    timestamps(type: :utc_datetime)
  end
end
