# Randos Operations

This document summarizes the environment variables and basic operating commands
used by the Randos application.

## Environment Variables

The application currently reads these environment variables from config:

| Variable | Used in | Purpose |
| --- | --- | --- |
| `PORT` | `config/dev.exs`, `config/runtime.exs` | HTTP port. Defaults to `4000` in development and production. |
| `HTTPS_PORT` | `config/dev.exs` | Development HTTPS port when local certificate files exist. Defaults to `4001`. |
| `DEV_SSL_CERTFILE` | `config/dev.exs` | Development TLS certificate path. Defaults to `priv/cert/randos_dev.pem`. |
| `DEV_SSL_KEYFILE` | `config/dev.exs` | Development TLS key path. Defaults to `priv/cert/randos_dev_key.pem`. |
| `PHX_SERVER` | `config/runtime.exs` | Enables the Phoenix endpoint server in releases, for example `PHX_SERVER=true bin/randos start`. |
| `SECRET_KEY_BASE` | `config/runtime.exs` | Required in production for signing and encryption. Generate with `mix phx.gen.secret`. |
| `PHX_HOST` | `config/runtime.exs` | Public production host. Defaults to `example.com`. |
| `DNS_CLUSTER_QUERY` | `config/runtime.exs`, `lib/randos/application.ex` | Optional DNS clustering query for distributed deployments. |

## TURN Variables

These variables configure browser ICE servers for WebRTC calls:

| Variable | Status |
| --- | --- |
| `TURN_HOST` | Optional hostname shortcut. When present, the app derives `stun:`, `turn:`, and `turns:` URLs from it. |
| `TURN_STUN_URL` | Optional explicit STUN URL, for example `stun:turn.slowinput.org:3478`. |
| `TURN_SERVER_URL` | Optional explicit TURN URL, for example `turn:turn.slowinput.org:3478`. |
| `TURNS_SERVER_URL` | Optional explicit TURN-over-TLS URL, for example `turns:turn.slowinput.org:5349`. |
| `TURN_SHARED_SECRET` | coturn REST API shared secret used to generate temporary browser credentials. |
| `TURN_REALM` | coturn realm. Kept with deployment config; browsers do not need it directly. |
| `TURN_CREDENTIAL_TTL_SECONDS` | Lifetime for generated temporary TURN credentials. Defaults to `900`. |

Without `TURN_SHARED_SECRET` and at least one TURN URL, ICE server
configuration falls back to public STUN:

```text
stun:stun.l.google.com:19302
```

For local coturn testing:

```bash
TURN_HOST="turn.slowinput.org" \
TURN_REALM="turn.slowinput.org" \
TURN_SHARED_SECRET="$(terraform -chdir=infra/coturn output -raw turn_shared_secret)" \
TURN_CREDENTIAL_TTL_SECONDS="900" \
mix phx.server
```

## Local Development

Install dependencies and build assets:

```bash
mix setup
```

Start the development server:

```bash
mix phx.server
```

Open the HTTP endpoint:

```text
http://localhost:4000
```

## HTTPS Development

Microphone capture and WebRTC testing are more reliable from a secure browser
context. The app enables a development HTTPS endpoint when both certificate
files exist:

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

Then start Phoenix:

```bash
mix phx.server
```

Open:

```text
https://localhost:4001
```

The HTTP endpoint remains available at:

```text
http://localhost:4000
```

Useful development HTTPS overrides:

```bash
HTTPS_PORT=4443 mix phx.server
DEV_SSL_CERTFILE=/path/to/cert.pem DEV_SSL_KEYFILE=/path/to/key.pem mix phx.server
```

For phone or LAN testing, the dev endpoint binds to `0.0.0.0`, so use the
machine's LAN IP. The development certificate must include the hostname or IP
that the phone uses to reach the server.

## Testing And Checks

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

## Production Basics

The app currently has no database configured. Ash resources use ETS-backed
transient state, and matchmaking and calls are process-backed. Queued users,
active calls, and call session state disappear on application restart.

At minimum, production needs:

```bash
SECRET_KEY_BASE="$(mix phx.gen.secret)"
PHX_HOST=your.domain.com
PORT=4000
```

For a release:

```bash
MIX_ENV=prod mix assets.deploy
MIX_ENV=prod mix release
PHX_SERVER=true SECRET_KEY_BASE=... PHX_HOST=... PORT=4000 bin/randos start
```
