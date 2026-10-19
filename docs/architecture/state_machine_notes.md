# State Machine Notes

Randos uses explicit state machines to avoid ad hoc realtime lifecycle behavior.

The goal is to make matchmaking, call coordination, and UI transitions predictable and debuggable.

## Architectural Principle

Each lifecycle has exactly one owner:

- **Call lifecycle:** `Randos.Calls.CallCoordinator`, a `:gen_statem` (one per
  call), using the rules in `Randos.Calls.Lifecycle` and owning the
  `Randos.Calls.Call` struct.
- **A person's flow:** `Randos.Participant` (pure; run by
  `RandosWeb.ParticipantShell` from the LiveView or the participant channel).
- **Browser media:** `WebRTCClient` in `assets/js/randos/webrtc_client.js`.

Do not collapse these responsibilities together.

## Call Lifecycle

Statuses: `connecting`, `active`, `extension_pending`, `ended`.

Allowed transitions:

- connecting -> active
- connecting -> ended
- active -> extension_pending
- active -> ended
- extension_pending -> active
- extension_pending -> ended

Each `:gen_statem` state owns its timer as a `state_timeout`, so leaving a
state cancels it. Transition from the wrong status raises; the extension cap
is the one legitimate refusal (`Lifecycle.extend/1`).

## What the Call State Machine Does Not Handle

- queue membership (`Randos.Matchmaking.Matchmaker`)
- ICE state, SDP signaling, browser media state (browser JavaScript)
- waveform visualization (browser)
- socket presence (the participant's transport process)

## Participant States

A participant (`Randos.Participant`) has explicit states:

- idle
- looking
- connecting
- in_call
- extension_pending

Avoid scattered boolean flags.

Avoid combinations like:

```elixir
%{
  loading: true,
  connected: false,
  waiting: true,
  extension_prompt: false
}
```

Prefer coherent states.

## Browser WebRTC States

Client-side WebRTC logic should also remain explicit.

Possible states:

- not_started
- creating_peer_connection
- waiting_for_offer
- offer_sent
- answer_sent
- ice_checking
- connected
- failed
- closed

This state should remain browser-local.

Do not attempt to fully synchronize browser WebRTC state with the server. The server only hears `connection_established`, `connection_failed`, and `peer_disconnected`.

## Idempotency

Call ending should be idempotent.

Cleanup should be idempotent.

Extension approval should be idempotent.

Timeout handling should be idempotent.

Expect duplicate events and race conditions.

The system should tolerate them gracefully.

## Philosophy

The state machine architecture exists to reduce:

- zombie calls
- stuck queues
- contradictory UI states
- signaling races
- extension timing bugs

The goal is not maximal abstraction.

The goal is calm, understandable realtime behavior.
