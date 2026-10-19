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

# Re-run only previously failed tests
test-failed:
    mix test --failed

# Format code
format:
    mix format

# Full pre-commit check: warnings-as-errors, unused deps, format, credo, tests,
# and a guard that the committed coturn state is encrypted
precommit: check-state-encrypted
    mix precommit

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
