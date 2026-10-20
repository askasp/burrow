# Peon's own configuration, for its tests. As a dependency of Burrow it is
# configured by Burrow (see burrow/config), which also hosts the instances.
import Config

config :peon,
  ecto_repos: [Peon.Repo],
  generators: [timestamp_type: :utc_datetime]

config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

import_config "#{config_env()}.exs"
