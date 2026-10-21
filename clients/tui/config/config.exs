import Config

# Where the TUI connects, and where it logs (the screen is the terminal, so
# logs go to a file). `mix tui` (dev) talks to the local dev server; an
# installed release (prod) talks to randos.slowinput.org and logs under the
# user's cache directory. `--url` / RANDOS_URL override the URL either way.
config :tui,
  default_url: "ws://localhost:4000/participant/websocket",
  log_path: "tmp/tui.log"

if config_env() == :prod do
  config :tui,
    default_url: "wss://randos.slowinput.org/participant/websocket",
    log_path: {:user_cache, "randos/tui.log"}
end
