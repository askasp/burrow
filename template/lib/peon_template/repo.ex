defmodule PeonTemplate.Repo do
  use Ecto.Repo,
    otp_app: :peon_template,
    adapter: Ecto.Adapters.SQLite3
end
