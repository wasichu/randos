# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :randos, generators: [timestamp_type: :utc_datetime]

# This deployment's source (AGPL: a modified copy offers its own). The
# footer, the About page and the translations' "Suggest a fix" link here.
config :randos, source_url: "https://github.com/wasichu/randos"

config :randos, RandosWeb.IceServers,
  servers: [
    %{urls: "stun:stun.l.google.com:19302"}
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
  # app.js, plus one entry per voice-processor worklet (browsers load each
  # AudioWorklet module by its own URL); the worklets embed the voice
  # processors' .wasm (binary loader).
  randos: [
    args:
      ~w(js/app.js js/randos/voice/passthrough.js js/randos/voice/pitch_shift.js --bundle --target=es2022 --outdir=../priv/static/assets/js --loader:.wasm=binary --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ],
  # The voice lab's page script: dev only (its watcher is in config/dev.exs;
  # `mix assets.deploy` never builds it).
  voice_lab: [
    args:
      ~w(js/voice_lab/lab.js --bundle --target=es2022 --outfile=../priv/static/assets/js/voice_lab.js),
    cd: Path.expand("../assets", __DIR__)
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

# Parameters Phoenix's request, socket and channel logs show as [FILTERED].
# A resume ticket (Randos.Calls.ResumeTicket) arrives in LiveView connect
# params and channel join params, and must never be logged (docs/privacy.md).
config :phoenix, :filter_parameters, ["password", "resume_ticket"]

# Configures Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id, :call_id, :match_id, :status, :reason, :result, :media]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
