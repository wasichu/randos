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

Status: items 1–6 done (`24a37a3`…`5becc85`). Item 1 also fixed a worse bug:
coordinators were `restart: :permanent`, so every ended call restarted as a
"ghost" call. Remaining Phase 1 work is the Phase-1-tagged Code quality items
below.

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

Status: core landed (`7986493`, `76261b7`, and the HomeLive shell commit).
`{:call_updated, %Call{}}` is the only call event; `Randos.Participant` is
the core; `ConversationFlow` is gone; the "End" button no longer reloads the
page; ICE servers are minted per call (§13); components live in
`RandosWeb.HomeComponents`; matches are `%Match{}`/`%Entry{}` structs (§3).
Phase 2 is complete.

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

## Ash: keep or replace (Phase 1 checkpoint)

**Decided 2026-10-19: replaced.** Calls are now `Randos.Calls.Call` +
`Randos.Calls.Lifecycle`; `ash` and `ash_state_machine` (and their transitive
deps) are gone. Guiding principle going forward: plain Elixir/OTP first, and
justify every dependency. Next: the coordinator becomes a `:gen_statem`, whose
`state_timeout`s replace the manual timer bookkeeping. The analysis below is
kept for the record.

What Ash does in Randos today, after Phase 1: one resource (`CallSession`) on
the ETS data layer, five actions, an AshStateMachine with six transitions, five
`one_of` validations and an extension-count check. `CallCoordinator` creates
the record, transitions it, and (since the leak fix) destroys it. **Nothing ever
reads it back**; every consumer reads the coordinator's own struct.

### Pros of keeping Ash

- **Declarative lifecycle.** The transition table, guards and per-action
  side effects (timestamps, `ended_reason`) live in one place, and
  `mix ash_state_machine.generate_flow_charts` draws it for free.
- **Validation as a contract.** Language codes, the ended-reason set, and the
  extension cap are enforced at the action boundary with typed errors. That's
  useful if the Phase 3 Channel takes untrusted input: an Ash action (with
  typed arguments) is a ready-made input contract.
- **Room to grow without rewrites.** If Randos ever needs abuse reports, rate
  limits as policies, a moderation/admin view, a JSON API, or *any*
  persistence (even short-lived Postgres for reports), Ash is already wired
  and those are its strengths (policies, AshJsonApi, AshAdmin, AshPostgres).
- **Introspection for the dev monitor.** Resource/action metadata and
  `Ash.read` over ETS give the Phase 4.1 monitor a queryable view of live
  calls with no extra code, if we start reading the records.
- **Signals / notifiers.** Ash notifications could replace hand-rolled
  `PubSub.broadcast` calls in the coordinator.
- **Learning value.** Ash is a large, idiomatic ecosystem; this repo is a
  low-stakes place to practice it. That's a legitimate reason on its own.

### Cons of keeping Ash

- **It's a write-only shadow of the real state.** The coordinator already owns
  `status`, timers, and votes; `CallSession` duplicates `status` (see Code
  quality §2) and nothing reads it. Two sources of truth for one lifecycle is
  a standing bug risk.
- **The product philosophy rules out its biggest wins.** No accounts, no
  persistence, no profiles, no history means no policies-over-records, no
  generated APIs over stored data, no migrations. Ash's leverage comes from
  exactly the things Randos deliberately refuses to have.
- **Weight and surface area.** Roughly a dozen extra runtime packages (ash,
  ash_state_machine, spark, reactor, ecto, splode, decimal, ets, crux,
  iterex, multigraph, yaml stack, …), ~215k lines of dependency source, and
  the 24+ security advisories we just upgraded away from. All of that is in
  the production release for a six-transition state machine.
- **Process-hot-path friction.** Ash calls run inside `handle_info` callbacks
  of a realtime GenServer; failures surface as `MatchError` crashes
  (Code quality §4) and each transition pays changeset/validation overhead
  for no reader.
- **Two mental models for one feature.** Contributors (and agents) have to know
  that call state lives in GenServers *and* in an Ash resource, and which one
  is authoritative.
- **Doesn't help the hard parts ahead.** The participant core, Channel
  transport, TUI client, WebRTC and voice anonymization are all process,
  protocol and media work; Ash has little to offer there.

### Recommendation

Replace `CallSession` with a plain `%Randos.Calls.Call{}` struct plus a
`Randos.Calls.Lifecycle` module (transition table + constants, in the style of
`ConversationFlow`), owned solely by the coordinator, and drop `ash` and
`ash_state_machine` (`spark` follows), plus the `ash-framework` skill entry in
`usage_rules/0`. (`usage_rules`/`igniter` stay; they generate AGENTS.md and the
skills.)

Keep Ash instead if, in your judgment, any of these outweighs the cons:
learning Ash here is a goal; you expect abuse reporting/moderation (policies)
soon; or you want the Phase 3 Channel's input contract expressed as Ash
actions. If Ash stays, make it pull its weight: make `CallSession` the single
source of truth for status (the coordinator reads it back), add a code interface
on `Randos.Comms` (§4), and use Ash notifiers for the call broadcasts.

## Code quality

Each item is tagged with the phase it belongs to. Nothing here is implemented
yet. Items marked **Bug** are defects, not cleanups.

### Phase 1 (small, independent)

1. **(Done in `c79ea82`.) Simplify `CallCoordinator.init/1`.** `call_coordinator.ex:77-104`
   re-derives `activation_delay_ms`, `pubsub` and the three durations with
   `Keyword.get(opts, key, CallSession.x() * 1_000)`, duplicating the struct
   defaults at `:17-32`. Build the struct once:
   `struct!(__MODULE__, Keyword.take(opts, @overridable))` then set
   `match`/`call_session`/`status`.
2. **(Done in `c79ea82`.) One source of truth for call status.** The coordinator keeps
   `state.status` (`:83`, `:181`, `:206`, `:299`, `:331`) and the same value is
   mirrored in `state.call_session.status`. `end_call/2`'s
   `if state.status == :ended` guard (`:323`) exists because of it. Resolved by
   the Ash decision: if Ash goes, `%Call{}` owns status; if Ash stays,
   read status from `call_session`.
4. **(Moot: Ash removed.) Ash calls in the coordinator.** `{:ok, call_session} =
   … |> Ash.update()` at `:175` and `:192` raise `MatchError` inside
   `handle_info`, and `Ash.update!()` at `:328` raises inside `end_call/2`.
   Add a code interface on `Randos.Comms` (`Comms.mark_call_active(call)`,
   etc.) and handle `{:error, _}` by ending the call with a reason. If Ash goes,
   this item disappears.
7. **(Done: credo in precommit; boundary deferred.) Credo.** Add `{:credo, "~> 1.7", only: [:dev, :test]}` and put
   `credo --strict` in the `precommit` alias. Recommendation on
   [`boundary`](https://hex.pm/packages/boundary) (0.11.0, maintained, Sept
   2026): **not yet**. With ~15 modules and the TUI planned as a separate Mix
   project (a natural boundary), it's mostly ceremony today. Revisit after
   Phase 3, when `Randos` core vs `RandosWeb` (LiveView + Channel) is a real
   split worth enforcing; at that point declare `Randos` and `RandosWeb`
   boundaries with `RandosWeb` depending only on the core's public modules.
8. **Multi-node matchmaking: split queue in production.** **Bug — mitigated 2026-10-19:** scaled to one machine (`fly scale count 1`). Multi-node support is still a goal; pick an option below before scaling up again.
   - Verified 2026-10-19 with `fly scale show` / `fly machines list`:
     app group `app` has **2 machines** in `ord` (`4d895d20b93158`,
     `d8d09d6fe0d148`), both shared-cpu-1x/512MB. Both were stopped at check
     time (`auto_stop_machines`, `min_machines_running = 0`), but both have
     run recently (last updated 2026-10-19 and 2026-10-13).
   - `rel/env.sh.eex` clusters the nodes via
     `DNS_CLUSTER_QUERY=${FLY_APP_NAME}.internal`, and PubSub spans nodes, but
     `Matchmaker` is registered locally (`matchmaker.ex:45-48`,
     `name: __MODULE__`). Each machine therefore has its own queue, and
     HomeLive calls the local one.
   - Whenever both machines are up, the Fly proxy can spread visitors across
     them, and two compatible people on different machines never match.
     That can happen after a deploy, or once load starts the second machine.
   - Options (not chosen):
     - pin to one machine (`fly scale count 1`; simplest, matches the
       transient design, and an ended call loses nothing);
     - a cluster-wide singleton (`:global` name or Horde) with failover;
     - a queue distributed over `:pg`/PubSub, where each node matches locally
       and falls back to remote.
   - Calls are already location-transparent: coordinator ↔ LiveView messaging
     is by pid/PubSub.

### Phase 2 (with the participant-core extraction)

3. **(Done: `Randos.Matchmaking.Match`/`Entry`, `Randos.Calls.Call`, `Randos.Participant`.) Structs at the boundaries.** `%Randos.Match{}`, `%Randos.Participant{}`
   (queue entry: id, pid, topic, languages) and `%Randos.Calls.Call{}` (what
   `public_call_state/1`, `call_coordinator.ex:370-382`, returns today) with
   `@enforce_keys` and `@type t`. Today these are maps typed only in
   `matchmaker.ex:16-31` (`@type participant`/`match`) and built ad hoc in
   `build_match/2` (`:252-260`) and `participant_from_attrs/1` (`:239-248`).
   These become the contract LiveView, Channel and TUI share.
5. **Structured logging + telemetry.** 17 interpolated `Logger` calls
   (`"call_ended call_id=#{…}"`) across `call_coordinator.ex` (11) and
   `matchmaker.ex` (6). Move ids into Logger metadata
   (`Logger.info("call_ended", call_id: …, reason: …)`) and emit
   `:telemetry` events (`[:randos, :call, :start | :active | :extended |
   :stop]`, `[:randos, :matchmaking, :join | :match | :leave]`). The Phase 4.1
   dev monitor TUI can attach to those events instead of polling; LiveDashboard
   metrics come for free.
6. **`@spec`/`@doc` on public functions.** `CallCoordinator` has 0 `@doc` and
   0 `@spec` on its public API (`start_match/2`, `hang_up/2`,
   `vote_extension/3`, `relay_signal/4`, `force_time_up/1`); `Matchmaker` has
   `@doc`s on join/leave/snapshot but no `@spec`s. Do this together with the
   structs (§3) so specs reference `Match.t()`/`Call.t()`.
10. **(Fixed in `419fbeb`.) Matchmaker: waiting participant orphaned when a call fails to start.**
    **Bug.**
    - Where: `join_queue/2`, `matchmaker.ex:143-170`. The waiting participant
      is popped and demonitored before `start_call/2`. On `{:error, _}` only
      the joiner gets `{:error, :call_start_failed}`.
    - Effect: the waiting participant is left in `:looking` forever, with no
      message and no longer in the queue.
    - `matchmaker_test.exs:36` ("does not leave queued participants behind")
      enshrines the removal but not the missing notification.
    - Fix: re-queue the waiting participant at the head, or broadcast an error
      to their topic.
11. **Matchmaker smaller cleanups.**
    - `deterministic_match_id/2` (`:283-286`): the same pair rematching (e.g.
      both press "Next" with nobody else waiting) gets the same match id.
      Prefer a random id; the hash adds nothing for anonymous ids.
    - "Next" can immediately rematch the same two people when they're the
      only ones queued. This is a product decision; consider a short
      "recently matched" exclusion.
    - `start_call/2`'s `with … else` (`:262-273`) is a no-op wrapper.
    - Queues append with `&1 ++ [participant]` (`:178`), which is O(n). Fine
      at this scale, but use `:queue` if it grows.
12. **(Fixed by `Randos.Participant`'s identity rules.) HomeLive trusts any call message.** `handle_info({:call_active, call}, …)`
    (`home_live.ex:125-139`) applies state from any call without checking it
    matches `@match`/`@call_pid`. The ghost-call bug fixed in `24a37a3` showed
    the impact. The participant core should drop events whose `call_id`
    doesn't match the current call.

### IceServers (`lib/randos_web/ice_servers.ex`)

13. **(Fixed: credentials minted per call, TTL ≥ longest call + 10 min.) TURN credentials go stale.** **Bug when TURN is enabled.**
    - Where: credentials are minted once, at full page render, into a
      `<meta>` tag (`layouts/root.html.heex:7`). `iceServersFromPage()`
      (`assets/js/randos/ice_servers.js:3`) re-reads that same tag and never
      refreshes it. TTL defaults to 900 s (`ice_servers.ex:13`).
    - Effect (verified from the code): after 15 minutes on the page, through
      repeat calls, auto-requeue, or "Next", new calls use expired
      credentials, so anyone who needs a relay can't connect.
    - Also likely, but inferred and unverified against coturn: a relayed call
      longer than the TTL can lose its allocation mid-call, since coturn
      re-checks REST credentials on refresh. Calls can run 30 min.
    - Fix (Phase 2/3): send fresh ICE servers with each match (in the
      `{:randos_match, …}` payload or a push event). Set TTL ≥ max call
      duration plus a margin.
14. (Done.) `config :randos, RandosWeb.IceServers, future_env: […]`
    (`config/config.exs:56-64`) is dead: the module hardcodes the env var
    names. Delete it, or have the module read it (Phase 1).
15. Env vars are read with `System.get_env/1` on every render
    (`ice_servers.ex:118-126`). Move them into `config/runtime.exs` so
    misconfiguration fails at boot rather than silently falling back to Google
    STUN (Phase 1).

### Browser JS (`assets/js/`)

Reviewed in full (all 11 files). Items 16 and 17 I re-verified directly; the
rest are from reading the code, and "(inferred)" means it depends on runtime
behavior nobody has tested.

16. **(Fixed in `b9ab772`, covered by `just smoke`.) Teardown during the mic prompt leaks the mic.** **Bug.** (Only via "Next"/peer hang-up: "End" does a full-page redirect, which frees the mic on its own.)
    - Where: `WebRTCClient.start()` checks `this.cleaned` only on entry
      (`webrtc_client.js:45`) and never re-checks after
      `await this.captureLocalAudio()` (`:48`).
    - When it happens: the user hangs up, presses Next, or leaves while the
      permission prompt is open.
    - Effect: the stream is still assigned (`:81`), a visualizer and rAF loop
      start (`:82`), an `RTCPeerConnection` is created (`:51`), and an offer may
      be pushed from a dead hook. Nothing stops those tracks, so the browser's
      mic indicator stays on.
    - Fix: re-check `cleaned` after every `await` in `start()`, and stop the
      stream if teardown already happened. (Phase 1)
17. **(Fixed in `b9ab772`, covered by `just smoke`.) Visualizers go blank after a call is extended.** **Bug.**
    - Where: `call_hook.js:22-23` looks up the canvases once with
      `document.querySelector`. They live in `call_panel`, which is replaced by
      `extension_panel` during `:extension_pending` (`home_live.ex:257-266`),
      while the hook element (`call_media_panel`) stays mounted.
    - Effect: after "extended", the visualizers keep drawing to detached
      canvases.
    - Fix: re-query the canvases in the hook's `updated()`, or move them inside
      the hook's own subtree. (Phase 1)
18. **(Fixed in `b9ab772`.) Signal errors are swallowed.** **Bug.**
    - Where: `call_hook.js:118` calls the async `peer.receiveSignal()` without
      `await` or `.catch`. A rejected `setRemoteDescription`, `createAnswer` or
      `addIceCandidate` (`webrtc_client.js:135-159, 212`) becomes an unhandled
      rejection.
    - Effect: no `connection_failed` reaches the server, and the call sits in
      "connecting" until someone hangs up. (Phase 1)
19. **(Fixed: signals are serialized through one promise chain gated on start().) Late signals after teardown.** Signals aren't serialized, so `close()`
    can land in the middle of `receiveOffer`, and then `createAnswer()` throws on
    null (`:138`). After `failConnection` the state is FAILED, not CLOSED, so
    the guard at `:97` lets later signals through to the queue (`:99-100`),
    which is never drained. Serialize signal handling through one promise chain.
    (Phase 2)
20. **(Fixed in `b9ab772`.) Mic denial is indistinguishable from a network failure.**
    `webrtc_client.js:85` sets MICROPHONE_DENIED, but `failConnection`
    (`call_hook.js:56`) immediately overwrites it with FAILED and reports
    `error.message`, not `error.name` (`NotAllowedError` / `NotFoundError`).
    Send the name so the UI can say "allow microphone access". (Phase 1)
21. (Fixed in `b9ab772`.) `logging.js:3` reads `localStorage` without try/catch. In some privacy
    modes that throws, which would break every `logEvent`, including those in
    `start()`. (inferred; Phase 1)
22. **(Done.) Cleanups.**
    - Two duplicate signal queues: `call_hook.js:24,112-128` and
      `webrtc_client.js:38,99-132`. The hook's queue only fills when
      `RTCPeerConnection` is missing, and then grows without bound.
    - `handleIceConnectionState`/`handleConnectionState` (`:229-278`) are near
      duplicates, and their "closed" branches can't run, because the handlers
      are nulled at `:191-194` before `close()`.
    - `close()`, `failConnection()` and `cleanupMedia()` (`:163-205`) overlap,
      with two guard flags (`cleaned`, `state`). Make it one idempotent
      `teardown(reason)`.
    - `countdown_hook.js:11-13` has a three-way selector fallback; only
      `[data-countdown-value]` is needed.
23. **Phase 2 coupling.**
    - The JS runs its own 11-state machine (`webrtc_client.js:12-24`) parallel
      to the server's. The server only sees `connection_established`,
      `connection_failed` and `peer_disconnected`. The participant core should
      treat those three as its only media inputs.
    - Teardown has two triggers, the server `hangup` signal (`:117-121`) and
      hook removal. Make the server's event authoritative.
    - `disconnected()` (`call_hook.js:66`) kills the call on any socket blip.
      Fine today, but a session-keyed core could let P2P audio survive a
      signaling reconnect; this hook would then need to change.
    - The role is read once from `data-webrtc-role` at mount
      (`call_hook.js:42`). That's only correct while `#webrtc-audio` remounts
      for every call; keep that invariant explicit.
24. **Phase 5 seam: clean, with four caveats.** The only capture site is
    `webrtc_client.js:81` and the only `addTrack` is `:58-60`, with no
    `replaceTrack` or renegotiation. So the seam is
    `this.rawStream = await captureLocalAudio(); this.localStream = await
    processLocalStream(this.rawStream)` (async, since AudioWorklet
    `addModule` is). Caveats:
    - teardown (`:187`) must stop the **raw** tracks and close the processor's
      AudioContext, because stopping the processed tracks doesn't release the
      mic;
    - decide whether mute (`:92`) toggles the raw track or the processed one;
    - decide whether the visualizer (`:82`, which opens its own AudioContext at
      `audio_visualizer.js:32`) shows raw or anonymized audio, and share one
      AudioContext;
    - fix item 16 first, since the seam adds a second `await` gap.

### Summary: real bugs vs cleanups

Bugs: §8 (split queue: mitigated by running one machine), §10 (fixed),
§13, §16, §17, §18 (fixed). Everything else is cleanup or design.
