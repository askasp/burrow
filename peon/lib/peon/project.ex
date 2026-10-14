defmodule Peon.Project do
  @moduledoc "The one project this Peon serves, with its human-edited settings."

  use Ecto.Schema

  alias Peon.Repo

  schema "project" do
    field :slug, :string
    field :name, :string
    field :settings, :map, default: %{}
    timestamps(type: :utc_datetime)
  end

  def get, do: Repo.one(__MODULE__)

  @doc "Settings overrides for `PeonCore.Policy.check/3`."
  def policy_settings do
    settings = (get() || %__MODULE__{}).settings

    for {key, policy_key} <- [
          {"restart_paths", :restart_paths},
          {"forbidden_paths", :forbidden_paths},
          {"migration_paths", :migration_paths}
        ],
        value = settings[key],
        is_list(value),
        do: {policy_key, value}
  end
end
