import Config

# Tests don't ask for the site's password (PeonTemplate.SiteAccess), so
# switching modes doesn't break them; SiteAccessTest turns it on. No pause
# after a wrong password.
config :peon_template, enforce_site_password: false, unlock_delay: 0

# peon:if-accounts
# Only in tests, remove the complexity from the password hashing algorithm
config :bcrypt_elixir, :log_rounds, 1

# peon:end

# Configure your database
#
# The MIX_TEST_PARTITION environment variable can be used
# to provide built-in test partitioning in CI environment.
# Run `mix help test` for more information.
config :peon_template, PeonTemplate.Repo,
  database: Path.expand("../peon_template_test.db", __DIR__),
  pool_size: 5,
  pool: Ecto.Adapters.SQL.Sandbox

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :peon_template, PeonTemplateWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "fZz6rrTHHUQY/1iHdZazna18P62PmLmf7jCnPyl0Snq6Dyqj8mN5DX3ZuMw0e1Kp",
  server: false

# In test we don't send emails
config :peon_template, PeonTemplate.Mailer, adapter: Swoosh.Adapters.Test

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

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
