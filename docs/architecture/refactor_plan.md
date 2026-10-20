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

Stage 1 (browser interop) is in progress: the helper places and answers
WebRTC calls (str0m), the TUI drives them from the pure `Tui.Media.State`,
and `just tui-smoke` runs an automated TUI ↔ headless Chrome call in both
roles with audio checked both ways. Next: STUN/TURN candidates (calls across
NATs, real coturn), the str0m-vs-webrtc-rs checkpoint, then a live call. See
`tui_audio.md` Stage 1.

Stage 0 code is done:
- the helper (`clients/tui/native`, crate `randos_media`) speaks a JSON Port
  protocol (requests with ids, replies, events) and runs a cpal → Opus → cpal
  loopback (≈81 ms pipeline latency measured);
- `Tui.Media` owns it (pure `Tui.Media.Protocol`), under `Tui.Supervisor`
  next to `Tui.App`, so a helper crash restarts only the helper;
- `t` on the TUI's idle screen runs a 5 s mic test through it.

**Headphone test: done (2026-10-19).** On Bluetooth (Shokz OpenRun Pro 2),
≈290 ms mouth-to-ear (≈192 ms of it Bluetooth), no feedback or glitches, no
mic prompt (the terminal already had access); the TUI's mic test matched.
It also moved resampling into Stage 0, since the headphones offer only
44.1/16 kHz. Details in `tui_audio.md`.

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
eye, before anything touches a real call. (Design reviewed with the advisor
2026-10-19.)

### Decisions (2026-10-19)

1. **Processors are written once, in Rust** (one implementation, no
   competing versions in different languages). Each variant compiles two
   ways: to WASM for an AudioWorklet (the lab and the browser call) and
   natively into the media helper (the TUI). The lab therefore tests exactly
   what both clients run. This replaces the 4.3 plan to prototype in Elixir;
   Elixir/Nx stays an option only for model-based experiments that can't be
   expressed this way.
2. **Bundles follow the first-party, same-origin rule** (AGENTS.md; the
   rule was broadened from "only `app.js`/`app.css`" to the security
   properties it protects, so this needs no exception):
   - worklet processors are their own esbuild entry points (or static files
     under `priv/static/`), served from our own origin, because
     `audioWorklet.addModule(url)` loads each one from its own URL;
   - the lab UI is a separate `voice_lab.js` entry built only with
     `dev_routes`, so dev code never ships;
   - shippable processors live under `assets/js/randos/voice/` (the winner
     joins the production call path); only the lab UI goes under
     `assets/js/voice_lab/`.

### Plan

1. **Seam first.** One explicit spot in each client's audio path between the
   mic and the call, with a pass-through default:
   - Browser: in `WebRTCClient.startConnection()`, after `captureLocalAudio()`
     and before `addTrack`: `localStream = await processLocalStream(rawStream)`.
     Teardown must stop the *raw* tracks and close the processor's
     AudioContext; decide whether mute and the visualizer act on raw or
     processed audio; share one AudioContext, created at the capture rate
     (48 kHz) so the seam doesn't add a resampler.
   - TUI: the equivalent spot in the helper's pipeline (its `Processor`).
   - **Done when** `just smoke` passes with pass-through *in the call path*
     and the lab has measured pass-through latency (a worklet hop costs at
     least one render quantum plus destination buffering). That number is
     the budget every real variant is measured against.
2. **Voice lab (local web page).** A dev-only LiveView at `/dev/voice-lab`,
   inside the existing `dev_routes` scope, so it never ships to production
   (the phoenix-framework skill applies; canvas hooks need
   `phx-update="ignore"`).
   - **One file per variant.** Sliders come from the processor's own
     AudioWorklet `parameterDescriptors` (name, default, min, max), so there
     is no separate manifest to keep in sync; a few static fields add display
     name, description, and which clients it runs in. A pass-through
     baseline is always present.
   - **Sources.** Bundled, openly licensed speech clips chosen to span the
     pitch range on purpose (low and high voices, where anonymization quality
     diverges), with a license/attribution file next to them; a test tone;
     and the live mic.
   - **Comparison works on rendered clips.** Every variant of a clip is
     rendered up front with `OfflineAudioContext`: deterministic, faster than
     real time, and exactly in sync. That gives instant switching at the same
     position, blind A/B, parameter sweeps, and side-by-side spectrograms.
   - **Live mic is a separate "listen live" mode:** real time to headphones
     with a level meter and nothing else. Nothing is recorded, stored, or
     uploaded (README product constraints).
   - **Honest numbers.** CPU cost is the offline render time divided by the
     clip length (real-time factor). Algorithmic latency comes from
     cross-correlating each rendered output with its input. (Check which
     timing APIs `AudioWorkletGlobalScope` actually has before promising
     per-frame timing.)
   - **Same code as the call:** variants plug into the seam function the
     browser call uses, so a lab winner is one setting away from a real call.
3. **Built in stages.**
   - **v0:** seam + pass-through + one pitch-shift variant, offline render,
     play and switch, spectrograms. Enough to start judging results.
   - **v1:** blind A/B, parameter sweeps, pitch tracks, real-time factor and
     latency numbers, listen-live mode.
   - **v2:** comparison write-ups.
4. **Comparison write-ups.** After each round, a report page: variants
   tried, their numbers, spectrogram images, blind A/B results, a
   recommendation, and the processed clips embedded so the report can be
   listened to. Only bundled clips, never a recording of anyone's voice.
5. **Model mini-project** (its own design doc once the lab exists): DSP
   (pitch/formant shifting) vs. on-device voice conversion, latency budget,
   browser WASM/WebGPU vs. native, and how much anonymity each actually
   gives (a speaker-similarity check belongs in the lab once there's a
   candidate model).

## One call policy for both clients (2026-10-20, decided; in progress)

Goal: the TUI and the browser are different UIs over the same behaviour.
The server side is already shared (`Randos.Participant`, `ParticipantShell`,
matchmaking, `CallCoordinator`, `Randos.Signaling`, `Lifecycle`). The
duplication is the clients' call-health policy: `Tui.Media.State` and
`webrtc_client.js` each run a small state machine about connection health,
in two languages. The fix isn't sharing code between Elixir and JS; it's
moving the policy to the one place both clients already trust. Reviewed
with the advisor.

### Findings (verified in code)

- **The server never decides a call failed.** `CallCoordinator` relays
  `connection_established` but ignores it, starts the call clock 750 ms
  after the match whether or not media connected, and has no
  "never connected" timeout. A call whose media never comes up runs its
  full segment unless a client reports `connection_failed`.
- **The TUI can't self-report a hard failure.** str0m's ICE has no `Failed`
  state ("we never end trickle ice"), so a TUI call that never connects sits
  in `Checking` forever; only the TUI's own 5 s grace (after a
  `disconnected`) can fail it.
- **The clients disagree on local failure, and the browser's choice loops.**
  If the browser can't start (mic denied, no mic), it sends
  `connection_failed`. That ends the call without `stop_after_call?`, so
  both participants go back to `:looking` and rejoin the queue
  (`Randos.Participant`): the mic-denied user is rematched and fails again,
  dragging each partner through it. The TUI sends `end_call` for the same
  case (only the peer is requeued). Read from the code, not yet reproduced.
- ~~Neither client drops stale signals.~~ Corrected on implementation:
  `Randos.Participant` already pushes a signal only if its `call_id` is the
  participant's current call, so stale signals never reach either client.
  One filter, in the shared core; no client-side copies needed.
- **Duplicated policy:** the 5 s disconnected grace (`DISCONNECTED_GRACE_MS`
  and `@disconnected_grace_ms`); "send `connection_established` once";
  tearing down on a peer's `connection_failed` / `peer_disconnected`
  (`TEARDOWN_SIGNALS` and `remote_signal/3`), which duplicates the server
  ending the call and pushing the new status anyway; the browser's
  `DEFAULT_ICE_SERVERS` fallback, which duplicates `RandosWeb.IceServers`
  and hides misconfiguration. The lifecycle payloads also differ
  (`{[source]: state}` vs `{helper: "connected"}`); harmless only because
  the server ignores them.
- **Already single-sourced:** the language list (server-rendered for the
  browser, join reply for the TUI); status strings (server-rendered, or
  parsed per `participant_channel.md`); call timing (`Lifecycle`).
- **Legitimately client-specific:** countdown rendering from
  `*_deadline_unix_ms`; buffering candidates until the remote description
  is set (a WebRTC API requirement); the media stack (Opus settings, mute,
  devices); how "I left" is detected (page unload vs channel close). The
  server maps those two to different `ended_reason`s (`peer_disconnected`,
  `disconnected`) for the same human event; it could unify them.

### Proposal (recommended: option A, staged)

- **A. The server owns call health; clients report raw media state.** One
  signal type replaces `connection_established` / `connection_failed`:
  `media_state` with `{"state": "connected" | "disconnected" | "failed",
  "reason"?}`. `CallCoordinator` keeps each participant's media state and
  owns the timers (following its `@overridable` millisecond settings, so
  tests stay fast and deterministic):
  - a connect timeout: not both `connected` within N s → ends `:connection_failed`;
  - the disconnected grace (5 s) → ends `:connection_failed`;
  - `failed` → ends `:connection_failed`.
  The `state` push's `call` map gains `media: %{self, peer}`, so both UIs show
  "peer connecting…" from server state, and the server stops relaying
  lifecycle signals to the peer. Clients tear down only on the server's
  status change; `TEARDOWN_SIGNALS` and the TUI's equivalent go away. The
  old signal types stay accepted for one release (a cached page can outlive
  a deploy).
- **B (not recommended): the server pushes the constants** (grace, timeouts)
  and clients keep their logic. That still leaves two copies of the logic.
- **Protocol simplifications either way:**
  - `ice_servers` move into the `state` push's `call` map, so the TUI gets
    them atomically like the browser does (today it handles either arrival
    order);
  - a documented rule to drop signals whose `call_id` isn't the current
    call;
  - one payload shape for media-state reports.
- **`participant_channel.md` gains "Client obligations"**: the single list of
  what a client must report and when (start on `in_call`, report media
  state, local failure → `end_call`, drop stale `call_id`s, tear down on
  status change). Both clients are tested against that list.

### Drift guards

Once the policy is on the server, the end-to-end harnesses test the
clients' *obligations*, the same scenarios for both, asserting the
server-observed status on both sides:
- peer hangs up;
- media dies mid-call (`kill -9` the helper; `pc.close()` in Chrome via the
  `__randosPeers` hook);
- never connects (an unreachable `bind_ip` for the TUI; Chrome with
  non-proxied UDP disabled);
- local start failure (getUserMedia rejecting via the page init script; the
  TUI without a helper).

These run in `just smoke` and `just tui-smoke` (and CI); the scenario lists
must match "Client obligations". The coordinator gets unit tests for each
timer.

### Decisions (owner, 2026-10-20)

- **Option A**, accepting that the server now manages call health.
- **Local start failure → `end_call` in both clients** (no drift).
- **Connect timeout: configurable, default 15 s.** The 10-minute clock
  starts **once both sides report `connected`** (`in_call` then means audio is
  up), replacing the fixed 750 ms activation. Text-only pairs (both
  `audio?: false`) activate as before, since they never connect media.
- **Drop the browser's `DEFAULT_ICE_SERVERS`** (the TUI doesn't share it).
- **Before STUN/TURN.**

Implementation order (advisor): (a) clients start media on `connecting`, not
`in_call` (otherwise clients and server would wait on each other); (b)
`Lifecycle` timers, `media_state` in `Signaling`, the coordinator, both
clients reporting raw state, `end_call` with a reason; (c) `ice_servers` in
each participant's state push, stale `call_id` filtering, "Client
obligations" in the protocol doc; (d) drift-guard scenarios in both e2e
harnesses. Done: (a), (b), (c): the call's `ice_servers` and both sides'
`media` now come in each participant's `state` push (the separate
`ice_servers` push is gone), error text comes from the server
(`RandosWeb.ParticipantErrors`, sent as `error_message`), and
`participant_channel.md` has a numbered "Client obligations" section; (d):
the obligations are checked in both e2e harnesses (table in
`participant_channel.md`); `just smoke` / `just tui-smoke` run the server with
a 4 s connect timeout. Writing them found a real bug: an instant rematch
(same render) kept the previous call's `#webrtc-audio` element and WebRTC
hook; the element is now wrapped in `#call-media-<call id>`, so every call
gets a fresh hook. **All four steps are done.**

### Proposal as reviewed

1. **Option A** (server owns call health) vs B vs status quo.
2. **Local start failure → `end_call` in both clients.** This changes
   production browser behaviour (mic denied sends `connection_failed` today,
   and requeues both people).
3. **Connect timeout value** (e.g. 20–30 s), and **when the call clock
   starts**: at the match (today, plus 750 ms) or once both sides report
   `connected`. In other words, does connecting time count against the
   10 minutes?
4. **Drop the browser's `DEFAULT_ICE_SERVERS`** (the server always pushes;
   a silent fallback hides misconfiguration).
5. **Order:** do this before STUN/TURN (recommended; Stage 1 paused here).

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
  anonymizer is written once in Rust (WASM in the browser, native in the
  helper). See
  [`tui_audio.md`](tui_audio.md).
