import Config

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :peon, Peon.Repo,
  database: Path.expand("../peon_test.db", __DIR__),
  pool_size: 5,
  pool: Ecto.Adapters.SQL.Sandbox

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :peon, PeonWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "Spas5FkI7eAMG9EZqP9wY+UedqUKdrGAT3c/JAV8MCkfDw1+Fdztnj0UxTeD8uZz",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true

config :peon,
  start_workers: false,
  preview_ports: [],
  fix_retries: 0,
  port_url: "http://localhost:{port}"

# Burrow's API (Peon.Burrow) answers from a stub in tests.
config :peon, burrow_req: [plug: {Req.Test, Peon.Burrow}]
