# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :randos, generators: [timestamp_type: :utc_datetime]

config :randos, RandosWeb.IceServers,
  servers: [
    %{urls: "stun:stun.l.google.com:19302"}
  ],
  future_env: [
    turn_host: "TURN_HOST",
    turn_stun_url: "TURN_STUN_URL",
    turn_server_url: "TURN_SERVER_URL",
    turns_server_url: "TURNS_SERVER_URL",
    turn_shared_secret: "TURN_SHARED_SECRET",
    turn_realm: "TURN_REALM",
    turn_credential_ttl_seconds: "TURN_CREDENTIAL_TTL_SECONDS"
  ]

# Configures the endpoint
config :randos, RandosWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: RandosWeb.ErrorHTML, json: RandosWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Randos.PubSub,
  live_view: [signing_salt: "OFeKGiNl"]

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.28.2",
  randos: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.3",
  randos: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__)
  ]

# Configures Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
