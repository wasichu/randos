import Config
config :ash, policies: [show_policy_breakdowns?: true]

dev_ssl_keyfile = System.get_env("DEV_SSL_KEYFILE") || "priv/cert/randos_dev_key.pem"
dev_ssl_certfile = System.get_env("DEV_SSL_CERTFILE") || "priv/cert/randos_dev.pem"

dev_https =
  if File.exists?(dev_ssl_keyfile) and File.exists?(dev_ssl_certfile) do
    [
      https: [
        ip: {0, 0, 0, 0},
        port: String.to_integer(System.get_env("HTTPS_PORT") || "4001"),
        cipher_suite: :strong,
        keyfile: dev_ssl_keyfile,
        certfile: dev_ssl_certfile
      ]
    ]
  else
    []
  end

# For development, we disable any cache and enable
# debugging and code reloading.
#
# The watchers configuration can be used to run external
# watchers to your application. For example, we can use it
# to bundle .js and .css sources.
# Binding to 0.0.0.0 allows local-network device testing.
endpoint_config =
  [
    http: [ip: {0, 0, 0, 0}, port: String.to_integer(System.get_env("PORT") || "4000")]
  ] ++
    dev_https ++
    [
      check_origin: false,
      code_reloader: true,
      debug_errors: true,
      secret_key_base: "+Xvc0PMd7VulpdSDU1JZLuo+/41ABUVJkfOsWkIMRABkEICKjE4uV02TeU6+I2iO",
      watchers: [
        esbuild: {Esbuild, :install_and_run, [:randos, ~w(--sourcemap=inline --watch)]},
        tailwind: {Tailwind, :install_and_run, [:randos, ~w(--watch)]}
      ]
    ]

config :randos, RandosWeb.Endpoint, endpoint_config

# Watch static and templates for browser reloading.
config :randos, RandosWeb.Endpoint,
  live_reload: [
    web_console_logger: true,
    patterns: [
      ~r"priv/static/(?!uploads/).*(js|css|png|jpeg|jpg|gif|svg)$",
      ~r"priv/gettext/.*(po)$",
      ~r"lib/randos_web/(?:controllers|live|components|router)/?.*\.(ex|heex)$"
    ]
  ]

# Enable dev routes for dashboard and mailbox
config :randos, dev_routes: true

# Do not include metadata nor timestamps in development logs
config :logger, :default_formatter, format: "[$level] $message\n"

# Set a higher stacktrace during development. Avoid configuring such
# in production as building large stacktraces may be expensive.
config :phoenix, :stacktrace_depth, 20

# Initialize plugs at runtime for faster development compilation
config :phoenix, :plug_init_mode, :runtime

config :phoenix_live_view,
  # Include debug annotations and locations in rendered markup.
  # Changing this configuration will require mix clean and a full recompile.
  debug_heex_annotations: true,
  debug_attributes: true,
  # Enable helpful, but potentially expensive runtime checks
  enable_expensive_runtime_checks: true
