defmodule Burrow.Computers.Computer do
  use Ecto.Schema

  schema "computers" do
    # Nil until someone approves the pairing code
    belongs_to :user, Burrow.Accounts.User
    field :name, :string
    # As Go names them: linux, darwin, windows; amd64, arm64
    field :os, :string
    field :arch, :string
    field :version, :string
    # While pairing: the code Burrow and the computer both show, the hash of
    # the secret the computer polls with, and when the code expires
    field :user_code, :string
    field :device_code_hash, :binary
    field :pair_expires_at, :utc_datetime
    field :approved_at, :utc_datetime
    # The hash of the computer's own token, once it took it
    field :token_hash, :binary
    field :last_seen_at, :utc_datetime
    # The folders the computer last said it shares (`%{"path", "write"}`),
    # and whether it can show a folder picker
    field :folders, {:array, :map}, default: []
    field :can_pick, :boolean, default: false
    timestamps(type: :utc_datetime)
  end
end
