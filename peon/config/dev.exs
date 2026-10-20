import Config

# For `mix ecto.*` against a scratch database.
config :peon, Peon.Repo, database: Path.expand("../peon_dev.db", __DIR__)
