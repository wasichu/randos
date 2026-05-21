# State Machine Notes

Randos uses explicit state machines to avoid ad hoc realtime lifecycle behavior.

The goal is to make matchmaking, call coordination, and UI transitions predictable and debuggable.

## Architectural Principle

Ash state machines should model domain lifecycle transitions.

GenServers should manage live runtime coordination.

Browser JavaScript should manage browser-local WebRTC state.

Do not collapse these responsibilities together.

## Ash State Machine Usage

Use `ash_state_machine` for `CallSession.status`.

Statuses:

- connecting
- active
- extension_pending
- ended

Allowed transitions:

- connecting -> active
- connecting -> ended
- active -> extension_pending
- active -> ended
- extension_pending -> active
- extension_pending -> ended

Do not mutate status fields manually.

Use transition actions.

## What Ash State Machines Should Not Handle

Do not use Ash state machines for:

- queue membership
- ICE state
- SDP signaling
- active socket presence
- browser media state
- waveform visualization
- timeout ownership
- extension vote tracking

Those belong to:

- GenServers
- PubSub
- browser JavaScript
- WebRTC APIs

## LiveView UI States

The UI should also have explicit states:

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

Do not attempt to fully synchronize browser WebRTC state with Ash resources.

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
