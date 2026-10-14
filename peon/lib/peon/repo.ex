defmodule Peon.Repo do
  use Ecto.Repo,
    otp_app: :peon,
    adapter: Ecto.Adapters.SQLite3
end
