defmodule Peon.Incidents.Incident do
  @moduledoc "Errors from a running environment, grouped by fingerprint."

  use Ecto.Schema

  @derive {Jason.Encoder,
           only:
             ~w(id env fingerprint title detail count status changeset_id chat_id last_seen_at inserted_at)a}
  schema "incidents" do
    field :env, :string
    field :fingerprint, :string
    field :title, :string
    field :detail, :string
    field :count, :integer, default: 1
    # "open", "fixing" (a chat is on it) or "resolved"
    field :status, :string
    # What was deployed when it was first seen
    field :changeset_id, :id
    field :chat_id, :string
    field :last_seen_at, :utc_datetime
    timestamps(type: :utc_datetime)
  end
end
