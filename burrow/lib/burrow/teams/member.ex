defmodule Burrow.Teams.Member do
  use Ecto.Schema

  @roles ~w(owner member)

  schema "team_members" do
    field :role, :string, default: "member"
    belongs_to :team, Burrow.Teams.Team
    belongs_to :user, Burrow.Accounts.User
    timestamps(type: :utc_datetime)
  end

  def roles, do: @roles
end
