import Config

# Where the TUI connects, where it logs (the screen is the terminal, so
# logs go to a file), and where it keeps its settings (`Tui.Config`).
# `mix tui` (dev) talks to the local dev server and keeps both files in
# tmp/; an installed release (prod) talks to randos.slowinput.org and uses
# the user's cache and config directories. `--url` / RANDOS_URL override the
# URL either way. Tests never read or write a settings file.
config :tui,
  default_url: "ws://localhost:4000/participant/websocket",
  log_path: "tmp/tui.log",
  config_path: "tmp/tui-config.json"

if config_env() == :prod do
  config :tui,
    default_url: "wss://randos.slowinput.org/participant/websocket",
    log_path: {:user_cache, "randos/tui.log"},
    config_path: {:user_config, "randos/config.json"}
end

if config_env() == :test do
  config :tui, config_path: nil
end
