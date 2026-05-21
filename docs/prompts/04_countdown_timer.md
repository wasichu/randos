# Randos UI Tweak: Server-Authoritative Countdown Timer

Add a countdown timer to the active call UI.

The app already has mock call coordination, five minute call segments, and extension_pending behavior.

Goal:

Show users how much time remains in the current call segment without making the timer feel stressful.

## Core Principle

The call coordinator should own the authoritative deadline.

The browser should only render the countdown.

Do not make the browser responsible for enforcing call duration.

Do not push timer updates from the server every second.

## Server Requirements

When a call becomes active, the server should provide the client with a deadline timestamp.

Use a value like:

```elixir
call_deadline_unix_ms
```

or another clear equivalent.

The deadline should represent when the current call segment expires.

For the initial call segment:

```elixir
now + 300 seconds
```

For an extension:

```elixir
now + 300 seconds
```

If both users mutually extend, send the new deadline to both clients.

## Client Requirements

The browser should locally render the countdown based on the server-provided deadline.

Display format:

```text
4:58
```

or:

```text
4:58 remaining
```

Update the display locally once per second.

Do not use server pushes every second.

## UI Requirements

Show the countdown only during active calls.

Hide or replace it during:

- idle
- looking
- connecting
- extension_pending
- ended

During extension_pending, show the extension prompt instead:

```text
Time is up. Continue for another 5 minutes?
```

## Visual Style

Keep the countdown subtle.

It should be visible but not stressful.

Avoid:

- giant timer
- red warning styling
- aggressive animations
- gamified urgency

Optional restrained behavior:

- under 60 seconds, slightly increase emphasis
- under 15 seconds, gentle visual cue only if it fits the current UI

## Lifecycle Requirements

The countdown should reset when:

- a new call starts
- a call is mutually extended
- a call ends and a new call begins

The countdown should stop when:

- the user hangs up
- the peer disconnects
- extension is declined
- extension times out
- the call ends for any reason

Cleanup should be idempotent.

## Testing

Add or update tests where appropriate for:

- server sends a call deadline when call becomes active
- server sends a new deadline after mutual extension
- UI displays countdown during active call
- UI hides countdown outside active call
- countdown cleanup after call end

Do not add WebRTC yet.

Do not add audio yet.

Do not add persistence.
