# randos roadmap

Verified against the code at `13902a9` (2026-10-21). Update this line, and
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
| 4 | TUI | 4.1, 4.2 done; 4.3 Stages 0 and 1 done, **next: 4.3 Stage 2** (see 4.3 below); then 4.4 release binaries and 4.5 Homebrew tap |
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

### 4.3 Audio (Stages 1 to 3 done; packaging next)

Design: [`tui_audio.md`](tui_audio.md). Proposed: all media in one Rust helper
run as a Port (str0m, Opus via libopus, cpal), Elixir keeps signaling and UI;
`ex_webrtc` rejected for its in-VM NIFs (OpenSSL, libsrtp) compiled on users'
machines. Staged: skeleton → browser interop with real TURN → hardening → AEC.

Stage 1 (browser interop) is built: the helper places and answers
WebRTC calls (str0m), the TUI drives them from the pure `Tui.Media.State`,
and `just tui-smoke` runs an automated TUI ↔ headless Chrome call in both
roles with audio checked both ways. STUN is done: the helper gathers a
server-reflexive candidate and trickles it (checked against Google's STUN
server and a hermetic fake one). TURN is done too: one relay allocation per
call via `turn-client-proto`, trickled as a `relay` candidate (hermetic fake
TURN server; coturn checked with bogus credentials). The str0m-vs-webrtc-rs checkpoint
passed: a whole relay-only call runs through our coturn (`just turn-check`),
so we stay on str0m (see `tui_audio.md`). The end-of-Stage-1 code-quality
pass is done (below). **Live call: done (2026-10-20)**, TUI ↔ Safari on an
iPad through `just dev-turn` on the same network, with each side answering
once: both worked, connected quickly, no dropouts. Within earshot (and with
noise-cancelling headphones) each person also heard the other through the
air, slightly offset: expected without echo cancellation (Stage 3), and
worth a line in the headphones advice. Still to try: the same call across
real networks (iPad on cellular, against production), which is what
exercises STUN/TURN. See `tui_audio.md` Stage 1.

**Stages 2 and 3 (done 2026-10-21; the owner asked for both, no open
design decisions).** All seven items below are built, each with tests,
the relay ones also against coturn (`just turn-check`: four calls/tests).
Order, one commit each, reviewed with the advisor:
1. Relay permissions for every known remote candidate when the allocation
   comes up (the open item below; live-test follow-up).
2. Mute: the helper sends silence and keeps RTP flowing (a stopped stream
   looks like a stall to the peer); Port contract only, as browser mute
   isn't signalled either.
3. The call's path (direct or relayed) in `call_stats` and the TUI's Status.
4. Packet loss: Opus in-band FEC on one-frame gaps, concealment sized from
   the RTP timestamp gap (capped), tested with injected loss.
5. Device selection: list devices, choose them for a call; in-session only.
6. Stage 3, echo cancellation with `sonora` (BSD-3-Clause, a pure-Rust port
   of WebRTC's audio processing; `aec3` if it falls short): render audio fed
   as it's played, capture processed before encoding, never on the mic-test
   loopback (it would cancel your own voice). Tested with a synthetic echo
   (echo reduction and near-end passthrough), then the "headphones
   required" advice becomes "recommended".
7. `turns:` (TURN over TLS, coturn serves it on 5349) as a fallback when the
   UDP allocation isn't up within a few seconds; last, as the heaviest item
   (TLS over a TCP stream in the session loop, `ring`).

Not planned: ducking (superseded by echo cancellation); Firefox stays a hand
test (the e2e harness speaks CDP, Firefox needs WebDriver BiDi). Only a person
can verify echo cancellation on real speakers, Firefox, and `turns:` on a
UDP-blocked network.

Stage 0 code is done:
- the helper (`clients/tui/native`, crate `randos_media`) speaks a JSON Port
  protocol (requests with ids, replies, events) and runs a cpal → Opus → cpal
  loopback (latency measured; see `tui_audio.md`);
- `Tui.Media` owns it (pure `Tui.Media.Protocol`), under `Tui.Supervisor`
  next to `Tui.App`, so a helper crash restarts only the helper;
- `t` on the TUI's idle screen runs a 5 s mic test through it.

**Headphone test: done (2026-10-19)**, on Bluetooth: no feedback, glitches,
or mic prompt; it moved resampling into Stage 0. Results in `tui_audio.md`.

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

### 4.4 Distribution (done 2026-10-21: v0.1.0 released)

A `mix release` directory, not Burrito: Homebrew installs a directory
well, and nothing unpacks to a cache on first run. `just tui-release`
makes `dist/randos-VERSION-OS-ARCH.tar.gz` (~18 MB: ERTS, the app, the
media helper in `priv/`, and `bin/randos`, `Tui.CLI`'s wrapper, which
follows symlinks) and checks the unpacked copy (`--version`, `--check`).
Installed builds default to production and log under the user's cache
directory. The macOS release links nothing outside the system (this
Erlang's crypto has OpenSSL built in); Linux is checked in CI.
`.github/workflows/release.yml` builds macOS arm64 and Linux x86_64 on a
`v*` tag (the tag must match `mix.exs`'s version) and attaches them to a
GitHub release; run by hand it only builds artifacts. No tag has been
pushed: releasing is the owner's call.

### 4.5 Homebrew (custom tap) (done 2026-10-21: v0.1.0 is installable)

**Live:** `brew install wasichu/randos/randos` installs v0.1.0 from the
`wasichu/homebrew-randos` tap (checked on macOS arm64: install, `--version`,
`--check`; the formula passes `brew test` and `brew audit --strict`). Each
new version: bump `clients/tui/mix.exs`, tag `vX.Y.Z`, then commit
`just homebrew-formula X.Y.Z` to the tap (automating that needs a token).
Linux through Homebrew is untested.


**Built:** `packaging/homebrew/` (the formula template, `render.sh`, and the
owner's remaining steps). The rendered formula installs and passes
`brew test` through a local tap pointed at a locally built archive. Left
for the owner: the `wasichu/homebrew-randos`
repository, the first `v*` tag, and publishing the rendered formula there
(`just homebrew-formula VERSION`); automating that last step needs a token
for the tap repo. The plan below stands.

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

## Phase 6: UI translations (after the first release; alongside Phase 5)

Numbered after Phase 5 but started first: after 4.4/4.5 ship, before the
voice lab gets going, and worked on in parallel with it. Scoped 2026-10-20;
design details when we get there.

**Where it starts.** The web UI already wraps ~80 strings in `gettext`
(home components, About, layout, `ParticipantErrors`); only `errors.pot` has
ever been extracted, and there are no translations or locale selection.
Language names are already endonyms (`Randos.ConversationLanguages`), so they
need no translation. The TUI's own strings aren't in gettext (decide whether
it gets translated, or stays English).

**Languages.** The 14 non-English practice languages: es, zh, hi, ar, pt,
bn, ru, ja, fr, de, ko, it, tr, id. Arabic needs right-to-left layout.

**Plan**
1. **Plumbing.** `mix gettext.extract --merge` into `default.pot` and one
   `.po` per locale; a CI check that the template is current. Locale from an
   explicit choice (a small switcher kept in the browser: no account, no
   tracking), then `Accept-Language`, then English; missing strings fall back
   to English. RTL for Arabic. Interpolation only via `%{name}` (no string
   concatenation), translator comments (`#.`) where context matters.
2. **Translation shootout** (the AI-engineering part). Several open models
   translate every string into every locale; automated checks score them; the
   winner per language ships. Candidates, evaluators, licenses, and memory
   needs are in [`translation_models.md`](translation_models.md) (researched
   2026-10-20): front-runners Hy-MT2 (Apache-2.0, all 14 languages) and
   TranslateGemma (Gemma terms), with MADLAD-400, M2M100 and Opus-MT as
   baselines and a general LLM; NLLB, Tower, and Aya are out (non-commercial).
   Checks, none needing a human:
   - placeholders (`%{count}`) and glossary terms ("rando", "randos") intact,
     length sane (buttons), script correct for the locale;
   - back-translation to English, compared with the source (chrF);
   - reference-free quality estimation with two independent models
     (MetricX-24 and COMET-Kiwi): TranslateGemma was trained on MetricX, so
     never rank on MetricX alone;
   - an LLM judge for tone (calm, informal) as a tiebreaker.
   **Hardware bound:** everything runs locally on the owner's machine (Apple
   M5 Pro, 48 GB unified memory, ~36 GB usable by the GPU): dedicated
   translation models at any size listed, LLMs up to ~32B at 4-bit (MLX),
   nothing 70B-class. ~1,100 short strings in all, so memory, not speed, is
   the limit. The LLM tone judge comes from a different family than any LLM
   contestant (models favour their own output). Tooling (Python,
   `transformers` on MPS, `mlx-lm`) lives in its own directory and pinned
   environment, never in the app's dependencies.
3. **Results as documentation.** A page or diagram of the shootout: scores per
   model and language, where models disagree, what failed the checks. It
   doubles as the record of why each language uses the model it does.
4. **No human review, so make fixes easy.** Machine translations ship as
   they are (check how gettext treats `fuzzy` entries at runtime: don't mark
   shipped strings fuzzy if that hides them); a short "help fix a
   translation" note points to the `.po` files on GitHub (a PR or an issue).
   Human fixes must survive re-runs: the pipeline only fills untranslated
   entries unless asked to redo a language.

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

## One call policy for both clients (done 2026-10-20)

**Goal:** the TUI and the browser are different UIs over the same behaviour.
Both clients used to run their own call-health state machine (5 s grace,
"send `connection_established` once", teardown on a peer's signal), in two
languages. The fix moved that policy to the one place both trust.

**What changed (option A, owner's decisions):**
- `CallCoordinator` owns call health from clients' raw `media_state` reports:
  `in_call` (and the call clock) only once both sides are connected; ends
  `connection_failed` on the connect timeout (configurable,
  `RANDOS_CONNECT_TIMEOUT_MS`), a disconnected grace, or `failed`. Text-only
  pairs activate as before. Values live in `Randos.Calls.Lifecycle`.
- Clients start media at the match (`connecting`), report raw state, tear
  down on the server's status, and end a call they can't carry with
  `end_call` + a reason (no more `connection_failed`, which requeued both and
  could loop for a mic-denied browser user).
- Each participant's `state` push carries the call's `ice_servers` and both
  sides' `media`; error text comes from the server (`error_message`,
  `RandosWeb.ParticipantErrors`). The browser has no default STUN server.
- The spec is "Client obligations" in `participant_channel.md`, checked for
  both clients in both e2e harnesses (coverage table there); diagrams in
  `call_flow.md`.

**Found along the way:** the server never decided a call failed; str0m has
no ICE `Failed` state (a TUI call could sit in `Checking` forever); and an
instant rematch reused the previous call's browser WebRTC hook (fixed by
keying the element by call id). Stale signals were never a client problem:
`Randos.Participant` already drops signals for other calls.

## DRY pass over Phase 4.3 Stage 1 (done 2026-10-20)

Before STUN/TURN; no behaviour changes. Rule: shared logic in one place,
environment-specific code only where the environment differs. Reviewed with
the advisor. Each item: **extract**, **merge**, **link**, or **leave** (with why).

**Rust helper**
- **Extract `audio::Devices::open`**: `Loopback::start` and `Call::start`
  repeat ~20 lines (open capture and playback, play the streams, name them),
  and the call imports `Started` from the loopback. `Started` moves to `audio`.
- **Extract a `Peak` level tracker** (max rms, `dbfs`, reset per report) next to
  `codec::rms`: the loopback inlines the dB formula, the call has a function.
- **Leave the two `Report`s**: they report different facts (latency breakdown
  vs packets and levels each way); a generic report would be the wrong
  abstraction. The once-a-second gate is four lines.
- **Leave the two thread lifecycles**: different stop mechanisms (a flag vs a
  command channel); revisit if Stage 2 adds a third worker.
- **Leave** the dropped-frame rule: it already lives once (`Playback::write`).

**TUI (Elixir)**
- **Leave `Tui.Media.State` as one module** (decision 1): the one shared rule
  (a helper restart fails both features) is already a single clause, and a
  split adds a facade with no behaviour.
- **Verify `pending_signals`** (buffering signals that arrive before the call
  starts): with ICE servers now in the `state` push, a peer's signal may never
  beat our `connecting` push. Prove that with a channel-level test before
  deleting anything; otherwise leave it.
- **Leave `Tui.App`'s routing**: clean, nothing to merge.

**Tests and harnesses**
- **Extract `Tui.TestSupport`** (`clients/tui/test/support/`): `kill_helper`,
  `eventually`, `keys`, `await_model`, and the language-picking `find`,
  repeated across five test files.
- **Extract the smoke server start** in the `Justfile`: `smoke` and `tui-smoke`
  repeat the env, port, trap, and wait-for-server lines verbatim.
- **Leave the three signal-relay loops** (`call.rs` tests, `tests/port.rs`,
  `app_test.exs`): three interfaces in two languages, and each loop is its
  test's subject.
- **Leave the e2e scripts**: `cdp.mjs` is the shared part; the scripts are
  different scenarios.

**Docs: one source per fact, others link**
- Timing values: the code (`Randos.Calls.Lifecycle`). `participant_channel.md`
  states them for client authors and points there; `AGENTS.md` and this
  roadmap stop restating numbers.
- Measurements (≈81 ms, ≈290 ms): `tui_audio.md` only.
- Stage status: this roadmap only. `tui_audio.md`'s Stage 1 "Progress" block
  (already stale: it still says the TUI mirrors the browser's grace) becomes
  a link.
- Port protocol: the crate README only.
- The one-call-policy proposal above is now history: condense it to the
  decisions and outcome (decision 3).

**Browser vs TUI, still different**
- **"I left" has two `ended_reason`s**: the browser's page-hide sends
  `peer_disconnected`; the TUI closing its channel ends `disconnected`. Same
  human event. Unifying them changes server behaviour, so it's outside this
  pass (decision 2).
- **Leave**: both clients now get `media.peer` and neither shows it yet (same
  in both); `end_call` reason strings exist in three languages by necessity,
  guarded by the channel's validation and the obligation-6 tests; mute
  (browser only, Stage 2 for the TUI); the TUI holding mic audio until
  connected (a media detail).

**Decisions (owner, 2026-10-20)**
1. `Tui.Media.State` stays one module (no layers that only add indirection).
2. **Unify "I left"**, as a server-behaviour change. Done as: the TUI sends
   `peer_disconnected` when it quits, like the browser's page hide, so the
   same human event gives the same reason from both clients. `disconnected`
   keeps meaning a lost connection (network drop, crash), which a future
   reconnect grace (the "socket blip" open item) needs to tell apart.
   Obligation 7 says so.
3. The one-call-policy proposal is condensed in this roadmap (done).

**Delivered (checked after landing):**
- `audio::Devices::open` and `codec::Peak`: both workers use them; `Started`
  lives in `audio`; no copies left.
- `Tui.TestSupport`: the five files import it; no inline helper copies or
  `kill -9` snippets remain outside it.
- `test/e2e/with_test_server.sh`: the only place the throwaway server starts.
- `pending_signals`: proved unreachable (the server only forwards signals for
  the current call) and removed.
- "I left": the TUI sends `peer_disconnected` on quit (obligation 7).
- Docs: one source per fact; `call_flow.md` has the diagrams.
- Found along the way: a headless Chrome stranded by an interrupted run kept
  reconnecting to test servers. Fixed at the root: nothing a test starts can
  outlive its starter (Chrome over a DevTools pipe, a test-server watchdog,
  Port scripts exit on stdin EOF); see "Testing" in AGENTS.md.
Every commit passed `just precommit`, `just smoke`, and `just tui-smoke`.

## Quality pass at the end of Phase 4.3 Stage 1 (done 2026-10-20)

The milestone pass after STUN/TURN and the str0m checkpoint; no behaviour
changes, reviewed with the advisor. Each gate ran `just precommit`,
`just smoke`, `just tui-smoke`, and `just turn-check` (the only proof of the
relay path).

**Rust helper**
- **Extract `candidates.rs`**: `call.rs`'s session also gathered candidates
  and routed every datagram (STUN interception, TURN wrapping, the trickle
  queue). Now `Candidates` (sans-IO) owns the STUN `Gatherer`, the `Relay`,
  and the trickle; the session keeps the socket, the `Rtc`, and audio. The
  receive order and "relayed data arrives at the relayed address" moved with
  it, with unit tests.
- **Regression guard for the late trickle**: `Candidates::trickle` is tested
  with "SDP sent, mid unknown" directly (the bug once reached `main` with all
  gates green; a timing-based call test couldn't pin it, this can). Checked
  by reintroducing the bug: the test fails.
- **Merge onto `stun-types`**: one STUN codec instead of our own plus the TURN
  crate's; the RFC 5769 vector, a hand-built reply, and a new MAPPED-ADDRESS
  test guard it.
- **Extract `test_support.rs`**: the hand-built STUN reply and the fake STUN
  and TURN servers; relay-only tests moved into `relay.rs`.
- **Leave** the TURN crate's clock and `Transmit` types (contained in
  `relay.rs`), and `Gatherer`'s retransmit timer (a STUN transaction detail,
  not call policy; browsers do the same internally).

**Docs**: the helper README, `call_flow.md` (the TUI diagram and the
same/different table), and AGENTS' TUI row now cover STUN/TURN.

**Owner decisions**
- Bad TURN credentials: **fail fast** (the owner's call). The crate would
  retry for ~40 s; `Relay` now reports `Failed` on coturn's first refusal.
  No user-visible change (the server's 15 s connect timeout decides the
  call either way), no library patch; it gives up the crate's guard against
  a forged 401, which only an on-path attacker could send.
- e2e tests never reach the internet: the test server hands out no ICE
  servers (`RANDOS_ICE_SERVERS='[]'`); srflx is covered by the Rust tests.
- `relay_only` stays test-only (`CallConfig`), not a Port field; it's a
  one-line field if a user's network ever needs diagnosing.

## Quality pass before packaging (done 2026-10-21)

The milestone pass before 4.4/4.5, after Stages 2 and 3; no behaviour
changes, reviewed with the advisor. Each commit ran `just precommit`,
`just smoke`, `just tui-smoke`, and `just turn-check` where the relay path
moved.

**Rust helper**
- **Extract `report.rs` and `tls_stream.rs`** from `call.rs` (it had grown
  back to 938 production lines; now 753): the stats and meters, and the
  TCP connection under a TLS relay.
- **Extract `CallConfig::new(role)`**: six struct literals no longer repeat
  every test-only field.
- **Merge `Relay::allocate`/`allocate_tls`** onto one constructor.
- **Leave** the new client-side constants (`TLS_FALLBACK_AFTER`,
  `TLS_CONNECT_TIMEOUT`, `MAX_CONCEALED`, `LEVELS_EVERY`): they describe this
  network path or this codec, not call policy, so the server couldn't own
  them.

**TUI**
- **Extract `Tui.View`**: the screens (pure functions of the app's state)
  leave `Tui.App` (585 lines, now 231; `App.render/2` delegates).

**Tests**: a warning in every run (`participant/5`'s unused default) gone.

**Docs**: `call_flow.md` (the helper's parts and the same/different table),
`tui_audio.md` (stages done, and the checkpoint's "no C" premise, which
turned out wrong; the str0m decision holds, see there), this roadmap.

**What tests didn't catch tonight**: three bugs passed every hermetic test
and showed only against real coturn or real-device conditions (the late
trickle, two identical test tones cancelled as echo, the 4 KiB TLS drop).
That's why `just turn-check` is in the gate for relay changes, and why the
hand checks matter: echo cancellation on real speakers, Firefox, and TLS
TURN on a network that blocks UDP.

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
- **Upstream reports (the owner's call: it means posting on other
  projects).** `turn-client-rustls` 0.1.2 gives rustls one `read_tls` per
  chunk, losing bytes past 4 KiB (worked around in `Relay::recv`); and
  `str0m-rust-crypto` pulls in AWS-LC through `dimpl`'s `rcgen` feature.
- **Revisit at 4.4:** keep the TUI's device choice between sessions (a config
  file, once installed users have a config dir); today it's per session.
- **Decide after a real call:** sonora's noise suppression and gain control
  (only echo cancellation is on).
- **coturn follow-ups** for its next intentional rebuild: see
  [`coturn_audit.md`](coturn_audit.md).

## Decisions

All 2026-10-19 unless noted.

- **License (2026-10-21): AGPL-3.0-or-later.** The owner would mind someone
  running a closed, modified randos; the AGPL's network clause means anyone
  who runs a modified copy for others must offer them its source. The site's
  GitHub link offers ours. Dependencies stay permissive (`deny.toml`).

- **Order after Stage 1 (2026-10-20):** 4.3 Stage 2 (hardening, scoped by
  what the live call shows), then Stage 3 (echo cancellation), then
  packaging (4.4, 4.5); then Phase 6 (UI translations), with Phase 5's
  voice lab starting after it and running alongside; the owner works on
  the voice lab freely. Quality passes stay at their milestones (before 4.4/4.5,
  and at the start of the voice lab).

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
