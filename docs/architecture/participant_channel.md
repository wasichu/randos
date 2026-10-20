# Participant channel protocol

The public API for non-browser Randos clients (the TUI). Browsers use the
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
| `find` | `{"speaks": "en", "listens": "es", "adult_acknowledged": true, "audio": false}` | `idle` | Join the queue (or match immediately) with someone whose languages mirror yours **and whose `audio` matches** (see below). Without the acknowledgment, state shows `error: "adult_terms_required"`. **Rate limited:** burst of 5, then 1 per 6 s → `rate_limited`. |
| `cancel_search` | `{}` | `looking` | Leave the queue → `idle`. |
| `end_call` | `{}`, or `{"reason": …}` | in a call | Hang up and go `idle`. The peer goes back to `looking`. A client that can't carry the call sends a `reason`: `microphone_denied`, `microphone_not_found`, `audio_unavailable`, or `audio_failed` (anything else replies `invalid_message`); it comes back as this participant's `error`. |
| `next` | `{}` | in a call | Hang up and go straight back to `looking`. |
| `vote` | `{"vote": "continue" \| "end"}` | `extension_pending` | Vote on extending. Both `continue` → another segment; any `end` → call ends (voter goes `idle`). |
| `signal` | `{"type": <signal type>, "payload": {…}}` | in a call | Relay a WebRTC signal to the peer (see [signals](#webrtc-signaling)). |

Events that don't apply in the current status are accepted and ignored.
Malformed payloads reply `invalid_message`; unknown signal types reply
`unsupported_signal_type`.

`speaks` and `listens` must be codes from the join reply's `languages`;
others give `error: "unsupported_language"`.

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
and `call.status` / `call.ended_reason` arrive as strings, e.g. `"in_call"`.

```json
{
  "status": "idle | looking | connecting | in_call | extension_pending",
  "webrtc_role": "offerer | answerer | null",
  "error": "adult_terms_required | unsupported_language | call_start_failed | null",
  "call": null | {
    "id": "call-…",
    "status": "connecting | active | extension_pending | ended",
    "call_deadline_unix_ms": 1760000000000 | null,
    "extension_deadline_unix_ms": 1760000000000 | null,
    "extension_count": 0,
    "ended_reason": null
  }
}
```

- `connecting` → `in_call` happens ~750 ms after a match. Start WebRTC when
  `in_call` arrives (that's when the browser does).
- `call_deadline_unix_ms`: when the current segment ends (10 min, then 10
  more per extension, max 2 extensions / 30 min).
  `extension_deadline_unix_ms`: when the vote closes (20 s).
- After a call ends, `call` becomes `null` and status becomes `idle` (if you
  chose to stop) or `looking` (you were requeued automatically).
- The state never contains the peer, the match, or any participant id.

### `ice_servers`

```json
{"ice_servers": [{"urls": "stun:…"}, {"urls": "turn:…", "username": "…", "credential": "…"}]}
```

Pushed when a new call starts (fresh TURN credentials, valid for at least the
longest possible call), and `{"ice_servers": null}` once there's no call. Use
them for that call's `RTCPeerConnection`.

### `signal`

A WebRTC signal from the peer:

```json
{"call_id": "call-…", "type": "offer", "payload": {"sdp": {…}}, "sent_at_unix_ms": 1760000000000}
```

## WebRTC signaling

Same flow as the browser (`assets/js/randos/webrtc_client.js`). **Call health
is the server's job**: clients report their raw media state, and the server
(`CallCoordinator`) decides when a call is up or has failed.

1. On `connecting` (the match), capture the mic, create the peer connection
   with the pushed `ice_servers`, and add the audio track. (`in_call` comes
   later: once both sides' media is connected.)
2. **Offerer** creates an offer and sends `signal` `offer`
   (`{"sdp": {"type", "sdp"}}`); **answerer** waits for it, then sends
   `answer`. Both trickle `ice_candidate`
   (`{"candidate": {"candidate", "sdpMid", "sdpMLineIndex", "usernameFragment"}}`,
   i.e. `RTCIceCandidate.toJSON()`). Buffer remote candidates until the
   remote description is set.
3. On every change of your connection, send `signal` `media_state`:
   `{"state": "connected" | "disconnected" | "failed", ...}` (extra keys,
   like a `reason` or `source`, are allowed). Send each change once.
4. The server then:
   - makes the call `in_call` (and starts its clock) once both sides are
     `connected`;
   - ends it `connection_failed` if that doesn't happen within the connect
     timeout (15 s), if a side stays `disconnected` past the grace (5 s), or
     on `failed`.
   You see the result as `state` pushes. **Tear down when the status leaves
   the call**; the server doesn't relay lifecycle signals to the peer.
5. If you can't start (no mic, mic denied, no audio support), send
   `end_call` with a `reason`, not `media_state` `failed`: only the peer is
   requeued, and you're told why.
6. Leaving the page or app: `signal` `peer_disconnected`, or just close the
   channel. Either ends the call.

**Clients without audio** send `"audio": false` in `find`, so they're only
matched with each other, and their calls go `in_call` without any media
reports. If one still receives an `offer`, it must answer with `end_call`
(reason `audio_unavailable`), never `media_state` `failed`: `end_call` ends the
call with this client stopping, so only the peer is requeued; any other
ending requeues both participants, and two incompatible clients would
rematch in a loop.

Signal types: `offer`, `answer`, `ice_candidate` (relayed to the peer as-is;
the server never touches media), `media_state` (validated and acted on;
`invalid_media_state` if malformed), and `peer_disconnected`.
`connection_established` / `connection_failed` are older spellings of
`media_state` connected / failed, still accepted.

## Not provided (yet)

- No reconnect/resume (see above).
- No IP-level rate limiting; that belongs at the edge (Fly).
- No identity of any kind, by design.
