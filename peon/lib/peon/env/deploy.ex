defmodule Peon.Env.Deploy do
  @moduledoc """
  One deploy of a changeset to an environment. Status goes `deploying` ->
  `watching` (the health window) -> `healthy`, or ends `failed`.
  """

  use Ecto.Schema

  @derive {Jason.Encoder,
           only: ~w(id env changeset_id from_id mode status detail inserted_at updated_at)a}
  schema "deploys" do
    field :env, :string
    field :changeset_id, :id
    field :from_id, :id
    # "hot" (code loaded into the running node) or "cold" (container restarted)
    field :mode, :string
    field :status, :string
    field :detail, :string
    timestamps(type: :utc_datetime)
  end
end
