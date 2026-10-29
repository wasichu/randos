# Running your own randos

randos is a single Phoenix application with no database, so an instance is
one server process plus, ideally, a TURN relay. This is how
[randos.slowinput.org](https://randos.slowinput.org) runs, and what you need
to run your own. To work on the code, see [development](development.md).

randos is under the AGPL: if you run a modified copy for other people, you
must offer them its source. The footer, the About page and the
translations' "Suggest a fix" link to this repository; point them at
yours with `source_url` in `config/config.exs`.

## One instance, not several

Run exactly one instance of the app. The waiting room (the matchmaking
queue) and every call live in that instance's memory, so two instances
would be two separate waiting rooms: two people who arrived at different
instances could never be matched. Restarting the instance ends the calls in
progress and empties the waiting room; nothing else is lost, because
nothing else is kept. (Matching across several instances is a possible
future change: "Multi-node matchmaking" in the
[roadmap](architecture/refactor_plan.md).)

One small machine is plenty: the server only relays signaling messages,
never audio. Ours is a single shared-CPU, 512 MB Fly.io machine.

## Building and running

The repository has a `Dockerfile` for a release image (`just docker-build`
builds it locally); `fly.toml` is our Fly.io configuration (`just deploy`).
Without Docker:

Build from a clean source tree: development bundles under `priv/static/assets`
and local certificates under `priv/cert` must not enter the release. The Docker
context excludes both directories; a direct Mix release does not apply
`.dockerignore`.

```bash
MIX_ENV=prod mix assets.deploy
MIX_ENV=prod mix release
SECRET_KEY_BASE=... PHX_HOST=randos.example.org PORT=4000 \
  _build/prod/rel/randos/bin/server
```

(`bin/server` is `bin/randos start` with `PHX_SERVER=true`.)

Put it behind HTTPS (browsers allow the microphone only on secure pages);
the app itself serves plain HTTP on `PORT`.

## Configuration

| Variable | Required | Purpose |
| --- | --- | --- |
| `SECRET_KEY_BASE` | yes | Signs and encrypts cookies. Generate one with `mix phx.gen.secret`. |
| `PHX_HOST` | yes | The public host name. Browsers' websockets are accepted only from this origin, and invitation links are built from it (`https://PHX_HOST/join#…`), so it must be the name people reach you by. |
| `PORT` | | The HTTP port (default `4000`). |
| `PHX_SERVER` | for releases | `true` starts the web server (`bin/server`, which the Docker image runs, sets it). |
| `RANDOS_ALLOW_DIRECT_CALLS` | | `true` allows direct calls between the two people, with the relay as the fallback. Unset, calls go through the TURN relay only (see below). |
| `RANDOS_ICE_SERVERS` | | When TURN isn't configured: the ICE servers to hand out, as JSON (default: Google's public STUN). Each entry's `urls`, `username` and `credential` are read; other keys are ignored. A TURN entry here makes calls relay-only, as a configured TURN server does. |
| `RANDOS_COMMIT` | | The commit the image was built from, shown and linked in the footer (`-dirty` if built from uncommitted changes). A Docker build argument: `just deploy` passes it; unset, no commit is shown. Its link goes to `source_url` (above). |
| `RANDOS_STATS_DIR` | | Where the status page keeps each day's aggregate counts across restarts (one small JSON file per day). Unset: memory only. Ours is a 1 GB Fly volume; the container's `bin/start` gives the directory to the app's user. |
| `RANDOS_VOICE_PROCESSOR` | | Runs every browser call's mic through a voice processor (`passthrough`, `pitch_shift`; the voice lab's experiments). Unset: none, the mic is sent as it is. An unknown name stops the server from starting. |
| `RANDOS_CONNECT_TIMEOUT_MS` | | How long a call may take to connect before it ends (default 15 s). |
| `DNS_CLUSTER_QUERY` | | Erlang clustering via DNS. Clustering alone doesn't share the waiting room (see above). |

Voice masking is a local, off-by-default choice in both clients, not an additional
`RANDOS_VOICE_PROCESSOR` name. Leave that legacy fixed-worklet setting unset to
use the product choices; it cannot be stacked with masking. Building the media helper requires C++17;
Linux binaries need the system C++ standard library (`libstdc++6` on Ubuntu).
See `voice-native/README.md`. Phoenix-only deployment needs no C++ toolchain.

### TURN

A TURN server relays the two people's (still encrypted) audio. **With one
configured, every call goes through it** (relay-only), so neither person
ever learns the other's IP address: a direct call would show each one's
address to the other. That costs a little latency (the audio detours
through the relay) and the relay's bandwidth (about 40 kbit/s each way per
call). `RANDOS_ALLOW_DIRECT_CALLS=true` allows direct calls instead, with
the relay as the fallback for people who can't reach each other directly.

The server enforces this as well as asking the clients: in a relay-only
call it removes direct addresses from the connection messages it relays,
so even an outdated client can't reveal its owner's address.

**Production refuses to start without a TURN server** unless direct calls
are allowed, so a configuration mistake can't quietly expose addresses.
Development and the tests run without one, with direct calls. If the relay
is down, relay-only calls can't connect: they end at the connect timeout
with the usual "couldn't connect" message.

randos mints short-lived TURN credentials for each call from a secret it
shares with coturn (coturn's `use-auth-secret`), so no one gets a
long-lived password.

| Variable | Purpose |
| --- | --- |
| `TURN_HOST` | The TURN server's host. randos derives `stun:HOST:3478`, `turn:HOST:3478`, and `turns:HOST:5349` (TURN over TLS, for networks that block UDP) from it. |
| `TURN_STUN_URL`, `TURN_SERVER_URL`, `TURNS_SERVER_URL` | Explicit URLs instead of the derived ones. |
| `TURN_SHARED_SECRET` | coturn's `static-auth-secret`. Required for TURN. |
| `TURN_REALM` | coturn's realm. Kept with the deployment's config; clients don't need it. |
| `TURN_CREDENTIAL_TTL_SECONDS` | How long each call's credentials last (default 3600). Values below the longest call plus ten minutes (2400) are raised to that, since coturn re-checks credentials when a relay is refreshed. |

TURN needs `TURN_SHARED_SECRET` and at least one TURN URL; otherwise there
is no relay (STUN only, so direct calls), which production allows only with
`RANDOS_ALLOW_DIRECT_CALLS=true`.

The status page (`/status`) tests the relay every few minutes, setting up
and releasing a real allocation over UDP and TLS, and shows whether it
works.

coturn's error log can include callers' addresses, so ours goes through
rsyslog, whose `mmanon` module zeroes every address before it's written;
see `docs/privacy.md` for what we found and why.

Our coturn server is defined as code in `infra/coturn/` (OpenTofu and
cloud-init on a DigitalOcean droplet, with Let's Encrypt for TLS); its
[README](../infra/coturn/README.md) covers provisioning, DNS, the firewall,
certificate renewal, and the encrypted state. The
[coturn audit](architecture/coturn_audit.md) lists its hardening.

## The terminal client and your instance

The terminal client defaults to randos.slowinput.org. To use yours:

```bash
randos --url wss://randos.example.org/participant/websocket
```

(or set `RANDOS_URL`). The client and the server speak the
[participant channel protocol](architecture/participant_channel.md).
