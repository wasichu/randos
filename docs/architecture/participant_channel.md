# Participant channel protocol

The public API for non-browser randos clients (the TUI). Browsers use the
LiveView at `/` instead; both run the same `Randos.Participant` core through
`RandosWeb.ParticipantShell`, so a channel participant and a browser
participant can be matched with each other.

Implementation: `RandosWeb.ParticipantSocket`, `RandosWeb.ParticipantChannel`.
Tests: `test/randos_web/channels/participant_channel_test.exs`.

## Connecting

- **URL:** `wss://<host>/participant/websocket?vsn=2.0.0` (Phoenix socket
  protocol v2, JSON). Use any Phoenix channels client, or plain websockets:
  frames are `[join_ref, ref, topic, event, payload]`. Send a `heartbeat` on
  topic `phoenix` every ~30 s.
- **Websocket only** (no long-polling). Frames are capped at **64 KB**;
  larger frames close the socket with code 1009.
- **Anonymous.** No params, no auth, no ids. **A new channel is a new
  participant**: there is no resume. If the socket drops, the participant
  leaves the queue and any call ends (`disconnected`) for both people.

## Joining

Join topic `"participant"` with `{}`. The reply carries the initial
[state](#state) and the supported conversation languages (use these codes in
`find`; don't hardcode the list):

```json
["1", "1", "participant", "phx_join", {}]
→ ["1", "1", "participant", "phx_reply", {"status": "ok", "response": {
    "state": {"status": "idle", "webrtc_role": null, "error": null, "call": null},
    "languages": [{"code": "en", "name": "English (EN)"}, {"code": "es", "name": "Español (ES)"}, …]
  }}]
```

A reconnect (e.g. Slipstream rejoining) is a new participant: the join reply
is a fresh `idle` state.

## Client → server events

Every event gets a reply: `{"status": "ok", "response": {}}` or
`{"status": "error", "response": {"reason": <string>}}`. Effects of an event
show up as [`state`](#state) pushes, not in the reply.

| Event | Payload | Applies when | Effect |
| --- | --- | --- | --- |
| `find` | `{"speaks": "en", "hears": ["en", "es"], "adult_acknowledged": true, "audio": false}` | `idle` | Join the queue (or match immediately) with someone you can talk to **and whose `audio` matches** (see below). Without the acknowledgment, state shows `error: "adult_terms_required"`. **Rate limited:** burst of 5, then 1 per 6 s → `rate_limited`. |
| `cancel_search` | `{}` | `looking` | Leave the queue → `idle`. |
| `end_call` | `{}`, or `{"reason": …}` | in a call | Hang up and go `idle`. The peer goes back to `looking`. A client that can't carry the call sends a `reason`: `microphone_denied`, `microphone_not_found`, `audio_unavailable`, or `audio_failed` (anything else replies `invalid_message`); it comes back as this participant's `error`. |
| `next` | `{}` | in a call | Hang up and go straight back to `looking`. |
| `vote` | `{"vote": "continue" \| "end"}` | `extension_pending` | Vote on extending. Both `continue` → another segment; any `end` → call ends (voter goes `idle`). |
| `signal` | `{"type": <signal type>, "payload": {…}}` | in a call | Relay a WebRTC signal to the peer (see [signals](#webrtc-signaling)). |

Events that don't apply in the current status are accepted and ignored.
Malformed payloads reply `invalid_message`; unknown signal types reply
`unsupported_signal_type`.

`speaks` is the language you'll speak; `hears` the languages you're happy
to hear (one or more; a browser starts with the speaking language checked
among them). Two people are matched when **each one's `speaks` is in the
other's `hears`**: the same language both ways, or crosstalk (you speak
Spanish and hear English, they the opposite). Among several compatible
people, whoever has waited longest is matched. All codes must come from
the join reply's `languages`, and `hears` can't be empty; otherwise the
state shows `error: "unsupported_language"`. A `hears` that isn't a list of
strings replies `invalid_message`. Clients from before `hears` send a
single `"listens": "es"` instead, which means `"hears": ["es"]`.

Two people who just had a call aren't matched with each other again for
`Randos.Calls.Lifecycle.rematch_window_seconds/0` (90 s) after it ends, so
`next` finds someone new; if they're still both waiting when it passes,
they're matched then. The server remembers only the pair's anonymous ids,
in memory, for that window.

`audio` (boolean, optional, default `false`) says whether this client can
carry call audio over WebRTC. Browsers always do. A client that sends
`false` (or leaves it out) is only matched with other clients that sent
`false`, so a browser user never ends up in a silent call with a text-only
client. Send `true` only once you can actually answer or offer an audio
call; a non-boolean value replies `invalid_message`.

## Server → client pushes

### `state`

Pushed whenever the participant's state changes (the initial one comes in
the join reply). JSON strings throughout: `status`, `webrtc_role`, `error`,
`call.status`, `call.ended_reason` and `call.media.*` arrive as strings,
e.g. `"in_call"`.

```json
{
  "status": "idle | looking | connecting | in_call | extension_pending",
  "webrtc_role": "offerer | answerer | null",
  "error": "adult_terms_required | unsupported_language | call_start_failed | microphone_denied | microphone_not_found | audio_unavailable | audio_failed | null",
  "error_message": "…the same words the browser shows… | null",
  "call": null | {
    "id": "call-…",
    "status": "connecting | active | extension_pending | ended",
    "media": {"self": "connecting | connected | disconnected", "peer": "…"},
    "ice_servers": [{"urls": "stun:…"}, {"urls": "turn:…", "username": "…", "credential": "…"}],
    "ice_transport_policy": "relay | all",
    "peer_speaks": "es",
    "call_deadline_unix_ms": 1760000000000 | null,
    "extension_deadline_unix_ms": 1760000000000 | null,
    "extension_count": 0,
    "extension_duration_seconds": 600,
    "ended_reason": null
  }
}
```

- `connecting` is the match: start WebRTC now (see
  [Client obligations](#client-obligations)). It becomes `in_call` once both
  sides' `media` is `connected`, and that's when the call clock starts. A call
  between two clients without audio becomes `in_call` ~750 ms after the
  match.
- `media`: each side's connection as it last reported it (`self` is you),
  so a client can show "peer connecting…".
- `ice_servers`: this call's STUN/TURN servers (fresh TURN credentials,
  valid for at least the longest possible call). Use them for this call's
  peer connection.
- `peer_speaks`: the language your rando speaks in this call (a code from
  `languages`). With several hearing languages, it's the only way to know.
  It's a language, never anything that identifies them.
- `ice_transport_policy`: WebRTC's `iceTransportPolicy` for this call.
  `"relay"` (whenever the server has a TURN server, unless its operator
  allows direct calls): connect only through the TURN relay, so neither
  person learns the other's IP address. `"all"`: direct when possible, the
  relay as the fallback. See obligation 8.
- `call_deadline_unix_ms`: when the current segment ends (10 min, then 10
  more per extension, max 2 extensions / 30 min).
  `extension_deadline_unix_ms`: when the vote closes (20 s).
  `extension_duration_seconds`: how long a continued call runs on, for the
  vote's wording ("continue for another 10 minutes?"); don't hardcode it.
- `error_message`: show this rather than wording your own, so every client
  says the same thing.
- After a call ends, `call` becomes `null` and status becomes `idle` (if you
  chose to stop) or `looking` (you were requeued automatically).
- The state never contains the peer, the match, or any participant id.

(There is no separate `ice_servers` push any more: the servers come with
the call in `state`.)

### `signal`

A WebRTC signal from the peer:

```json
{"call_id": "call-…", "type": "offer", "payload": {"sdp": {…}}, "sent_at_unix_ms": 1760000000000}
```

## WebRTC signaling

(Diagrams of this flow, shared and per client: [`call_flow.md`](call_flow.md).)

Same flow as the browser (`assets/js/randos/webrtc_client.js`). **Call health
is the server's job**: clients report their raw media state, and the server
(`CallCoordinator`) decides when a call is up or has failed.

The server also drops any signal that isn't for your current call, so a
late signal from a previous call never reaches you.

### Client obligations

Every client with audio (the browser, the TUI) does exactly this. The
end-to-end tests check these, by number, for both clients
(`test/e2e/call_smoke.mjs` browser-to-browser,
`clients/tui/test/integration/browser_call_test.exs` TUI-to-browser):

| Obligation | Browser ↔ browser | TUI ↔ browser |
| --- | --- | --- |
| 1–4: start at the match, negotiate, report, `in_call` once both connect | "two people match and connect audio" | both roles, audio checked both ways |
| 4: never connects → ends at the connect timeout | relay-only page | relay-only browser |
| 4: disconnected past the grace | (unit tests: `call_coordinator_test.exs`; hard to cause from a real client) | (same) |
| 5: tear down on the status change | hang-up and "Next" scenarios | every scenario ends through the status |
| 6: can't start → `end_call` with a reason | mic denied | TUI without audio; browser mic denied |
| 7: leaving on purpose | page hide sends `peer_disconnected` | quitting mid-call sends it (`connection_test.exs`, `app_test.exs`) |
| 8: relay-only means relay only | `relay_only_smoke.mjs` (and a page that ignores the policy, which the server's filter must stop) | TUI ↔ TUI: `relay_only_test.exs` |

(Obligation 8's tests run against a server whose only TURN server never
answers, `RANDOS_TEST_UNREACHABLE_RELAY=1`, so a call can connect only by
going direct: `just smoke` and `just tui-smoke` run them.)

1. **Start at the match.** On `connecting`, capture the mic and create the
   peer connection with the call's `ice_servers`, and add the audio track.
2. **Negotiate.** The **offerer** creates an offer and sends `signal`
   `offer` (`{"sdp": {"type", "sdp"}}`); the **answerer** waits for it, then
   sends `answer`. Both trickle `ice_candidate`
   (`{"candidate": {"candidate", "sdpMid", "sdpMLineIndex", "usernameFragment"}}`,
   i.e. `RTCIceCandidate.toJSON()`; `sdpMid` may be `null`, with
   `sdpMLineIndex` 0 naming the one audio m-line). Buffer remote candidates
   until the remote description is set.
3. **Report media state.** On every change of your connection, send
   `signal` `media_state`: `{"state": "connected" | "disconnected" |
   "failed", ...}` (extra keys, like a `reason` or `source`, are allowed).
   Send each change once.
4. **Let the server decide.** It makes the call `in_call` (and starts its
   clock) once both sides are `connected`, and ends it `connection_failed` if
   that doesn't happen within the connect timeout (15 s), if a side stays
   `disconnected` past the grace (5 s), or on `failed`. Don't run your own
   timers for these.
5. **Tear down when the status leaves the call** (`call` becomes `null`).
   The server doesn't relay lifecycle signals to the peer.
6. **Can't start? `end_call` with a reason.** No mic, mic denied, or no
   audio support: send `end_call` with a `reason`
   (`microphone_denied`, `microphone_not_found`, `audio_unavailable`,
   `audio_failed`), not `media_state` `failed`. Only the peer is requeued,
   and you get the reason back as your `error` and `error_message`.
7. **Leaving on purpose? Say so.** When the person closes the page or quits
   the app during a call, send `signal` `peer_disconnected` (and wait for its
   reply if you're about to close the channel). The call ends
   `peer_disconnected`. A channel that just goes away ends it `disconnected`,
   which means a lost connection (network, crash), not a choice.
8. **Relay-only means relay only.** When the call's `ice_transport_policy`
   is `"relay"`, gather and send only relay candidates (a browser's
   `iceTransportPolicy: "relay"`): no host or server-reflexive candidates,
   in trickled candidates or in the SDP. Your address must never reach the
   peer. If the relay can't be reached, the call doesn't connect, and the
   server ends it at the connect timeout; never fall back to direct. A
   missing policy (an older server) means `"all"`.

   **The server enforces it too** (`Randos.Signaling.relay_only/2`): in a
   relay-only call it drops every non-relay candidate it's asked to relay,
   in `ice_candidate` signals and in SDP, and blanks the addresses a relay
   candidate or SDP could still carry (`raddr`/`rport`, and the `c=`,
   `a=rtcp:` and `o=` lines). Nothing else in a message changes: DTLS
   fingerprints, ICE credentials and codecs stay byte for byte as sent (a
   test checks). So an older or broken client can't reveal its owner's
   address; a client following this obligation loses nothing.

**Clients without audio** send `"audio": false` in `find`, so they're only
matched with each other, and their calls go `in_call` without any media
reports. If one still receives an `offer`, it must answer with `end_call`
(reason `audio_unavailable`), never `media_state` `failed`: `end_call` ends the
call with this client stopping, so only the peer is requeued; any other
ending requeues both participants, and two incompatible clients would
rematch in a loop.

Signal types: `offer`, `answer`, `ice_candidate` (relayed to the peer as-is,
except in relay-only calls, where the server removes direct addresses: see
obligation 8;
the server never touches media), `media_state` (validated and acted on;
`invalid_media_state` if malformed), and `peer_disconnected`.
`connection_established` / `connection_failed` are older spellings of
`media_state` connected / failed, still accepted.

## Not provided (yet)

- No reconnect/resume (see above).
- No IP-level rate limiting; that belongs at the edge (Fly).
- No identity of any kind, by design.
