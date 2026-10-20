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
#     PHX_SERVER=true bin/burrow start
#
# Alternatively, you can use `mix phx.gen.release` to generate a `bin/server`
# script that automatically sets the env var above.
root = Path.expand("../..", __DIR__)

# Local secrets (OPENAI_API_KEY, BURROW_LLM_MODEL, ...) live in the repo's
# gitignored .env file. Real environment variables win.
if config_env() == :dev and File.exists?(Path.join(root, ".env")) do
  root
  |> Path.join(".env")
  |> File.read!()
  |> String.split("\n", trim: true)
  |> Enum.reject(&String.starts_with?(&1, "#"))
  |> Enum.each(fn line ->
    case String.split(line, "=", parts: 2) do
      [key, value] ->
        System.get_env(String.trim(key)) || System.put_env(String.trim(key), String.trim(value))

      _ ->
        :ok
    end
  end)
end

if config_env() != :test do
  burrow_port = System.get_env("PORT", "4000")

  opencode_bin = System.get_env("BURROW_OPENCODE_BIN") || System.find_executable("opencode")

  config :burrow,
    data_dir: System.get_env("BURROW_DATA_DIR") || Path.join(root, "data/burrow"),
    # opencode runs every user's agents with the user's own AI logins.
    opencode_bin: opencode_bin,
    opencode_model: System.get_env("BURROW_OPENCODE_MODEL", "openai/gpt-6-sol"),
    # Local mode: let users copy this computer's opencode logins. Never by
    # default once Burrow is public: anyone who signs up could use them.
    local_login_import:
      System.get_env(
        "BURROW_LOCAL_LOGIN_IMPORT",
        to_string(config_env() == :dev and is_nil(System.get_env("BURROW_PUBLIC_URL")))
      ) == "true"

  # Each project's Peon, run inside Burrow (`Burrow.Cell`, `Peon.Instance`).
  config :peon,
    template_dir: System.get_env("BURROW_TEMPLATE_DIR") || Path.join(root, "template"),
    sandbox_image: System.get_env("PEON_SANDBOX_IMAGE", "burrow/elixir-dev:1"),
    # Where a browser reaches a preview's or an environment's port: its own
    # address behind a tunnel (e.g. https://peon-{port}.example.com), or the
    # port on BURROW_PEON_HOST
    port_url:
      System.get_env("BURROW_PORT_URL") ||
        "http://#{System.get_env("BURROW_PEON_HOST", "localhost")}:{port}",
    opencode_bin: opencode_bin || "opencode",
    check_slots: String.to_integer(System.get_env("PEON_CHECK_SLOTS", "2")),
    # Chats running at once per project (agent and preview)
    max_running_chats: String.to_integer(System.get_env("PEON_MAX_RUNNING_CHATS", "4")),
    health_window: :timer.seconds(String.to_integer(System.get_env("PEON_HEALTH_WINDOW", "60"))),
    # The workspace (Burrow's own site) may show previews in a frame.
    frame_ancestors: [System.get_env("BURROW_PUBLIC_URL") || "http://localhost:#{burrow_port}"]
end

if System.get_env("PHX_SERVER") do
  config :burrow, BurrowWeb.Endpoint, server: true
end

config :burrow, BurrowWeb.Endpoint,
  http: [port: String.to_integer(System.get_env("PORT", "4000"))]

# Burrow's own public address behind a tunnel, e.g. https://burrow.example.com
if public = System.get_env("BURROW_PUBLIC_URL") do
  %URI{host: host, port: port, scheme: scheme} = URI.parse(public)
  config :burrow, BurrowWeb.Endpoint, url: [host: host, port: port, scheme: scheme]
end

if config_env() == :dev do
  # Reload browser tabs when matching files change.
  config :burrow, BurrowWeb.Endpoint,
    live_reload: [
      web_console_logger: true,
      patterns: [
        # Static assets, except user uploads
        ~r"priv/static/(?!uploads/).*\.(js|css|png|jpeg|jpg|gif|svg)$",
        # Router, Controllers, LiveViews and LiveComponents
        ~r"lib/burrow_web/router\.ex$",
        ~r"lib/burrow_web/(controllers|live|components)/.*\.(ex|heex)$"
      ]
    ]
end

if config_env() == :prod do
  database_path =
    System.get_env("DATABASE_PATH") ||
      raise """
      environment variable DATABASE_PATH is missing.
      For example: /etc/burrow/burrow.db
      """

  config :burrow, Burrow.Repo,
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

  config :burrow, :dns_cluster_query, System.get_env("DNS_CLUSTER_QUERY")

  config :burrow, BurrowWeb.Endpoint,
    url: [host: host, port: 443, scheme: "https"],
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
  #     config :burrow, BurrowWeb.Endpoint,
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
  #     config :burrow, BurrowWeb.Endpoint,
  #       force_ssl: [hsts: true]
  #
  # Check `Plug.SSL` for all available options in `force_ssl`.

  # ## Configuring the mailer
  #
  # In production you need to configure the mailer to use a different adapter.
  # Here is an example configuration for Mailgun:
  #
  #     config :burrow, Burrow.Mailer,
  #       adapter: Swoosh.Adapters.Mailgun,
  #       api_key: System.get_env("MAILGUN_API_KEY"),
  #       domain: System.get_env("MAILGUN_DOMAIN")
  #
  # Most non-SMTP adapters require an API client. Swoosh supports Req, Hackney,
  # and Finch out-of-the-box. This configuration is typically done at
  # compile-time in your config/prod.exs:
  #
  #     config :swoosh, :api_client, Swoosh.ApiClient.Req
  #
  # See https://swoosh.hexdocs.pm/Swoosh.html#module-installation for details.
end
