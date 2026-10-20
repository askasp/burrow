import Config

config :peon, Peon.Repo,
  database: Path.expand("../peon_test.db", __DIR__),
  pool_size: 5,
  pool: Ecto.Adapters.SQL.Sandbox

config :logger, level: :warning

# One instance on Peon.Repo, in the SQL sandbox (`Peon.DataCase`); no
# workers touching Docker.
config :peon,
  test_repo: true,
  start_workers: false,
  fix_retries: 0,
  port_url: "http://localhost:{port}"
