# Common commands for Randos. Toolchain versions are pinned in mise.toml.
# Recipes are thin wrappers around mix aliases (see mix.exs) — keep logic there.

set dotenv-load := false

# List available recipes
default:
    @just --list

# Install the pinned toolchain, fetch deps, and build assets
setup:
    mise install
    mix setup

# Run the dev server (HTTP :4000, HTTPS :4001 when certs exist)
dev: _free-dev-port
    iex -S mix phx.server

# Stops a background dev server (`just serve`, run by the session hook) so an
# interactive one can take :4000. An interactive server (IEx, e.g. another
# `just dev`) is never stopped: that's an error instead.
_free-dev-port:
    #!/usr/bin/env bash
    set -euo pipefail
    port="${PORT:-4000}"
    for pid in $(lsof -t -nP -iTCP:"${port}" -sTCP:LISTEN || true); do
      cmd=$(ps -o command= -p "$pid")
      if [[ $cmd == *beam.smp* && $cmd == *-noshell* ]]; then
        kill "$pid"
        while kill -0 "$pid" 2>/dev/null; do sleep 0.2; done
        echo "stopped the background dev server on :${port} (pid ${pid})"
      else
        echo "error: :${port} is taken by pid ${pid}, not a background dev server (an IEx session?); stop it first" >&2
        exit 1
      fi
    done

# Reuses a running server: if something already answers on $PORT (default
# 4000), it says so and exits instead of starting a second one.
# Dev server without IEx, for the background (Tidewave, the TUI, tests)
serve:
    #!/usr/bin/env bash
    set -euo pipefail
    port="${PORT:-4000}"
    if curl -s -o /dev/null --max-time 2 "http://localhost:${port}/"; then
      echo "dev server already running on :${port}; reusing it"
      exit 0
    fi
    exec mix phx.server

# e.g. the one the SessionStart hook starts for Tidewave. Only stops a BEAM,
# never something else on the port.
# Stop the dev server on $PORT (default 4000)
serve-stop:
    #!/usr/bin/env bash
    set -euo pipefail
    port="${PORT:-4000}"
    pids=$(lsof -t -nP -iTCP:"${port}" -sTCP:LISTEN || true)
    if [ -z "$pids" ]; then echo "nothing is serving :${port}"; exit 0; fi
    for pid in $pids; do
      if ps -o command= -p "$pid" | grep -q beam.smp; then
        kill "$pid" && echo "stopped the dev server on :${port} (pid ${pid})"
      else
        echo "leaving pid ${pid} on :${port} alone: it isn't a BEAM" >&2
      fi
    done

# Run the dev server against the coturn TURN server managed by infra/coturn
# (the shared secret comes from the encrypted state via `just tofu`, so the
# Keychain passphrase is used and the secret is never printed)
dev-turn: _free-dev-port
    TURN_HOST="turn.slowinput.org" \
    TURN_REALM="turn.slowinput.org" \
    TURN_SHARED_SECRET="$(just tofu output -raw turn_shared_secret)" \
    TURN_CREDENTIAL_TTL_SECONDS="3600" \
    iex -S mix phx.server

# Generate local HTTPS certs with mkcert (for mic/WebRTC testing)
certs:
    # Trusting the CA on this Mac needs sudo (a real terminal). Other devices
    # never trust it anyway (they click through a warning), so it's optional.
    mkcert -install || echo "warning: CA not trusted on this machine (run 'mkcert -install' in a terminal); generating the certificates anyway" >&2
    mkdir -p priv/cert
    mkcert \
      -key-file priv/cert/randos_dev_key.pem \
      -cert-file priv/cert/randos_dev.pem \
      localhost 127.0.0.1 ::1 "$(hostname)" randos.local

# Dev server plus a terminal dashboard of queues, calls, and events (q quits)
top:
    mix randos.top

# Run tests (pass args through, e.g. `just test test/randos/signaling_test.exs`)
test *args:
    mix test {{args}}

# Browser smoke test: two headless Chromes place a real WebRTC call (needs Chrome)
smoke:
    test/e2e/with_test_server.sh tmp/smoke-server.log env BASE_URL=http://localhost:4010 node test/e2e/call_smoke.mjs

# Terminal client (text-only) against the local dev server; RANDOS_URL or --url to override
tui *args:
    cd clients/tui && mix tui {{args}}

# Through a throwaway server with 8s segments: two real TUI clients call each other,
# and a TUI (helper with a test tone) calls headless Chrome in both roles (needs the
# helper built, node, and Chrome)
tui-smoke:
    test/e2e/with_test_server.sh tmp/tui-smoke-server.log sh -c 'cd clients/tui && RANDOS_URL=ws://localhost:4010/participant/websocket mix test --only integration'

# Run the TUI client's tests (pass args through)
test-tui *args:
    cd clients/tui && mix test {{args}}

# Re-run only previously failed tests
test-failed:
    mix test --failed

# Format code
format:
    mix format

# Full pre-commit check: server, clients/tui, the Rust helper, and the encrypted-state guard
precommit: check-state-encrypted
    mix precommit
    just native-check
    cargo build --quiet -p randos_media
    cd clients/tui && mix precommit

# Media helper loopback: default mic → Opus → default speaker; latency on stderr (use headphones)
media-loopback seconds="20":
    cargo run --quiet -p randos_media -- --loopback --seconds {{seconds}}

# Rust media helper checks: format, clippy (warnings are errors), tests, cargo-deny
native-check:
    cd clients/tui/native && cargo fmt --check && cargo clippy --all-targets -- -D warnings && cargo test --quiet && cargo deny --log-level error check --hide-inclusion-graph

# The helper against the real coturn: allocations, relayed data, and a whole
# relay-only call. Derives short-lived TURN REST credentials from the shared
# secret (via `just tofu`, so the Keychain passphrase) without printing it
turn-check:
    #!/usr/bin/env bash
    set -euo pipefail
    secret="$(just tofu output -raw turn_shared_secret 2>/dev/null)" \
      || { echo "could not read the TURN secret (just tofu)" >&2; exit 1; }
    export TURN_TEST_USERNAME="$(( $(date +%s) + 600 ))"
    export TURN_TEST_CREDENTIAL="$(printf %s "$TURN_TEST_USERNAME" | openssl dgst -sha1 -hmac "$secret" -binary | base64)"
    unset secret
    cd clients/tui/native && cargo test --quiet -- --ignored production_turn

# Refuse a plaintext infra/coturn/terraform.tfstate (it holds the TURN secret)
check-state-encrypted:
    #!/usr/bin/env bash
    set -euo pipefail
    state=infra/coturn/terraform.tfstate
    if [ -f "$state" ] && ! grep -q '"encrypted_data"' "$state"; then
      echo "ERROR: $state is not encrypted; do not commit it" >&2
      exit 1
    fi

# Build dev assets
assets:
    mix assets.build

# Show outdated hex dependencies
outdated:
    mix hex.outdated

# Update all deps within mix.exs constraints, then regenerate the AGENTS.md rules block + skills
update:
    mix deps.update --all
    mix usage_rules.sync --yes

# Refresh the graft context graph after big changes
graft:
    graft build

# OpenTofu for coturn (`just tofu plan`); passphrase from Keychain, DO token from doctl
tofu *args:
    #!/usr/bin/env bash
    set -euo pipefail
    if [ -z "${TF_VAR_state_passphrase:-}" ]; then
      TF_VAR_state_passphrase="$(security find-generic-password -s randos-tofu-state-passphrase -w)" \
        || { echo "No Keychain item randos-tofu-state-passphrase (see infra/coturn/README.md)" >&2; exit 1; }
    fi
    export TF_VAR_state_passphrase
    export TF_VAR_do_token="${TF_VAR_do_token:-$(doctl auth token --context "${DO_CONTEXT:-default}")}"
    cd infra/coturn && tofu {{args}}

# Build the release Docker image locally
docker-build:
    docker build -t randos .

# Deploy to Fly.io
deploy:
    fly deploy
