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
dev:
    iex -S mix phx.server

# Dev server without IEx (for background use: Tidewave, the TUI, tests).
# Reuses a running server: if something already answers on $PORT (default
# 4000), it says so and exits instead of starting a second one.
serve:
    #!/usr/bin/env bash
    set -euo pipefail
    port="${PORT:-4000}"
    if curl -s -o /dev/null --max-time 2 "http://localhost:${port}/"; then
      echo "dev server already running on :${port}; reusing it"
      exit 0
    fi
    exec mix phx.server

# Run the dev server against the coturn TURN server managed by infra/coturn
dev-turn:
    TURN_HOST="turn.slowinput.org" \
    TURN_REALM="turn.slowinput.org" \
    TURN_SHARED_SECRET="$(tofu -chdir=infra/coturn output -raw turn_shared_secret)" \
    TURN_CREDENTIAL_TTL_SECONDS="3600" \
    iex -S mix phx.server

# Generate local HTTPS certs with mkcert (for mic/WebRTC testing)
certs:
    mkcert -install
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
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p tmp
    PORT=4010 HTTPS_PORT=4011 RANDOS_CALL_SEGMENT_MS=8000 mix phx.server > tmp/smoke-server.log 2>&1 &
    server=$!
    trap 'kill $server 2>/dev/null; wait $server 2>/dev/null || true' EXIT
    for _ in $(seq 1 60); do curl -sf -o /dev/null http://localhost:4010/ && break; sleep 1; done
    BASE_URL=http://localhost:4010 node test/e2e/call_smoke.mjs

# Terminal client (text-only) against the local dev server; RANDOS_URL or --url to override
tui *args:
    cd clients/tui && mix tui {{args}}

# Two real TUI clients call each other through a throwaway server with 8s segments
tui-smoke:
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p tmp
    PORT=4010 HTTPS_PORT=4011 RANDOS_CALL_SEGMENT_MS=8000 mix phx.server > tmp/tui-smoke-server.log 2>&1 &
    server=$!
    trap 'kill $server 2>/dev/null; wait $server 2>/dev/null || true' EXIT
    for _ in $(seq 1 60); do curl -sf -o /dev/null http://localhost:4010/ && break; sleep 1; done
    cd clients/tui && RANDOS_URL=ws://localhost:4010/participant/websocket mix test --only integration

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
