# Common commands for Randos. Toolchain versions are pinned in mise.toml.
# Recipes are thin wrappers around mix aliases (see mix.exs) — keep logic there.

set dotenv-load := false

# List available recipes
default:
    @just --list

# Install the pinned toolchain, fetch deps, and build assets
setup:
    mise install
    mix deps.get
    cd clients/tui && mix deps.get
    just prefetch
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
      # IEx runs with -noshell too; it's told apart by its +iex flag.
      if [[ $cmd == *beam.smp* && $cmd == *-noshell* && $cmd != *+iex* ]]; then
        kill "$pid"
        while kill -0 "$pid" 2>/dev/null; do sleep 0.2; done
        echo "stopped the background dev server on :${port} (pid ${pid})"
      else
        echo "error: :${port} is taken by pid ${pid}, not a background dev server (an IEx session?); stop it first" >&2
        exit 1
      fi
    done
    # HTTPS (only with `just certs`): nothing of ours to stop there, so just
    # say who has it and how to pick another port.
    https_port="${HTTPS_PORT:-4001}"
    if ls priv/cert/*.pem >/dev/null 2>&1; then
      pid=$(lsof -t -nP -iTCP:"${https_port}" -sTCP:LISTEN | head -1 || true)
      if [ -n "$pid" ]; then
        echo "error: HTTPS port :${https_port} is taken by pid ${pid} ($(ps -o comm= -p "$pid" | xargs basename)); pick another, e.g. HTTPS_PORT=4443 just dev-turn" >&2
        exit 1
      fi
    fi

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
    # HTTP only: Tidewave and the TUI need nothing more, and it can't clash
    # with whatever holds the HTTPS port (`just dev` / `dev-turn` serve HTTPS).
    RANDOS_DEV_HTTPS=false exec mix phx.server

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
    test/e2e/with_test_server.sh tmp/smoke-server.log env BASE_URL=http://localhost:4010 SMOKE_SERVER_LOG=tmp/smoke-server.log node test/e2e/call_smoke.mjs
    RANDOS_TEST_UNREACHABLE_RELAY=1 test/e2e/with_test_server.sh tmp/smoke-relay-server.log env BASE_URL=http://localhost:4010 node test/e2e/relay_only_smoke.mjs
    test/e2e/with_test_server.sh tmp/smoke-voice-lab-server.log env BASE_URL=http://localhost:4010 node test/e2e/voice_lab_smoke.mjs
    just recovery-smoke

# A call whose media path dies comes back (ICE restart, obligation 10):
# two Chromes, relay-only through the test TURN relay, which cuts them.
recovery-smoke: test-turn
    node test/e2e/recovery_smoke.mjs

# Terminal client (text-only) against the local dev server; RANDOS_URL or --url to override
tui *args:
    cd clients/tui && mix tui {{args}}

# Through a throwaway server with 8s segments: two real TUI clients call each other,
# and a TUI (helper with a test tone) calls headless Chrome in both roles (needs the
# helper built, node, and Chrome)
tui-smoke: test-turn
    test/e2e/with_test_server.sh tmp/tui-smoke-server.log sh -c 'cd clients/tui && RANDOS_URL=ws://localhost:4010/participant/websocket mix test --only integration'
    RANDOS_TEST_UNREACHABLE_RELAY=1 test/e2e/with_test_server.sh tmp/tui-smoke-relay-server.log sh -c 'cd clients/tui && RANDOS_URL=ws://localhost:4010/participant/websocket mix test --only relay_only'
    # Recovery (ICE restart): the tests start the test relay and their own server.
    cd clients/tui && RANDOS_URL=ws://localhost:4010/participant/websocket mix test --only recovery

# Run the TUI client's tests (pass args through)
test-tui *args:
    cd clients/tui && mix test {{args}}

# Re-run only previously failed tests
test-failed:
    mix test --failed

# Format code
format:
    mix format

# Full pre-commit check: server, clients/tui, the Rust crates, the Python harnesses' offline tests, and the guards
precommit: check-state-encrypted check-privacy
    mix precommit
    just native-check
    cargo build --quiet -p randos_media
    cd clients/tui && mix precommit
    just translate-test
    just voice-eval-test

# Media helper loopback: default mic → Opus → default speaker; latency on stderr (use headphones)
media-loopback seconds="20":
    cargo run --quiet -p randos_media -- --loopback --seconds {{seconds}}

# The test TURN relay that can cut a client's media path (ICE restart
# tests): target/debug/examples/test_turn (docs/architecture/ice_restart.md)
test-turn:
    cd clients/tui/native && cargo build --example test_turn

# Every crate in the workspace uses the shared lints (root Cargo.toml's
# [workspace.lints]), so none is checked less strictly than another.
rust-lints-check:
    #!/usr/bin/env bash
    set -euo pipefail
    status=0
    manifests=$(cargo metadata --format-version 1 --no-deps | python3 -c 'import json,sys; [print(p["manifest_path"]) for p in json.load(sys.stdin)["packages"]]')
    for manifest in $manifests; do
      if ! awk '/^\[lints\]/{f=1;next} /^\[/{f=0} f && /^workspace *= *true/{ok=1} END{exit !ok}' "$manifest"; then
        echo "error: ${manifest#$PWD/} doesn't use the workspace lints ([lints] workspace = true)" >&2
        status=1
      fi
    done
    exit $status

# Rust checks: the media helper and the voice processors (format, clippy with
# warnings as errors, tests, cargo-deny), and that the committed .wasm is
# the voice processors' current build
native-check: rust-lints-check voice-wasm-check
    cd clients/tui/native && cargo fmt --check && cargo clippy --all-targets -- -D warnings && cargo test --quiet && cargo deny --log-level error check --hide-inclusion-graph
    cd voice && cargo fmt --check && cargo clippy --all-targets -- -D warnings && cargo clippy --target wasm32-unknown-unknown -- -D warnings && cargo test --quiet

# Build the voice processors (voice/) to WASM for the browser's worklets:
# assets/js/randos/voice/randos_voice.wasm, committed (production builds
# have no Rust). std's paths are remapped to rustc's own, so the build is the
# same on every machine; needs the wasm32-unknown-unknown target (mise.toml)
voice-wasm out="assets/js/randos/voice/randos_voice.wasm":
    #!/usr/bin/env bash
    set -euo pipefail
    sysroot="$(rustc --print sysroot)"
    commit="$(rustc -vV | sed -n 's/commit-hash: //p')"
    RUSTFLAGS="--remap-path-prefix=$sysroot/lib/rustlib/src/rust=/rustc/$commit" \
      cargo build --quiet -p randos_voice --target wasm32-unknown-unknown --release --target-dir target/voice-wasm
    cp target/voice-wasm/wasm32-unknown-unknown/release/randos_voice.wasm "{{out}}"

# Fail if the committed .wasm isn't the current build of voice/ (run `just voice-wasm`)
voice-wasm-check:
    #!/usr/bin/env bash
    set -euo pipefail
    mkdir -p tmp
    just voice-wasm tmp/randos_voice.wasm
    if ! cmp -s tmp/randos_voice.wasm assets/js/randos/voice/randos_voice.wasm; then
      echo "ERROR: assets/js/randos/voice/randos_voice.wasm is stale: run 'just voice-wasm' and commit it" >&2
      exit 1
    fi

# What the build would download from GitHub releases with Erlang's :httpc,
# which refuses their responses (over 10 KB of headers since 2026-10-24:
# header_too_long), fetched with curl to where each installer looks first:
# ex_ratatui's NIF (the TUI and the dev dashboard), lazy_html's (tests),
# and the Tailwind binary. bin/prefetch.sh has the details; the Dockerfile
# runs its tailwind part. After `mix deps.get`, before anything compiles.
# Fetch the prebuilt NIFs and Tailwind with curl (after deps.get)
prefetch:
    bin/prefetch.sh nifs tailwind

# The TUI as an installable archive (Phase 4.4): ERTS, the app, bin/randos,
# and the media helper, in dist/randos-VERSION-OS-ARCH.tar.gz (+ .sha256).
# Unpacks anywhere; checked by running the unpacked copy. CI builds the same
# on a version tag (.github/workflows/release.yml)
tui-release:
    #!/usr/bin/env bash
    set -euo pipefail
    cargo build --release -p randos_media
    (cd clients/tui && MIX_ENV=prod mix deps.get --only prod >/dev/null)
    bin/prefetch.sh nifs
    (cd clients/tui && MIX_ENV=prod mix release randos_tui --overwrite --quiet)
    version="$(sed -n 's/^ *version: "\(.*\)",$/\1/p' clients/tui/mix.exs | head -1)"
    os="$(uname -s | tr '[:upper:]' '[:lower:]' | sed 's/darwin/macos/')"
    arch="$(uname -m | sed 's/aarch64/arm64/')"
    name="randos-${version}-${os}-${arch}"
    rm -rf "dist/${name}" "dist/${name}.tar.gz"
    mkdir -p dist
    cp -R clients/tui/_build/prod/rel/randos_tui "dist/${name}"
    tar -C dist -czf "dist/${name}.tar.gz" "${name}"
    (cd dist && shasum -a 256 "${name}.tar.gz" > "${name}.tar.gz.sha256")
    rm -rf "dist/${name}"
    # Check the archive itself: unpacked elsewhere, it runs and finds its helper.
    check="$(mktemp -d)"
    tar -C "$check" -xzf "dist/${name}.tar.gz"
    "$check/${name}/bin/randos" --version
    "$check/${name}/bin/randos" --check
    rm -rf "$check"
    echo "dist/${name}.tar.gz"

# Regenerate the README's screenshots (docs/assets/) from a real call on a
# throwaway server; needs Chrome and vhs (brew install vhs)
screenshots:
    cargo build --quiet -p randos_media
    cd clients/tui && mix compile
    PHX_HOST=randos.slowinput.org BASE_URL=http://localhost:4010 RANDOS_CALL_SEGMENT_MS=600000 test/e2e/with_test_server.sh tmp/screenshots-server.log node tools/screenshots/screenshots.mjs

# Running models: tools/translate/README.md. In its own environment,
# .venv-test: syncing the shared .venv would remove a running model's
# packages.
# The translation shootout's checks and fill rule (offline, no models)
translate-test:
    cd tools/translate && UV_PROJECT_ENVIRONMENT=.venv-test uv run --group dev ruff check --quiet . && UV_PROJECT_ENVIRONMENT=.venv-test uv run --group dev pytest -q

# After changing UI strings: the template is extracted, each model of the
# catalog's shootout translates only what's new or reworded (`cli plan`,
# then `run --append`), the scorers and judges score only those (judged
# verdicts are cached), and every language's .po gets the picks: empty
# entries and the machine's own, never a person's fix. One model at a
# time, in the shared .venv, so it refuses to start beside another run.
# Re-translate the strings that changed (catalog: site or tui)
translate-update catalog="site":
    #!/usr/bin/env bash
    set -euo pipefail
    # A model loading or running (run, score); not review/fill/plan, which
    # are model-free and safe beside one, nor an editor with cli.py open.
    if pgrep -f "[r]andos_translate\.cli .*(run|score)" >/dev/null; then
      echo "error: a translation model is already running (see pgrep -fl randos_translate)" >&2
      exit 1
    fi
    case "{{catalog}}" in
      site) mix gettext.extract --merge ;;
      tui) (cd clients/tui && mix gettext.extract --merge) ;;
      *) echo "error: catalog is site or tui" >&2; exit 1 ;;
    esac
    cd tools/translate
    cli="python -m randos_translate.cli --catalog {{catalog}}"
    plan=$(UV_PROJECT_ENVIRONMENT=.venv-test uv run $cli plan)
    if [ -z "$plan" ]; then echo "every model has every string; scoring anything left over"; fi
    while IFS=$'\t' read -r group model locales run count; do
      [ -n "$group" ] || continue
      echo "== $model: $count to translate"
      uv run --group "$group" $cli run --model "$model" --locales "$locales" --append "$run" < /dev/null
    done <<< "$plan"
    uv run --group models $cli score --scorer metricx > /dev/null
    uv run --group comet $cli score --scorer comet_kiwi > /dev/null
    uv run --group mlx $cli score --scorer judge > /dev/null
    export UV_PROJECT_ENVIRONMENT=.venv-test
    uv run $cli review > /dev/null
    uv run $cli fill --best --locale all --redo

# The voice-anonymization benchmark (tools/voice-eval): can ECAPA-TDNN still
# identify a speaker after each processor, and can Whisper understand them?
# Downloads LibriSpeech test-clean (346 MB) and the models (~0.4 GB) once;
# writes tools/voice-eval/results/benchmark.json, which the voice lab shows
voice-eval:
    cd tools/voice-eval && uv run --group models python -m randos_voice_eval.bench

# The benchmark's metrics and verdicts (offline, no models)
voice-eval-test:
    cd tools/voice-eval && uv run --group dev pytest -q

# The Homebrew formula for VERSION, from the GitHub release's checksums
# (packaging/homebrew/README.md); --local uses dist/ instead
homebrew-formula version *flags:
    @packaging/homebrew/render.sh {{version}} {{flags}}

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

# Fail if a setting docs/privacy.md relies on leaves the coturn config
check-privacy:
    #!/usr/bin/env bash
    set -euo pipefail
    template=infra/coturn/cloud-init.yaml.tftpl
    status=0
    for setting in 'use-auth-secret' 'log-min-level=error' \
                   '--log-driver syslog' '--log-opt cache-disabled=true' \
                   'syslog-address=udp://127.0.0.1:5514' \
                   'type="mmanon"' 'ipv4.bits="32"' 'ipv6.bits="128"' 'embeddedipv4.bits="128"' \
                   'ruleset="coturn"' 'rotate 7' \
                   '-v /etc/coturn:/etc/coturn:ro'; do
      if ! grep -qF -- "$setting" "$template"; then
        echo "ERROR: '$setting' is gone from $template, but docs/privacy.md promises it" >&2
        status=1
      fi
    done
    # coturn's admin CLI is off by default (since 4.18); nothing may turn it on.
    if grep -qE '^\s+(cli-password|cli-ip|cli-port|cli)(\s|=|$)' "$template"; then
      echo "ERROR: $template enables coturn's admin CLI, but docs/privacy.md says it's off" >&2
      status=1
    fi
    exit $status

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
    #!/usr/bin/env bash
    set -euo pipefail
    # Deploy only what's on origin/main: fly builds from this checkout, so
    # unpushed commits would go live unreviewed by CI. RANDOS_DEPLOY_UNPUSHED=1
    # overrides (say why in the commit you push afterwards).
    git fetch --quiet origin main \
      || echo "warning: couldn't reach origin; checking against the last fetched origin/main" >&2
    ahead=$(git rev-list --count origin/main..HEAD)
    if [ "$ahead" -gt 0 ] && [ "${RANDOS_DEPLOY_UNPUSHED:-}" != "1" ]; then
      echo "HEAD has $ahead commit(s) not on origin/main; push them (and let CI pass) first," >&2
      echo "or deploy anyway with RANDOS_DEPLOY_UNPUSHED=1 just deploy" >&2
      exit 1
    fi
    # Nor uncommitted changes (fly builds from the working tree), nor a
    # commit whose CI isn't green: RANDOS_DEPLOY_DIRTY=1 and
    # RANDOS_DEPLOY_UNCHECKED=1 override, for emergencies.
    commit=$(git rev-parse --short HEAD)
    if [ -n "$(git status --porcelain)" ]; then
      if [ "${RANDOS_DEPLOY_DIRTY:-}" != "1" ]; then
        echo "uncommitted changes would go live: commit and push them, or RANDOS_DEPLOY_DIRTY=1" >&2
        exit 1
      fi
      commit="$commit-dirty"
    fi
    if [ "${RANDOS_DEPLOY_UNCHECKED:-}" != "1" ]; then
      ci=$(gh run list --workflow ci.yml --commit "$(git rev-parse HEAD)" --json status,conclusion \
        --jq '.[0] | "\(.status) \(.conclusion)"' 2>/dev/null || echo "unknown")
      if [ "$ci" != "completed success" ]; then
        echo "CI for $commit is \"${ci:-none}\", not green: wait for it, or RANDOS_DEPLOY_UNCHECKED=1" >&2
        exit 1
      fi
    fi
    fly deploy --build-arg RANDOS_COMMIT="$commit"
