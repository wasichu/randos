# Refactor Plan (October 2026)

Status: proposed. Written after the toolchain/deps refresh (Elixir 1.20.4 /
OTP 29.1.1, Phoenix 1.8.15, LiveView 1.2.12, Ash 3.36) landed green.

## Goals this plan serves

1. **A TUI participant client** (ex_ratatui) alongside the web UI. Decided:
   the TUI must never attach to production Erlang nodes or be served over SSH.
   It is a standalone client (Burrito binary) that talks to the server exactly
   like a browser does: over a public socket API. Audio comes last (ex_webrtc +
   a native audio NIF).
2. **Voice anonymization**, run locally on the user's device (DSP and/or a
   small generative model). The server stays media-blind (README philosophy).

Both goals need the same thing from the codebase: the participant's
conversation flow pulled out of `RandosWeb.HomeLive` into a UI-agnostic core,
reachable over a transport that isn't LiveView-specific.

## Current-state findings

| Finding | Evidence | Severity |
| --- | --- | --- |
| `CallSession` ETS rows are created and updated but never read or destroyed: unbounded growth in prod | `CallCoordinator.create_call_session/1`, `end_call/2` (`Ash.update!` only) | **Bug** |
| `AnonymousSession` unused outside its own test | no references in `lib/` | Dead code |
| `PageController` / `PageHTML` / `page_html/home.html.heex` unrouted; `PageControllerTest` actually exercises `HomeLive` at `/` | `router.ex` routes `/` to `HomeLive` | Dead code / misnamed test |
| `ash_phoenix` used only for `AshPhoenix.Plug.CheckCodegenStatus` (no-op without migrations) | `endpoint.ex:39` | Unneeded dep |
| daisyUI still imported; only `toast` (flash) and `card` (theme toggle) are live; `badge` is in the dead page | `app.css`, `core_components.ex:59`, `layouts.ex:127` | Contradicts AGENTS.md rule |
| Participant flow (state, matchmaking join/leave, call assigns, signal relay, roles) lives in an 852-line LiveView | `home_live.ex` `transition/2` … `roles_for/2` | Blocks the TUI |
| Vocabulary drift: UI `:in_call` vs coordinator/Ash `:active`; `mock_call_*` PubSub messages are real now | `ConversationFlow`, `CallCoordinator.broadcast/2` | Confusing |
| Calls are anonymous children of the `DynamicSupervisor`; no index by id | `Application` | Needed later for lookup |

## Phase 1: mechanical cleanup (small, separate commits)

1. **Fix the ETS leak.** Destroy (or stop persisting) the `CallSession` record
   when a call ends. Add a test asserting the table is empty after a call ends.
2. Delete `PageController`, `PageHTML`, `page_html/`. Move the two `/`
   assertions into `home_live_test.exs` (using element IDs) and delete
   `PageControllerTest`.
3. Delete `AnonymousSession` and its test.
4. Remove `AshPhoenix.Plug.CheckCodegenStatus` and the `ash_phoenix` dep.
5. Remove daisyUI: rewrite flash `toast` and theme-toggle `card` in plain
   Tailwind, drop the `@plugin` blocks and `assets/vendor/daisyui*.js`, then
   remove the caveat from AGENTS.md.
6. Rename `mock_call_*` → `call_*` messages across coordinator, LiveView, tests.
7. **Ash decision checkpoint** (see below), made with Phase 1 done.

## Phase 2: the spine (a UI-agnostic participant core)

Functional core, imperative shell:

- `Randos.Participant` — a struct (preferences, ui state, match, call status,
  deadlines, extension count, webrtc role) plus a pure
  `handle(state, event) :: {state, [effect]}`.
  - Absorbs `ConversationFlow`, plus HomeLive's `join_matchmaking`,
    `maybe_leave_matchmaking`, `assign_match`, `assign_call_state`,
    `finish_call`, `relay_client_signal`, `roles_for`, `parse_state`.
  - Inbound events defined once: user intents (`:find`, `:hang_up`,
    `:next`, `{:vote, v}`, `{:signal, type, payload}`) and server events
    (`{:matched, m}`, `{:call_active, c}`, `{:extension_pending, c}`,
    `{:extended, c}`, `{:call_ended, c}`, `{:signaling, msg}`).
  - Effects are data: `{:join_queue, attrs}`, `{:leave_queue}`,
    `{:relay_signal, …}`, `{:vote, …}`, `{:push_client, event, payload}`.
  - One state vocabulary shared with the coordinator (pick `:active`).
- `HomeLive` becomes a thin shell: map `handle_event`/`handle_info` to
  events, run effects as process calls / `push_event`, render. Function
  components move to `RandosWeb.HomeComponents` if HomeLive is still large.
- Tests: exhaustive pure transition tests on `Randos.Participant`;
  `home_live_test.exs` shrinks to rendering + wiring.

## Phase 3: public participant transport (a Channel)

The TUI can't use LiveView, and must not use distribution or SSH. So:

- Add `RandosWeb.ParticipantSocket` + `ParticipantChannel` ("participant:<id>")
  that runs the same `Randos.Participant` core and maps effects to channel
  pushes. Anonymous: the server mints the participant id at join, like `mount`
  does today. Rate-limit joins and validate payloads (it's a public API).
- Signaling messages go over the channel unchanged (`Randos.Signaling` already
  defines the boundary).
- Optionally, move the browser onto the channel too, so both clients use one
  protocol. Defer the decision until the TUI exists. LiveView-as-shell is fine.
- Add a `Registry` for call coordinators (by call id), needed for reconnects and
  any observability.

## Phase 4: TUI milestones

1. **Local dev monitor (first milestone, cheap).** `mix randos.top`, run inside a
   *local dev* node only: queue depth (`Matchmaker.snapshot/0`), live calls via
   the Registry, recent transitions. Never deployed, never networked. It's a
   learning ramp for ex_ratatui (callback runtime, headless test backend), not
   a product.
2. **Text-only participant client.** A separate Mix project/app under
   `clients/tui` (keeps ex_ratatui's NIF out of the server release) using a
   Phoenix-channels client (e.g. Slipstream) against Phase 3's channel: choose
   languages, queue, match, timers, extension votes, hang up. Audio is a stub.
   This gives the whole UX loop without media.
3. **Audio.** ex_webrtc for the peer connection plus a native capture/playback
   path (e.g. a Membrane PortAudio plugin or a small Rustler NIF). Its own
   design doc first: device selection, echo cancellation (no browser AEC!),
   Opus, TURN credentials via the channel.
4. Distribution: `mix ex_ratatui.gen.burrito` for single-binary releases.

## Phase 5: voice anonymization seam

- Browser: one explicit `processLocalStream(stream) -> stream` slot in
  `assets/js/randos/media.js` between `getUserMedia` and `addTrack`
  (AudioWorklet / insertable streams), with an identity default. Every
  anonymizer plugs in here, so the server never sees audio.
- TUI: the equivalent slot in the native audio pipeline from Phase 4.3.
- Model work (DSP pitch/formant shifting vs. on-device voice conversion,
  latency budget, browser WASM/WebGPU vs. native) becomes its own mini-project
  doc once the seam exists.

## Ash: decision criteria for the Phase 1 checkpoint

My read: the hunch is mostly right. Ash earns its keep when there's durable
data, authorization policies, multiple generated interfaces (JSON:API,
GraphQL, admin), or a lot of business rules over persisted records. Randos
deliberately has none of that: no persistence, no accounts, no policies,
and the only CallSession behavior relied on is a six-transition state machine
that `ConversationFlow` already shows can be a 30-line module. The realtime
logic that matters lives in GenServers, where Ash doesn't help.

Keep Ash if, after Phase 1, any of these is true:
- the Phase 3 channel API would benefit from Ash actions/validations as its
  input contract (typed action arguments, validations), or
- you want policies (e.g. rate limits, abuse reports) modeled declaratively, or
- learning Ash is itself a goal here.

Otherwise replace `CallSession` with a struct + `Randos.Calls.Lifecycle`
(transitions + constants) and drop `ash` and `ash_state_machine` (`spark`
follows), plus the `ash-framework` skill entry in `usage_rules/0` in `mix.exs`.
(`usage_rules`/`igniter` stay; they generate AGENTS.md and the skills.) Expect faster compiles and a much smaller
CVE surface (Ash had 24+ advisories against the version we upgraded from).

## Suggested commit order for the work already done

1. Tooling: `mise.toml`, `Justfile`, `.gitignore`.
2. Deps: `mix.exs`, `mix.lock`, `config/config.exs`, `Dockerfile`, formatter-only template diffs.
3. Agents: `AGENTS.md`, `.claude/`, `.mcp.json`, `.ignore`, `USAGE_RULES.md` removal, Tidewave plug.
