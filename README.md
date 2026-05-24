<p align="center">
  <img src="priv/static/images/logo.svg" alt="Randos logo" width="96" height="96">
</p>

# Randos

Randos is an anonymous, audio-only language conversation app for low-pressure
human practice.

It is not a social network, content platform, or metrics-driven dopamine delivery system.
It is closer to public conversational infrastructure: a calm place where adults
can briefly meet to converse and then disappear.

[Try Randos][live-site].

## Philosophy

Randos is intentionally constrained:

- no accounts
- no profiles
- no followers, feeds, streaks, ratings, or scores
- no video
- no recording
- no server-side audio access
- no permanent social graph

Users choose the language they will speak and the language they want to hear.
Randos then pairs compatible strangers for a short WebRTC audio conversation.

This supports crosstalk, language exchange, listening practice, and casual
conversation without forcing people into rigid modes or gamified progress loops.

Calls start at ten minutes. At the end of each ten minute segment, both people
must agree to continue. The total cap is thirty minutes.

The product should feel like a doorway, not a platform.

## Current Shape

Randos is a Phoenix LiveView application with:

- anonymous matchmaking
- WebRTC microphone capture and peer audio
- dynamic ICE server configuration
- coturn-ready TURN credential generation
- local HTTPS support for microphone testing
- a Terraform/coturn scaffold under `infra/coturn`

The app currently uses ETS-backed Ash resources and process-backed call state.
There is no database. Queues, calls, and call session state are transient and
disappear on application restart.

## Local Development

Install dependencies and build assets:

```bash
mix setup
```

Start the app:

```bash
mix phx.server
```

Open:

```text
http://localhost:4000
```

## HTTPS Development

Microphone capture and WebRTC testing are more reliable from a secure browser
context. The dev HTTPS endpoint is enabled when these files exist:

```text
priv/cert/randos_dev.pem
priv/cert/randos_dev_key.pem
```

Generate local certs with `mkcert`:

```bash
mkcert -install
mkdir -p priv/cert
mkcert \
  -key-file priv/cert/randos_dev_key.pem \
  -cert-file priv/cert/randos_dev.pem \
  localhost 127.0.0.1 ::1 "$(hostname)" randos.local
```

Then run:

```bash
mix phx.server
```

Open:

```text
https://localhost:4001
```

Useful overrides:

```bash
HTTPS_PORT=4443 mix phx.server
DEV_SSL_CERTFILE=/path/to/cert.pem DEV_SSL_KEYFILE=/path/to/key.pem mix phx.server
```

For phone or LAN testing, include the device-visible hostname or LAN IP in the
certificate name list, then restart the app.

## TURN And STUN

Without TURN env vars, Randos falls back to public STUN:

```text
stun:stun.l.google.com:19302
```

To test against the coturn server managed by `infra/coturn`:

```bash
TURN_HOST="turn.slowinput.org" \
TURN_REALM="turn.slowinput.org" \
TURN_SHARED_SECRET="$(terraform -chdir=infra/coturn output -raw turn_shared_secret)" \
TURN_CREDENTIAL_TTL_SECONDS="900" \
mix phx.server
```

That emits browser ICE servers for:

```text
stun:turn.slowinput.org:3478
turn:turn.slowinput.org:3478
turns:turn.slowinput.org:5349
```

TURN relays encrypted WebRTC packets only when direct peer-to-peer connectivity
fails. It does not give Randos server-side audio access.

## Infrastructure

The coturn Terraform and cloud-init setup lives in:

```text
infra/coturn/
```

Operational docs:

- `docs/architecture/ops.md`
- `infra/coturn/README.md`

The Terraform state contains the generated TURN shared secret. Keep it private
and backed up.

## Checks

Run tests:

```bash
mix test
```

Run the full project check:

```bash
mix precommit
```

Build assets:

```bash
mix assets.build
```

Build production assets:

```bash
mix assets.deploy
```

## Production Notes

Minimum production configuration:

```bash
SECRET_KEY_BASE="$(mix phx.gen.secret)"
PHX_HOST=your.domain.com
PORT=4000
```

For TURN-backed production, also set:

```bash
TURN_HOST="turn.slowinput.org"
TURN_REALM="turn.slowinput.org"
TURN_SHARED_SECRET="..."
TURN_CREDENTIAL_TTL_SECONDS="900"
```

Run a single app instance until matchmaking and call coordination are moved to
shared/distributed infrastructure. The current in-memory state model is not
safe for horizontally scaled app instances.

[live-site]: https://randos.slowinput.org
