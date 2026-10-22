# Developing randos

How to set up, run, and test randos locally, and where things are. For
running a public instance, see [self-hosting](self-hosting.md). Coding
agents (and people who like rules written down) should also read
[`AGENTS.md`](../AGENTS.md): its constraints apply to everyone.

## What's here

| Part | Where | What it is |
| --- | --- | --- |
| Server and website | `lib/`, `assets/` | Phoenix LiveView: matchmaking, one process per call, WebRTC signaling. The browser does the audio. |
| Terminal client | `clients/tui/` | A separate Mix project on [ex_ratatui](https://hex.pm/packages/ex_ratatui), talking to the server over the [participant channel](architecture/participant_channel.md) |
| Media helper | `clients/tui/native/` | Rust (str0m WebRTC, Opus, cpal), run by the terminal client as a Port: [its README](../clients/tui/native/README.md) |
| Voice processors | `voice/` | Rust (`randos_voice`), written once: native in the helper, WASM in the browser (`just voice-wasm` rebuilds the committed `.wasm`) |
| Translation shootout | `tools/translate/` | Python (uv): machine-translates the UI's gettext strings and scores the models |
| Voice benchmark | `tools/voice-eval/` | Python (uv): can a speaker model still identify a voice after a processor? |
| TURN server | `infra/coturn/` | coturn as code (OpenTofu + cloud-init): [its README](../infra/coturn/README.md) |
| Design notes | `docs/architecture/` | The [roadmap](architecture/refactor_plan.md), the [call flow](architecture/call_flow.md), the channel protocol, and more |

There is no database: the matchmaking queue and each call's coordinator are
processes, and everything vanishes on restart.

## Setup

Toolchain versions (Erlang/OTP, Elixir, Node, Rust, just, OpenTofu, mkcert,
and a few more) are pinned in `mise.toml`, and the commands live in the
`Justfile` (`just --list` shows them all).

```bash
mise install
just setup        # toolchain, deps, assets
just dev          # http://localhost:4000 (with IEx)
```

`just serve` runs the same server without IEx, in the background
(`just serve-stop` stops it).

### HTTPS, for the mic on other devices

Browsers allow the microphone only on `localhost` or over HTTPS. To try
randos from a phone or another computer on your network:

```bash
just certs        # local certificates with mkcert (priv/cert/)
just dev          # also https://<your machine's name or LAN IP>:4001
```

Other devices click through a certificate warning (or trust mkcert's CA).
`HTTPS_PORT`, `DEV_SSL_CERTFILE`, and `DEV_SSL_KEYFILE` override the defaults.

### TURN in development

Without TURN settings, the dev server hands out Google's public STUN
server, which is enough on one network. To use the real coturn relay (the
owner's setup: the secret comes from the encrypted OpenTofu state and is
never printed):

```bash
just dev-turn
```

`RANDOS_CALL_SEGMENT_MS=8000 just dev` makes calls 8 seconds long, for
trying the continue-the-call vote by hand.

## The terminal client

```bash
cargo build -p randos_media     # the media helper (once, and after Rust changes)
just tui                        # against the local dev server
just tui --url wss://randos.slowinput.org/participant/websocket
```

Without the helper, the client runs text-only and is matched only with
other text-only clients. More in [its README](../clients/tui/README.md).

## Tests and checks

| Command | What it checks |
| --- | --- |
| `just test [path]` | The server's tests (`just test-tui` for the terminal client's) |
| `just precommit` | Everything CI checks per platform: compile with warnings as errors, format, Credo, both test suites, the Rust crates (fmt, clippy, tests, cargo-deny), and the Python harnesses' offline tests (`tools/translate`, `tools/voice-eval`; no models). **Run it before calling a change done**, and check its exit status. |
| `just smoke` | Two headless Chromes with fake mics place a real call (`mix test` can't see the browser). Run after changing `assets/js/` or the call flow. Includes `just recovery-smoke`: a relay-only call through the test TURN relay (`just test-turn`) has its media cut, alone and with a websocket drop, and must come back by ICE restart. |
| `just tui-smoke` | Real terminal clients call each other and headless Chrome, with audio checked both ways, including recovery: relay-only through the test TURN relay, every path cut, and the call back on ICE restart (TUI ↔ TUI, and TUI ↔ browser in both roles; those tests start their own relay and server). Run after changing the terminal client, the helper, or the channel. |
| `just check-privacy` | That the coturn settings [privacy.md](privacy.md) promises are still in its config (part of precommit). |
| `just turn-check` | The helper against the real coturn, over UDP and TLS (owner only: needs the TURN secret). Run after changing the relay path. |

CI (`.github/workflows/ci.yml`) runs `just precommit` on macOS and Linux,
plus both smoke tests. The tests never play sound and never reach the
internet; the smoke tests start their own throwaway server on :4010.

## More tools

- `just top`: the dev server plus a terminal dashboard of queues, calls, and
  events.
- Dev-only pages on `just dev` (never in production):
  [`/dev/voice-lab`](http://localhost:4000/dev/voice-lab), to hear and
  compare the voice processors (offline renders, spectrograms, and the
  anonymization benchmark's results), and
  [`/dev/translations`](http://localhost:4000/dev/translations), the
  translation shootout's review page (models side by side, where they and
  the evaluators disagree).
- `just voice-eval`: the anonymization benchmark (ECAPA-TDNN speaker
  identity and Whisper intelligibility on a LibriSpeech subset, downloaded
  on first run); commit its `results/benchmark.json`.
  `just translate-test` and `just voice-eval-test` run the two harnesses'
  offline tests (part of `just precommit`).
- `/status` (also in production): the relay check and today's counts.
- `/translations` (also in production): every string per language, each
  with a link to a prefilled GitHub issue. Such an issue becomes a pull
  request through `.github/workflows/translation-fix.yml`:
  `tools/translate`'s `randos_translate.issue_fix` reads and checks it
  (issue text never reaches a shell), and `mix randos.translation_fix`
  writes the one entry with Expo, so the diff is one line. Pull requests
  the workflow opens don't trigger CI; it checks the fix itself, and CI
  runs on main after merging.
- `just screenshots`: regenerates the README's screenshots
  (`docs/assets/`) from a real call on a throwaway server, with fake audio
  (needs Chrome and `brew install vhs`).
- `just media-loopback`: mic → Opus → speaker through the helper, with the
  latency (use headphones).

## Releases

The terminal client is released from a version tag:

1. Bump `version` in `clients/tui/mix.exs` and commit.
2. `git tag vX.Y.Z && git push origin vX.Y.Z`: CI builds the macOS arm64 and
   Linux x86_64 archives (`just tui-release` builds one locally) and attaches
   them to a GitHub release.
3. Commit the output of `just homebrew-formula X.Y.Z` to
   [wasichu/homebrew-randos](https://github.com/wasichu/homebrew-randos) as
   `Formula/randos.rb` ([details](../packaging/homebrew/README.md)).

The server is deployed separately (`just deploy`, to Fly.io).
