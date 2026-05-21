# Randos UI Tweak: Active Call and Extension Countdown Timers

Add countdown timers for both active calls and extension decisions.

The app already has:

- five minute call segments
- extension_pending behavior
- mutual extension
- extension response timeout

Goal:

Show users how much time remains in the current call segment and, during extension_pending, how much time remains to decide whether to continue.

## Core Principle

The call coordinator owns all authoritative deadlines.

The browser only renders countdowns.

Do not make the browser responsible for enforcing call duration.

Do not push timer updates from the server every second.

## Active Call Timer

When a call becomes active, the server should provide:

```elixir
call_deadline_unix_ms
```

This represents when the current five minute segment expires.

Display during active calls:

```text
4:58 remaining
```

or simply:

```text
4:58
```

## Extension Decision Timer

When the call enters extension_pending, the server should provide:

```elixir
extension_deadline_unix_ms
```

This represents when the extension response window expires.

Initial extension response timeout:

```elixir
@extension_response_timeout_seconds 20
```

Display during extension_pending:

```text
Time is up. Continue for another 5 minutes?
```

Then show a subtle decision timer:

```text
20 seconds to decide
```

or:

```text
Decision closes in 20s
```

## Mutual Extension Behavior

If both users accept before the extension deadline:

- call returns to active
- server sends a new `call_deadline_unix_ms`
- client hides extension timer
- client shows active call timer again

If either user declines:

- call ends
- client hides all timers

If the extension deadline expires:

- call ends
- client hides all timers

## Client Rendering

The browser should locally render countdowns once per second based on server-provided deadlines.

Do not use server pushes every second.

Countdowns should stop cleanly when:

- the call ends
- the user hangs up
- peer disconnects
- extension is declined
- extension times out
- a new call starts

Cleanup should be idempotent.

## UI Style

Keep both timers calm and restrained.

Avoid:

- giant countdowns
- aggressive red warnings
- panic styling
- gamified urgency

The extension timer should feel like a polite boundary, not a threat.

## UI State Rules

During `in_call`:

- show active call countdown
- hide extension countdown

During `extension_pending`:

- hide active call countdown
- show extension prompt
- show extension decision countdown

During `idle`, `looking`, `connecting`, or `ended`:

- hide all timers

## Testing

Add or update tests where appropriate for:

- active calls receive a call deadline
- extension_pending receives an extension deadline
- mutual extension sends a new active call deadline
- countdown display appears only in the correct UI states
- countdown cleanup after call end
- duplicate cleanup does not crash

Do not add WebRTC yet.

Do not add audio yet.

Do not add persistence.
