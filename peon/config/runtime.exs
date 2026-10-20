import Config

# config/runtime.exs is executed for all environments, including
# during releases. It is executed after compilation and before the
# system starts, so it is typically used to load production configuration
# and secrets from environment variables or elsewhere. Do not define
# any compile-time configuration in here, as it won't be applied.
# The block below contains prod specific runtime configuration.

# ## Using releases
#
# If you use `mix release`, you need to explicitly enable the server
# by passing the PHX_SERVER=true when you start it:
#
#     PHX_SERVER=true bin/peon start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
if System.get_env("PHX_SERVER") do
  config :peon, PeonWeb.Endpoint, server: true
end

config :peon, PeonWeb.Endpoint, http: [port: String.to_integer(System.get_env("PORT", "4000"))]

# This Peon's project, sandbox and LLM. Burrow sets these when it starts a
# Peon; the dev defaults let `mix phx.server` run one Peon standalone.
if config_env() != :test do
  root = Path.expand("../..", __DIR__)

  ports =
    case String.split(System.get_env("PEON_PREVIEW_PORTS", "4200-4209"), "-") do
      [first, last] -> String.to_integer(first)..String.to_integer(last)
    end

  # Environments that run the app for real; each gets a host port.
  env_ports =
    for {name, var, default} <- [
          {"staging", "PEON_STAGING_PORT", "4210"},
          {"prod", "PEON_PROD_PORT", "4211"}
        ],
        port = System.get_env(var, default),
        port != "",
        into: %{},
        do: {name, String.to_integer(port)}

  data_dir = System.get_env("PEON_DATA_DIR") || Path.join(root, "data/peon-dev")
  File.mkdir_p!(data_dir)

  config :peon, Peon.Repo,
    database: System.get_env("DATABASE_PATH") || Path.join(data_dir, "peon.db")

  config :peon,
    data_dir: data_dir,
    project_slug: System.get_env("PEON_PROJECT_SLUG", "sauna_booking"),
    project_name: System.get_env("PEON_PROJECT_NAME", "Sauna Booking"),
    template_dir: System.get_env("PEON_TEMPLATE_DIR") || Path.join(root, "template"),
    preview_ports: ports,
    env_ports: env_ports,
    check_slots: String.to_integer(System.get_env("PEON_CHECK_SLOTS", "2")),
    # Chats running at once (agent and preview), at most one per chat tab;
    # see Peon.Chat and Peon.Chats.max/0
    max_running_chats: String.to_integer(System.get_env("PEON_MAX_RUNNING_CHATS", "4")),
    health_window: :timer.seconds(String.to_integer(System.get_env("PEON_HEALTH_WINDOW", "60"))),
    # Where a browser reaches a preview or env port (see Peon.Ports.url/1)
    port_url:
      System.get_env("PEON_PORT_URL") ||
        "http://#{System.get_env("PEON_PREVIEW_HOST", "localhost")}:{port}",
    # Burrow's address, for the workspace's link back to the project list
    burrow_url: System.get_env("PEON_BURROW_URL"),
    # Burrow's API for this Peon (Peon.Burrow), and the token both ways
    # between Burrow and this Peon
    burrow_api: System.get_env("PEON_BURROW_API"),
    api_token: System.get_env("PEON_API_TOKEN"),
    # What a new project starts as: "live" (main is live) or "pipeline"
    envs: System.get_env("PEON_ENVS", "pipeline"),
    # The login a new app starts with: "accounts", "basic" or "open" (see
    # Peon.Template). For "basic", Peon.Bootstrap itself reads the username and
    # password from PEON_BASIC_AUTH_USERNAME/_PASSWORD, so they stay out of config.
    auth: System.get_env("PEON_AUTH", "accounts"),
    sandbox_image: System.get_env("PEON_SANDBOX_IMAGE", "burrow/elixir-dev:1"),
    # An existing git repo to work on instead of the template (Peon.Source)
    repo:
      (case System.get_env("PEON_REPO_URL", "") do
         "" -> nil
         url -> %{url: url, branch: System.get_env("PEON_REPO_BRANCH", "main")}
       end),
    sso_secret: System.get_env("PEON_SSO_SECRET"),
    # The agent: opencode, run per chat in the sandbox with the user's login.
    opencode: [
      bin: System.get_env("PEON_OPENCODE_BIN", "opencode"),
      model: System.get_env("PEON_OPENCODE_MODEL", "openai/gpt-6-sol"),
      data_dir: System.get_env("PEON_OPENCODE_DATA_DIR") || Path.join(data_dir, "opencode-data")
    ]
end

if config_env() == :dev do
  # Reload browser tabs when matching files change.
  config :peon, PeonWeb.Endpoint,
    live_reload: [
      web_console_logger: true,
      patterns: [
        # Static assets, except user uploads
        ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$",
        # Router, Controllers, LiveViews and LiveComponents
        ~r"lib/peon_web/router\.ex$",
        ~r"lib/peon_web/(controllers|live|components)/.*\.(ex|heex)$"
      ]
    ]
end

if config_env() == :prod do
  database_path =
    System.get_env("DATABASE_PATH") ||
      raise """
      environment variable DATABASE_PATH is missing.
      For example: /etc/peon/peon.db
      """

  config :peon, Peon.Repo,
    database: database_path,
    pool_size: String.to_integer(System.get_env("POOL_SIZE") || "5")

  # The secret key base is used to sign/encrypt cookies and other secrets.
  # A default value is used in config/dev.exs and config/test.exs but you
  # want to use a different value for prod and you most likely don't want
  # to check this value into version control, so we use an environment
  # variable instead.
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "example.com"

  config :peon, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :peon, PeonWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
    # Its public host, and localhost for scripts on this machine
    check_origin: ["//#{host}", "//localhost", "//127.0.0.1"],
    http: [
      # Enable IPv6 and bind on all interfaces.
      # Set it to  {0, 0, 0, 0, 0, 0, 0, 1} for local network only access.
      # See the documentation on https://bandit.hexdocs.pm/Bandit.html#t:options/0
      # for details about using IPv6 vs IPv4 and loopback vs public addresses.
      ip: {0, 0, 0, 0, 0, 0, 0, 0}
    ],
    secret_key_base: secret_key_base

  # ## SSL Support
  #
  # To get SSL working, you will need to add the `https` key
  # to your endpoint configuration:
  #
  #     config :peon, PeonWeb.Endpoint,
  #       https: [
  #         ...,
  #         port: 443,
  #         cipher_suite: :strong,
  #         keyfile: System.get_env("SOME_APP_SSL_KEY_PATH"),
  #         certfile: System.get_env("SOME_APP_SSL_CERT_PATH")
  #       ]
  #
  # The `cipher_suite` is set to `:strong` to support only the
  # latest and more secure SSL ciphers. This means old browsers
  # and clients may not be supported. You can set it to
  # `:compatible` for wider support.
  #
  # `:keyfile` and `:certfile` expect an absolute path to the key
  # and cert in disk or a relative path inside priv, for example
  # "priv/ssl/server.key". For all supported SSL configuration
  # options, see https://plug.hexdocs.pm/Plug.SSL.html#configure/1
  #
  # We also recommend setting `force_ssl` in your config/prod.exs,
  # ensuring no data is ever sent via http, always redirecting to https:
  #
  #     config :peon, PeonWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.
end
