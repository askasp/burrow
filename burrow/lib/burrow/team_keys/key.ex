defmodule Burrow.TeamKeys.Key do
  @moduledoc "An API key its owner shares with teams (`Burrow.TeamKeys`)."

  use Ecto.Schema

  schema "team_keys" do
    field :provider, :string
    # The owner's opencode login the value came from
    field :credential_id, :string
    field :value, :binary, redact: true
    belongs_to :user, Burrow.Accounts.User
    has_many :shares, Burrow.TeamKeys.Share, foreign_key: :team_key_id
    timestamps(type: :utc_datetime)
  end
end
