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
    TURN_SHARED_SECRET="$(terraform -chdir=infra/coturn output -raw turn_shared_secret)" \
    TURN_CREDENTIAL_TTL_SECONDS="900" \
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

# Re-run only previously failed tests
test-failed:
    mix test --failed

# Format code
format:
    mix format

# Full pre-commit check: warnings-as-errors, unused deps, format, tests
precommit:
    mix precommit

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

# Build the release Docker image locally
docker-build:
    docker build -t randos .

# Deploy to Fly.io
deploy:
    fly deploy
