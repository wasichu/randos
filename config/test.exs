import Config
config :ash, policies: [show_policy_breakdowns?: true]

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :randos, RandosWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "Ap0o8H3b3y/kyAMluMWs4Apm9rrzqwwthtRgaMu3S3Md8GRhqdgBKLzyZha9IMt8",
  server: false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true
