defmodule Burrow.TeamKeys.Share do
  @moduledoc "A team a key is shared with (`Burrow.TeamKeys`)."

  use Ecto.Schema

  schema "team_key_shares" do
    belongs_to :team_key, Burrow.TeamKeys.Key
    belongs_to :team, Burrow.Teams.Team
    timestamps(type: :utc_datetime)
  end
end
