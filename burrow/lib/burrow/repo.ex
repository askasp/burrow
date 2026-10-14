defmodule Burrow.Repo do
  use Ecto.Repo,
    otp_app: :burrow,
    adapter: Ecto.Adapters.SQLite3
end
