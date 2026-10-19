# Randos roadmap

Verified against the code at `6b13eec` (2026-10-19). Update this line, and
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
| 4 | TUI | **Next: 4.1** |
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

### 4.1 Local dev monitor (next)

A terminal dashboard for watching the server while developing: queue depth by
language pair (`Matchmaker.snapshot/0`), live calls and their status changes,
and a feed of recent call/matchmaking events, all from the telemetry events
above. It's also the learning ramp for ex_ratatui before the real client.

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

### 4.2 Text-only participant client

A separate Mix project in `clients/tui` (its own deps; nothing in the server
release). It is a **renderer of the channel's `state` pushes**: it holds no
participant state machine of its own, because the server's
`Randos.Participant` already is that. Choose languages, queue, see the match
and timer, vote on extensions, hang up, Next. Audio is a stub. It can be
matched with a browser user.

- Channel client: decide when starting, between Slipstream and a small
  hand-written Phoenix-protocol client over a websocket library (justify the
  dependency either way).

### 4.3 Audio

`ex_webrtc` for the peer connection plus native capture/playback (e.g. a
Membrane PortAudio plugin or a small Rustler NIF). Design doc first: device
selection, **echo cancellation** (browsers provide it; a native client doesn't),
Opus, and using the per-call `ice_servers` push.

### 4.4 Distribution

Single-binary releases via Burrito (`mix ex_ratatui.gen.burrito`).

## Phase 5: Voice anonymization

1. **Seam first.** One explicit spot in each client's audio path between the
   mic and the call, with a pass-through default:
   - Browser: in `WebRTCClient.startConnection()`, after `captureLocalAudio()`
     and before `addTrack`: `localStream = await processLocalStream(rawStream)`.
     Teardown must stop the *raw* tracks and close the processor's
     AudioContext; decide whether mute and the visualizer act on raw or
     processed audio; share one AudioContext.
   - TUI: the equivalent spot in the 4.3 native pipeline.
2. **Model mini-project** (its own design doc once the seam exists): DSP
   (pitch/formant shifting) vs. on-device voice conversion, latency budget,
   browser WASM/WebGPU vs. native.

## Open items

Not scheduled; pick up when relevant.

- **Multi-node matchmaking.** Production runs one Fly machine because
  `Matchmaker` is node-local (two machines split the queue). Before scaling
  out, pick one: a cluster-wide singleton (`:global`/Horde), or a queue over
  `:pg`/PubSub that matches locally and falls back to remote.
- **CI.** None; `main` is the deployed branch and nothing runs
  `just precommit` on push. Simple option: a GitHub Actions workflow running
  precommit + `just smoke` (deploys stay manual). Owner's call.
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
