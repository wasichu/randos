# ICE restart: design (2026-10-22)

Status: **built** (see "Outcome" below for what changed from this
proposal). Researched 2026-10-22 against `89be469`. Claims are marked **[source]** (read in our code or a
dependency's source), **[spec]** (an RFC or W3C/MDN text), or **[verify]**
(believed, not yet checked; check before building on it).

## Outcome (2026-10-22): built, with one change

The owner approved D1–D6 as recommended, then asked for consistent
behaviour across every failure. So the timers below (the disconnected
grace, the reconnect grace, the attempt timeout and count) became **one
recovery budget** (`Lifecycle.recovery_budget_seconds/0`, 15 s): from the
moment an active call turns unhealthy (media down, or someone away) it
has that long, shown as `call.recovering` ("Reconnecting audio…"), and
ends with what's still wrong. Restarts happen inside it: 2 s after
`disconnected`, at once on `failed` or on a resume with media down, then
every 5 s (`Lifecycle.ice_restart_retry_seconds/0`). Without ICE restart,
`failed` ends the call at once. ICE restart itself is as designed; the
helper's half is `call_restart`. Tested: `call_coordinator_test.exs`
(one test per scenario), `test/e2e/recovery_smoke.mjs` (two Chromes
through `test_turn`, both paths cut, and a cut with the websocket drop),
and the helper's `tests/restart.rs`. The current rules are in
`participant_channel.md` (obligations 4, 9, 10, and 11's offline limit,
added 2026-10-23); what follows is the design as proposed.

Where the helper's build differs from it: the offerer restarts with
`ice_restart(true)` after invalidating the old candidates (the new host
candidate is kept); trickled candidates carry their `usernameFragment`
(done, `Candidates::trickle`); and the helper noticed a dead path only
after ~15 s until a patched copy of str0m's `is` crate (`vendor/is`,
`vendor/README.md`) and tighter STUN timing brought it to ~4 s. A
helper whose call session stops ends the call `audio_failed`
(obligation 6), not `media_state` `failed`, since no restart can bring
it back.

## Recommendation in short

1. **Fix the sequence that ends calls today first**, before any WebRTC
   work: while one seat is `away`, the other seat's disconnected grace must
   not end the call (below). Without this, ICE restart can't help the main
   case (a network change), because the person who moved has no signaling
   for the restart to travel over.
2. **The server decides, the offerer restarts.** The `CallCoordinator`
   asks for a restart; only the client with `webrtc_role` `offerer` ever
   creates offers, so there's no glare and no rollback ("perfect
   negotiation" isn't needed). The answerer already answers any offer.
3. **The request rides on the call's state** (a generation number on
   `%Call{}`), not on a one-off push, so a request lost in a drop comes
   back in the resume reply.
4. **Timers and attempt counts live in `Randos.Calls.Lifecycle`** and run
   in the coordinator. Clients keep running no health timers of their own.
5. **No new TURN credentials are needed**, and `Randos.Signaling.relay_only/2`
   already handles restart offers unchanged.
6. **The TUI helper needs real work**: a fresh socket and fresh candidates
   on every restart, since str0m restarts ICE but the helper's socket is
   bound to the old network's address.

## What happens today when a network changes

Person A's laptop moves from Wi-Fi to cellular mid-call:

- A's websocket drops. The coordinator's `:DOWN` handler marks A `away`
  and arms `{:away, id}` for `reconnect_grace_seconds/0` (10 s)
  **[source]**.
- A's media dies too (the TURN allocation is bound to the old address,
  below). B's browser sees no traffic and reports `media_state`
  `disconnected` within a few seconds **[verify: Chrome's timing]**.
- That arms B's `{:grace, id}` timer for `disconnected_grace_seconds/0`
  (5 s) in `grace_timer/4`. Nothing pauses it while A is away
  **[source]**.
- So the call ends `connection_failed` roughly 5–8 s after the move,
  usually before A's socket is back. Obligation 9 rescues the signaling
  but never the call. Even if A resumes in time, nothing re-establishes
  the media path, so the grace still ends the call.

## What the specs say

| Topic | What it says | Where |
| --- | --- | --- |
| ICE restart | An agent MAY restart ICE. It MUST change both ufrag and pwd. All earlier state is flushed except the roles, which MUST NOT be redetermined. Data may keep flowing on the old session meanwhile. The new candidate set may reuse some, all, or none of the old candidates. | RFC 8445 §9 **[spec]** |
| Offer option | `IceRestart`: "the offer MUST indicate an ICE restart by generating new ICE ufrag and pwd"; meant for "reestablishing connectivity in cases where failures are detected by the application". | RFC 8829 §5.2.3.1; §3.5.1 (the needs-ice-restart bit) **[spec]** |
| Answerer | New credentials are made automatically for every m-section the offer restarts. Applying the description starts gathering new candidates. | RFC 8829 §5.3.2, §5.3.3, §5.9 **[spec]** |
| DTLS | If the fingerprint and tls-id don't change, "the same DTLS connection is continued over the new ICE channel". No new handshake, same SRTP keys. | RFC 8829 §5.11 **[spec]** |
| Browser API | `restartIce()` makes the next `createOffer()` a restart and fires `negotiationneeded`. "Existing media transmissions continue uninterrupted." Baseline in all major browsers since April 2021. | W3C webrtc-pc; MDN **[spec]** |
| TURN | An allocation is identified by its 5-tuple. A request from a new address or port matches no allocation (437), and indications from it are silently dropped. Allocation lifetime is 600 s by default, permissions 300 s, channels 600 s. | RFC 8656 §3.2, §3.5, §5, §9 **[spec]** |
| Trickle | Each candidate carries its ufrag, which says which ICE generation it belongs to. A candidate from the previous generation is discarded. | RFC 8829 §3.5.2.1; RFC 8838 **[spec]** |

So a network change always needs a new allocation from the new address.
RFC 8016 (TURN mobility) would let an allocation move, but browsers don't
implement it, so it isn't an option for us (coturn's `mobility` setting is
off in `infra/coturn` anyway).

## Who restarts, and when

**The server decides; the offerer acts.** `Signaling.classify/2` relays an
`offer` from either seat without checking roles **[source]**. If both
clients started restarts on their own, their offers could cross (glare),
and we'd need rollback on both clients, str0m included. With the server as
the only one who triggers a restart and the offerer as the only one who
offers, glare can't happen.

Proposed coordinator behaviour, only in `:active` and `:extension_pending`
(in `:connecting` the connect timeout already covers everything):

1. **A seat is away.** Hold the other seat's disconnected grace: don't arm
   it, or cancel it, while anyone is in `call.away`. The away timer (10 s)
   is then what bounds the outage. *(This is step 1 of the phasing below.)*
2. **A seat reports `disconnected` and both seats are present.** After
   `ice_restart_delay` (proposed 2 s, because browsers often recover by
   themselves from a short loss), if it's still `disconnected`, bump
   `call.ice_generation` and broadcast. Arm a generic timeout,
   `{:timeout, :ice_restart}`, for `ice_restart_timeout` (proposed 10 s)
   instead of the 5 s grace.
3. **Both seats are `connected` again.** Cancel the timeout. The restart
   worked and the call carries on; its clock never stopped.
4. **The timeout fires.** Start another attempt if any are left (proposed
   `max_ice_restarts` 2 per outage), else end the call `connection_failed`,
   as today.
5. **A seat resumes and media isn't connected on both sides.** Start an
   attempt at once (without the delay). It doesn't count against the
   maximum, because the previous attempt's messages may have been lost in
   the drop.

All the new constants go in `Randos.Calls.Lifecycle` beside the others,
and all the timers are `:gen_statem` timeouts in the coordinator.

**No `restarting` media state from clients.** Clients keep reporting raw
facts: `connected`, `disconnected`, `failed`. The server already knows a
restart is in flight because it asked for one. The `{:grace, id}` handler
just has to yield while `ice_generation` is mid-attempt. That keeps
`Signaling`'s `@media_states`, `Lifecycle.put_media/3` (whose guard allows
only `:connecting`, `:connected`, `:disconnected`) and both clients'
reporting unchanged, unless D3 is accepted (see there).

**Laptop sleep** longer than `reconnect_grace_seconds/0` (10 s) still
ends the call `:disconnected`: the server can't tell a sleeping laptop
from one that's gone. This design covers outages of seconds (a network
move, NAT rebinding, a short sleep), not minutes.

**Network events (`online`, `navigator.connection` `change`).** Leave
them out at first. Acting on them would be client policy. If it's wanted
later, the client reports the raw fact (e.g. `media_state` `disconnected`
with `"source": "network_change"`), and the server may skip the delay.

**`failed`.** Today the browser's `failConnection` tears the peer
connection down on `failed` and reports it, and the server ends the call
at once **[source]**. str0m has no failed ICE state, so the helper never
reports `failed` from ICE **[source]**. In browsers, `failed` usually
comes well after `disconnected` (consent freshness, RFC 7675), so the 2 s
trigger normally fires first **[verify: Chrome, Firefox, Safari timings]**.
But a restart whose new checks all fail can reach `failed`, and then the
call ends without trying again. **Behaviour change, owner's decision (D3):**
a client that declares restart support stops tearing down on `failed`. It
reports `failed` as a raw fact and waits for the status, like obligation 5
already says. The server treats `failed` like `disconnected` while attempts
remain. `handle_signal({:media, :failed}, …)` would record it as
`:disconnected`, so `put_media/3`'s guard stays as it is.

**Old clients.** A page loaded before a deploy keeps its old JavaScript,
and TUIs update slowly. So add a capability flag: `ice_restart: true` in the
channel's `find`, like `audio`. For browsers, put it in the LiveSocket's
`connect_params` (`app.js`, read in `HomeLive.mount`). That ties it to the
JavaScript the page actually loaded, which is exactly the version question. The coordinator
only restarts calls where both seats declared it; other calls keep today's
rules. The flag is a boolean about the client's version and says nothing
about the person.

## TURN credentials and relay-only

- **No fresh credentials needed.** `RandosWeb.IceServers` mints TURN REST
  credentials whose username *is* the expiry. The TTL is floored at
  `max_call_duration_seconds/0` + 600 s (default 3600 s) **[source]**, and
  they aren't tied to an address or an allocation. A new allocation from a
  new network mid-call uses the same credentials.
- A resume reply already carries fresh `ice_servers`. A client may use
  them: the browser through `setConfiguration({iceServers})` before
  `restartIce()` (an `RTCPeerConnection` otherwise keeps its construction
  config), the helper through a field on its restart command. It's
  optional, and nice to have if the TTL ever shrinks.
- **The filter needs no change.** `relay_only/2` is stateless, per message.
  It rewrites only `a=candidate:`, `c=`, `a=rtcp:` and `o=` lines and the
  `raddr`/`rport` fields. `a=ice-ufrag`, `a=ice-pwd` and `a=ice-options`
  pass through byte for byte, and so does a trickled candidate's
  `usernameFragment` key, along with a candidate line's own `ufrag …` field
  **[source]**. A restart offer is just an offer. Add one test: a real
  restart offer, relay-only, keeps its new credentials and loses its host
  candidates.
- **Stale allocations.** After a move, the old allocation can't be
  released: the Refresh with lifetime 0 would have to come from the dead
  5-tuple. So it lingers for up to its lifetime (600 s). `total-quota=400`
  in `infra/coturn/cloud-init.yaml.tftpl` counts it. That's harmless at
  today's scale; worth a line in `coturn_audit.md` when this lands.

## Browser

- **Offerer**, when `ice_generation` grows past the last one it acted on:
  call `restartIce()` (optionally `setConfiguration` first), then the
  existing `createOffer` → `setLocalDescription` → `pushSignal("offer")`
  path, then trickle as now. Send it ourselves rather than through
  `negotiationneeded`, which `WebRTCClient` doesn't listen to
  **[source]**. If an answer is still outstanding (`have-local-offer`), a
  new offer replaces it.
- **Answerer:** `receiveOffer` already handles a second offer. It calls
  `setRemoteDescription` and `createAnswer`, and the browser gathers new
  candidates **[source]**. `pendingIceCandidates` buffering is keyed on
  `remoteDescription`, which is already set, so new candidates are added
  directly. That's fine, because the server relays in order and the offer
  comes before its candidates.
- **Stale candidates:** `addIceCandidate` rejects a candidate from the old
  generation. `receiveSignal` already keeps the chain going after a
  rejection **[source]**. Just log it, without alarm.
- **Media:** tracks, DTLS and SRTP carry on. Chrome keeps sending on the
  old pair until the new one is chosen.
- **How the hook learns `ice_generation`:** as a `data-ice-generation`
  attribute on `#webrtc-audio`. The element has `phx-update="ignore"`, but
  LiveView still merges `data-*` attributes onto an ignored container
  (`DOM.mergeAttrs` with `isIgnored`) and calls the hook's `updated()` when
  its dataset changed (`View.triggerBeforeUpdateHook`) **[source]**.

## TUI and the helper (str0m 0.24.1)

**str0m supports ICE restart [source]**:
- `SdpApi::ice_restart(keep_local_candidates)` sets up new `IceCreds` for
  the next `apply()`.
- `accept_offer` detects changed remote credentials (`add_ice_details`)
  and restarts as the answerer. It always keeps local candidates
  (re-ufragged).
- `accept_answer` rejects an answer with new credentials unless we asked
  for a restart.
- `SdpApi::merge(pending)` folds an outstanding offer into a new one.
- `DirectApi::invalidate_candidate` drops an old local candidate.
- The `is` agent rejects remote candidates whose ufrag doesn't match.
- str0m ships a passing `tests/ice-restart.rs`.

**Surprises:**
- **str0m stops sending at once.** Its restart clears all candidate pairs
  (`IceAgent::ice_restart`), so audio stops until the new checks succeed.
  Browsers keep the old pair. That's a short gap when the path is already
  dead, but a cost on a false alarm; it's one more reason for the 2 s delay.
- **The helper's socket is bound to one address.** `call.rs` binds one
  `UdpSocket` to `default_route_ip()` at `call_start`. `Candidates` owns
  the STUN gatherer and one TURN allocation on that socket, and has no way
  to start over **[source]**. After a move, that socket's address is gone.
  str0m's restart alone does nothing; the helper must:
  1. bind a new socket on the current default route;
  2. build a new `Candidates` (STUN, a TURN allocation, the TLS fallback),
     and free the old one as best it can;
  3. `invalidate_candidate` the old local candidates, then
     `add_local_candidate` the new ones and trickle them.

  It must do this as offerer (`ice_restart(false)` and a new offer) and as
  answerer (on an offer with new remote credentials, since str0m keeps the
  old candidates).
- **Connected after a restart:** the helper reports `connected` again only
  if `dtls_up && !connected`, which holds when it saw `Disconnected`
  first. After a restart the peer started while our side was fine, ICE
  goes `Checking` (not reported) and back to `Connected` (not reported),
  which is correct: the server never heard `disconnected` from us. Keep it
  that way.
- **Trickled candidates:** they send `"usernameFragment": null`
  (`Candidates::trickle`), but str0m's candidate line carries
  `ufrag …` **[source]**, so receivers can still sort out the generation.
  Setting `usernameFragment` properly is cheap and clearer.

**Port protocol** (contract: change `clients/tui/native/README.md`,
`src/protocol.rs` and `Tui.Media.Protocol` together, with tests on both
sides):
- New request `call_restart`, with an optional `ice_servers`. The helper
  re-gathers and, as offerer, emits a new `call_signal` `offer`. It
  replies `true`, or `no call running`.
- No new events. `call_state` stays `connected` / `disconnected` /
  `failed`. Optionally, `call_stats` could count `restarts`.
- The answerer needs no new request: re-gathering on an offer with new
  remote credentials happens inside the helper.
- `Tui.Media.State` sends `call_restart` when the server's
  `ice_generation` grows. That's rendering server state, not a policy of
  its own.

## Signaling and obligations

- **Server → client:** `call.ice_generation` (an integer, 0 at the match)
  in `state`. No new push, and no new signal type: the offerer's restart
  is an ordinary `offer`.
- **Client → server:** the `ice_restart` capability in `find`.
- **Obligations:**
  - New **obligation 10, "Restart when asked":** the offerer restarts ICE
    (new credentials, fresh candidates, a new `offer`) whenever
    `ice_generation` grows past the last one it acted on, including the
    one in a resume reply. The answerer answers any offer.
  - **Obligation 4:** say that the server may ask for a restart before it
    ends a call, and (if D3 is accepted) that `failed` is a report, not a
    teardown.
  - **Obligation 9:** after a resume, act on the reply's `ice_generation`.
- **Lost messages** (add a row to "What a drop can lose"). The coordinator
  relays to the peer's topic with `PubSub.broadcast`, so a restart offer
  sent while the peer is away goes nowhere **[source]**. That's why rule 1
  defers restarts while anyone is away, and rule 5 bumps the generation on
  resume. Whoever lost what, the offerer makes a fresh offer, so nobody
  resends old messages and the server stores no SDP. A lost
  `ice_generation` change is put right by the join reply's `state`.

## Testing

Everything stays offline and dies with its starter (AGENTS.md, Testing).

- **Unit tests** (`call_coordinator_test.exs`, isolated instances, short
  overrides): the grace held while a seat is away; the delay, the
  generation bump, the timeout and the maximum; a resume during a restart
  bumps the generation; a call where one seat lacks the capability keeps
  today's rules. `signaling_test.exs`: a restart offer through
  `relay_only/2`.
- **What's missing for real tests.** No test can cut media today:
  - `drop_proxy.mjs` cuts only TCP (the page's websocket);
  - `Randos.FakeTurn` answers only Allocate and Refresh (no
    CreatePermission, Send/Data or ChannelBind), so it can't carry a call;
  - the e2e server hands out no ICE servers, so calls go host to host on
    loopback.
- **The proposed cut:** a relay-only call through a test TURN server that
  can be told to stop relaying for one allocation. Recovery then needs a
  restart and a new allocation, as after a real move. Two ways to build
  it (D5):
  - (a) Grow `Randos.FakeTurn` into a real relay inside the test BEAM. The
    test server's watchdog covers it, but it needs permissions, Send/Data
    and channels, written by us.
  - (b) A test binary on `turn-server-proto` (already the helper's
    dev-dependency, `test_support::fake_turn_server`), e.g. a cargo
    example. It takes "drop allocation" commands on stdin and exits when
    stdin closes, the existing pattern.

  (b) reuses a maintained server; (a) needs no Rust build for `just smoke`.

  **Built: (b), `clients/tui/native/examples/test_turn.rs`** (the owner
  chose it, D5). `just test-turn` builds it to
  `target/debug/examples/test_turn` (cargo's tests build it too). Run it
  with no arguments (or `--user U --pass P --realm R`; defaults `randos`,
  `randos`, `randos`). It's a real UDP TURN relay on 127.0.0.1 (Allocate,
  Refresh, CreatePermission, ChannelBind, Send/Data) with fixed long-term
  credentials, so a test hands out
  `[{"urls": "turn:127.0.0.1:PORT?transport=udp", "username": "randos",
  "credential": "randos"}]`. Its stdout is a report for the test that
  started it (it isn't the helper, so it may print), one line per event:
  `listening 127.0.0.1:PORT` first, then `allocated CLIENT RELAYED` per
  allocation and `cut CLIENT` per cut. Commands on stdin, one per line:
  `cut ADDR` (drop everything from and to that client address: its
  5-tuple is dead, as after a move; new allocations from other addresses
  still work, so a restart that re-gathers from a new socket recovers),
  `cut-all` (every client address seen so far), `heal`, `quit`. It exits
  when stdin closes. The helper's `tests/restart.rs` checks it: a
  relay-only helper↔helper call flows through it, and stops after
  `cut-all`.
- **Scenarios:**
  - browser ↔ browser in `call_smoke.mjs`, both roles cut;
  - TUI ↔ TUI (`clients/tui/test/integration`);
  - TUI ↔ browser (`browser_call_test.exs`), each side cut, audio checked
    both ways after recovery;
  - a cut combined with the websocket drop (`startDropProxy`), which is the
    real Wi-Fi → cellular case.

  CDP's `Network.emulateNetworkConditions` offline probably doesn't cut
  WebRTC's UDP **[verify]**; don't rely on it.
- **`just turn-check`:** add a relay-only helper-to-helper call through
  the real coturn that rebinds one side to a new socket mid-call (a new
  5-tuple) and restarts. This is the check that proves recovery through
  coturn's real 437 behaviour; on one machine the hermetic tests can't.

## Phasing

1. **Hold the grace while a seat is away** (coordinator only, unit
   tests). It's small, it helps even without restart (a blip that drops
   both the socket and the media for under 10 s, where ICE recovers by
   itself), and nothing else works without it. Its own behaviour change,
   owner's call (D1).
2. **Server side of restart:** the `Lifecycle` constants, the coordinator
   rules, `ice_generation`, the capability, the protocol doc and the
   obligation tests. It's inert until clients declare the capability.
3. **Browser:** offerer restart and the hook wiring, then the fake TURN
   with a kill switch, and browser e2e.
4. **Helper and TUI:** socket rebind, re-gathering, `call_restart`, the
   Port contract tests, TUI ↔ TUI and TUI ↔ browser e2e, and `turn-check`.
5. **Docs** (none changed yet): `participant_channel.md` (obligations 4,
   9, 10, the drop table, "Not provided (yet)"), `call_flow.md`, the
   helper README, `docs/privacy.md` (no new data; one line on stale
   allocations), `coturn_audit.md`, `refactor_plan.md`.

   A new protocol field and obligation is an AGENTS.md trigger for a
   focused mini-pass: check it reached the doc, both clients and the
   obligation tests.

**Risks:**
- str0m's audio gap on false alarms.
- Browsers' disconnected and failed timings differ.
- Stale allocations against the quota.
- IPv6-only cellular networks reaching the TURN host (outside this
  design, but it shows up first here) **[verify]**.
- More moving parts in the call's most timing-sensitive moment; the
  timeouts in tests must stay generous to avoid flakiness.

## Open decisions for the owner

- **D1.** Hold the disconnected grace while a seat is away (phase 1)?
  Hold it entirely, or stretch it to the reconnect grace?
- **D2.** The numbers: the restart delay (2 s?), each attempt's timeout
  (10 s?), attempts per outage (2?), and whether a resume-triggered
  attempt counts.
- **D3.** Should `failed` become a report, not a teardown, for clients
  with the capability? (This is a behaviour change to obligation 4.)
- **D4.** Show "reconnecting audio…" to both people during a restart?
  That needs new gettext strings, and maybe a `restarting` value the
  server puts in `call.media`; this design works without it.
- **D5.** The test TURN: grow `Randos.FakeTurn` (Elixir), or a
  `turn-server-proto` test binary (Rust)?
- **D6.** Count restarts in the public status page's aggregate usage
  (e.g. `calls_recovered`)?
