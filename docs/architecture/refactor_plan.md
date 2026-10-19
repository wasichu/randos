# Randos roadmap

Verified against the code at `df93b46` (2026-10-19). Update this line, and
check that every module/function named below still exists, whenever the plan
changes. This doc names symbols, never `file:line` (line numbers rot; graft
finds symbols). The reasoning and code review behind the 2026-10-19 decisions
is in [`2026-10-19-refactor-findings.md`](2026-10-19-refactor-findings.md).

## Goals

1. **A TUI participant client** (ex_ratatui) alongside the web UI. It must
   never attach to production Erlang nodes or be served over SSH: it is a
   standalone client that talks to the server like a browser does, over the
   public participant channel.
2. **Voice anonymization**, run locally on the user's device (DSP and/or a
   small model). The server stays media-blind.

## Status

| Phase | What | Status |
| --- | --- | --- |
| 1 | Cleanup: dead code, daisyUI, ghost-call and ETS-leak bugs, Ash replaced by plain Elixir/OTP | Done |
| 2 | UI-agnostic participant core; LiveView becomes a shell | Done |
| 3 | Public participant channel (browser stays on LiveView) | Done |
| — | coturn audit, hardening and rebuild; infra on OpenTofu with encrypted state | Done (see [`coturn_audit.md`](coturn_audit.md)) |
| 4 | TUI | 4.1, 4.2 done; 4.3 Stage 0 done (headphone check pending), **next: 4.3 Stage 1**; then 4.4 release binaries and 4.5 Homebrew tap |
| 5 | Voice anonymization | Planned |

## How it fits together

- **`Randos.Participant`** is the pure core of one person's flow (find → queue →
  call → back): `handle/2` returns `{participant, effects}`.
- **`RandosWeb.ParticipantShell`** runs that core for a transport process:
  `run/2` executes server-side effects (matchmaker, call coordinator) and
  returns client effects (`{:push_signal, _}`, `{:ice_servers, _}`);
  `client_state/1` is the JSON-safe view (no ids, no peer).
- Two transports share the shell: **`RandosWeb.HomeLive`** (browser, LiveView,
  rendered by `RandosWeb.HomeComponents`) and **`RandosWeb.ParticipantChannel`**
  on `RandosWeb.ParticipantSocket` (everything else; protocol in
  [`participant_channel.md`](participant_channel.md)).
- **`Randos.Matchmaking.Matchmaker`** pairs `Randos.Matchmaking.Entry` structs
  into a `Randos.Matchmaking.Match` and starts the call.
- **`Randos.Calls.CallCoordinator`** (a `:gen_statem`, one per call, `:temporary`)
  owns the `Randos.Calls.Call` struct, moves it through
  `Randos.Calls.Lifecycle`, and broadcasts `{:call_updated, call}` and
  `{:signaling, message}` (built by `Randos.Signaling`).
- **`RandosWeb.IceServers`** mints STUN/TURN credentials per call.
- **Telemetry:** `[:randos, :call, :start | :status | :stop]` and
  `[:randos, :matchmaking, :join]`, with metrics in `RandosWeb.Telemetry`.
- Browser media lives in `assets/js/randos/webrtc_client.js` (`WebRTCClient`)
  and `assets/js/hooks/call_hook.js`; `just smoke` exercises it end to end.

## Phase 4: TUI

### 4.1 Local dev monitor (done)

A terminal dashboard for watching the server while developing: queue depth by
language pair (`Matchmaker.snapshot/0`), live calls and their status changes,
and a feed of recent call/matchmaking events, all from the telemetry events
above. It's also the learning ramp for ex_ratatui before the real client.

Built as `RandosDev.Monitor` (an `ExRatatui.App`) over the pure
`RandosDev.Monitor.State`, run by `mix randos.top` / `just top`. Code lives in
`dev/`, compiled only in dev and test.

- **Data path (decided): in the dev VM.** Telemetry handlers and the
  Matchmaker are local to one BEAM VM, so the monitor runs *inside* the dev
  server's VM: `just top` starts the server and the monitor together (logs go
  to `tmp/` so they don't fight the TUI for the terminal; the browser still
  works against it). No networking and no new process registry. Not chosen:
  a separate `--sname` node over local Erlang distribution; it works, but adds
  moving parts for no gain here.
- **Dependency:** `ex_ratatui` with `only: :dev` in the server's `mix.exs`, so its
  NIF never reaches the release.
- **Tests:** ex_ratatui's headless backend; the state the monitor renders comes
  from a plain module that folds telemetry events, tested without a terminal.

### 4.2 Text-only participant client (done)

A separate Mix project in `clients/tui` (its own deps; nothing in the server
release). It is a **renderer of the channel's `state` pushes**: it holds no
participant state machine of its own, because the server's
`Randos.Participant` already is that. Choose languages, queue, see the match
and timer, vote on extensions, hang up, Next. Audio is a stub. It can be
matched with a browser user.

- Built as `Tui.App` over the pure `Tui.Model`, connected by `Tui.Connection`
  (Slipstream, chosen for join/heartbeat/reconnect handling and its test
  helper). Languages come from the join reply. With no audio, the client
  answers a peer's `offer` with `end_call` (only the peer is requeued; see
  the protocol doc); two TUIs can hold a call (used by `just tui-smoke`).
  `just tui` runs it against the local dev server. Not production-safe yet:
  see "Text-only clients and browsers" under open items.

### 4.3 Audio (design accepted; Stage 0 in progress)

Design: [`tui_audio.md`](tui_audio.md). Proposed: all media in one Rust helper
run as a Port (str0m, Opus via libopus, cpal), Elixir keeps signaling and UI;
`ex_webrtc` rejected for its in-VM NIFs (OpenSSL, libsrtp) compiled on users'
machines. Staged: skeleton → browser interop with real TURN → hardening → AEC.

Stage 0 code is done:
- the helper (`clients/tui/native`, crate `randos_media`) speaks a JSON Port
  protocol (requests with ids, replies, events) and runs a cpal → Opus → cpal
  loopback (≈81 ms pipeline latency measured);
- `Tui.Media` owns it (pure `Tui.Media.Protocol`), under `Tui.Supervisor`
  next to `Tui.App`, so a helper crash restarts only the helper;
- `t` on the TUI's idle screen runs a 5 s mic test through it.

**Open TODO (needs headphones, by hand):** run `just media-loopback` and the
TUI's `t` mic test, clap to judge mouth-to-ear delay, and note whether macOS
shows a mic prompt and which app it names. Record the results in
`tui_audio.md`.

Capability-aware matching is built: `find` carries `audio` (browsers always
`true`, the TUI `false` until Stage 1), and `Matchmaker` keys its queues by
`{speaks, listens, audio?}`, so text-only clients only meet each other.

Decisions for Stage 1 (from the Stage 0 review):
- **Media state lives in a pure module (done).** `Tui.Media.State` holds
  local audio state as `{state, commands}` transitions (the mic test today);
  Stage 1's call audio (ICE, mute, levels) goes there too, not in `Tui.App`.
  `Tui.App` sends requests with `Tui.Media.request_async/2` and never blocks
  on the helper.
- **`OpusLoop` is loopback-shaped.** Stage 1 splits encode (mic → network)
  from decode (network → speaker), and the WebRTC path replaces the device
  sink. It isn't an abstraction to keep.

### 4.4 Distribution

Single-binary releases via Burrito (`mix ex_ratatui.gen.burrito`).

### 4.5 Homebrew (custom tap)

Goal: `brew install wasichu/randos/randos`, then `randos` just works. Far
off: it needs 4.3 Stage 1 (real call audio) and 4.4 (release binaries).

- **A tap, not homebrew-core.** Core wants formulas built from source (Rust
  plus Erlang/Elixir toolchains at install time) and a notable project; a tap
  (`github.com/wasichu/homebrew-randos`, formula `randos`) can install our
  prebuilt release archives, one per platform (`on_macos`/`on_arm` blocks
  with a `sha256` each). Linuxbrew gets the Linux glibc build from the same
  formula. Core can be revisited if the project grows.
- **What it installs:** the TUI and the `randos_media` helper side by side,
  so `Tui.Media.default_helper_path/0` finds it without `RANDOS_MEDIA_BIN`.
  Decide in 4.4 whether that's a Burrito binary (unpacks to a cache dir on
  first run) or a plain `mix release` directory; the latter suits Homebrew's
  layout better.
- **Release automation:** a tagged release in CI builds the archives,
  attaches them to a GitHub release, and bumps the formula's URLs and hashes
  in the tap (needs a token with write access to the tap, stored as a repo
  secret: owner's call when we get there). The formula's `test do` block runs
  the TUI's `--version` and pings the helper.
- **Product defaults that change for installed users:** `mix tui` defaults to
  the local dev server; an installed `randos` must default to production
  (`wss://randos.slowinput.org/participant/websocket`), with `--url` kept for
  dev.
- **macOS:** Homebrew formulas don't add the quarantine attribute, so an
  unsigned binary runs; mic permission is granted to the terminal app hosting
  it. Signing and notarization are optional for a tap, but revisit them if the
  4.3 Stage 0 mic-permission findings show an unsigned helper is treated
  differently.

## Phase 5: Voice anonymization

The most experimental phase, so it's built around a **voice lab** that
makes trying an approach cheap and comparing approaches easy, by ear and by
eye, before anything touches a real call.

1. **Seam first.** One explicit spot in each client's audio path between the
   mic and the call, with a pass-through default:
   - Browser: in `WebRTCClient.startConnection()`, after `captureLocalAudio()`
     and before `addTrack`: `localStream = await processLocalStream(rawStream)`.
     Teardown must stop the *raw* tracks and close the processor's
     AudioContext; decide whether mute and the visualizer act on raw or
     processed audio; share one AudioContext.
   - TUI: the equivalent spot in the 4.3 native pipeline (the helper's
     `Processor`, prototyped in Elixir first per the 4.3 decisions).
2. **Voice lab (local web page).** A dev-only LiveView at `/dev/voice-lab`,
   inside the existing `dev_routes` scope, so it never ships to production.
   - **Pluggable processors.** Each approach is one module behind a common
     interface (e.g. an AudioWorklet processor under
     `assets/js/voice_lab/processors/`, plus a manifest of name,
     parameters, and where it runs). Adding a variant = adding a file; the
     lab picks it up and renders its parameter sliders automatically. A
     pass-through baseline is always present.
   - **Sources.** Bundled, openly licensed speech clips (several voices,
     both supported languages' worth of variety), a test tone, and the live
     mic. The mic path is processed in real time to headphones only; nothing
     is recorded, stored, or uploaded (README product constraints).
   - **Compare side by side.** Pick any two to four variants: synchronized
     playback with instant switching (same clip, same position), a blind A/B
     mode that hides which is which and tallies your picks, and a parameter
     sweep that renders one variant at several settings in a row.
   - **See it, not just hear it.** Per variant: spectrogram and pitch track
     next to the original, measured processing latency and CPU per frame,
     and a level meter, so "sounds robotic" can be matched to something
     visible.
   - **Same code as the call.** Processors run through the same seam
     function the browser call uses, so a variant that wins in the lab is
     one setting away from a real call (`just smoke` then checks it doesn't
     break teardown).
3. **Comparison write-ups.** After each round of experiments, a short
   report: the variants tried, their latency/CPU numbers, spectrogram
   snapshots, your blind A/B results, and a recommendation. Reports use only
   the bundled clips, never a recording of anyone's voice.
4. **Model mini-project** (its own design doc once the lab exists): DSP
   (pitch/formant shifting) vs. on-device voice conversion, latency budget,
   browser WASM/WebGPU vs. native, and how much anonymity each actually
   gives (a speaker-similarity check belongs in the lab once there's a
   candidate model).

## Open items

Not scheduled; pick up when relevant.

- **Multi-node matchmaking.** Production runs one Fly machine because
  `Matchmaker` is node-local (two machines split the queue). Before scaling
  out, pick one: a cluster-wide singleton (`:global`/Horde), or a queue over
  `:pg`/PubSub that matches locally and falls back to remote.
- **CI (done).** `.github/workflows/ci.yml`: `just precommit` on macOS and
  Linux (with `RANDOS_REQUIRE_NATIVE=1`), plus `just smoke` and
  `just tui-smoke`. Deploys stay manual (`just deploy`).
- **Same pair rematching on "Next"** when they're the only two queued
  (product decision: a short "recently matched" exclusion?).
- **`RandosWeb.IceServers` reads env vars per call.** Move them to
  `config/runtime.exs` so misconfiguration fails at boot instead of silently
  falling back to Google STUN.
- **Socket blip ends the call.** `call_hook.js`'s `disconnected()` tears down on
  any LiveView reconnect; revisit if reconnect/resume is ever designed (today
  a new connection is a new participant, by design).
- **`boundary` library.** Deferred during cleanup; now that core vs web is a
  real split, reconsider enforcing it.
- **coturn follow-ups** for its next intentional rebuild: see
  [`coturn_audit.md`](coturn_audit.md).

## Decisions

All 2026-10-19 unless noted.

- **Ash removed**; plain Elixir/OTP first, justify every dependency. Call
  coordinator is a `:gen_statem`.
- **The TUI never attaches to Erlang nodes or uses SSH**; it uses the public
  participant channel.
- **Browser stays on LiveView**; the channel is for non-browser clients.
- **"End" no longer reloads the page** (it hangs up and goes idle).
- **Production runs one machine** until multi-node matchmaking exists.
- **TURN credentials are minted per call**, TTL ≥ longest call + 10 minutes.
- **coturn: hardened via rebuild** (option C, step A skipped), errors-only
  logging, pinned image.
- **Infra on OpenTofu with encrypted, committed state**; passphrase in the
  owner's Keychain and password manager.
- **Dev monitor (4.1) runs in the dev VM**, not as a separate node.
- **TUI audio (4.3): one Rust helper as a Port** (str0m, Opus, cpal);
  headphones in v1; capability-aware matching before Stage 1; the Phase 5
  anonymizer is prototyped in Elixir and shipped in Rust. See
  [`tui_audio.md`](tui_audio.md).
