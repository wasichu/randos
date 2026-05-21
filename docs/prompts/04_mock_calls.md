# Randos Step 4: Mock Call Coordination Lifecycle

Implement mock call coordination after matchmaking.

Still no WebRTC.

Goal:

When two users match, both users enter a shared mock call session with a coherent lifecycle, a five minute time limit, and mutual extension.

## Call Process

Create a per-call coordination process.

It should track:

- call id
- participant A
- participant B
- offerer
- answerer
- call status
- whether each participant is connected
- whether either participant has hung up
- max duration
- timeout reference
- extension_count
- extension votes

## Mock Call Flow

When two users match:

1. Matchmaker creates or delegates to a call coordination process
2. Call coordination creates a CallSession Ash resource
3. Both users transition to connecting
4. After a short simulated delay, both transition to in_call
5. CallSession is marked active
6. The call process starts a five minute timeout

## Call Time Limit

Initial default:

```elixir
@default_max_call_duration_seconds 300
```

When the timeout fires, do not immediately end the call.

Instead, move the call to extension_pending.

## Mutual Extension

When the five minute time limit is reached:

1. move call status to extension_pending
2. notify both users that time is up
3. ask each user whether they want to continue for another five minutes
4. if both users agree, extend the call
5. if either user declines, end the call
6. if either user does not respond within the grace period, end the call

Extension duration:

```elixir
@extension_duration_seconds 300
```

Extension response timeout:

```elixir
@extension_response_timeout_seconds 20
```

The extension decision must be mutual.

This is only mutual continuation of the current ephemeral conversation.

Do not reveal identity.

Do not create contacts.

Do not persist social relationships.

## Extension Outcomes

If both users accept:

- increment extension_count
- mark CallSession active again
- start another five minute timeout
- notify both users that the call was extended

If either user declines:

- mark CallSession ended with reason: extension_declined
- terminate the call process cleanly
- apply auto_requeue behavior independently

If grace period expires:

- mark CallSession ended with reason: extension_timeout
- terminate the call process cleanly
- apply auto_requeue behavior independently

## Hangup Behavior

When one user hangs up at any point:

- notify the other user
- terminate the call process
- mark CallSession ended with reason: hangup
- apply auto_requeue behavior independently

## Disconnect Behavior

If a user disconnects:

- notify the peer
- terminate the call
- mark CallSession ended with reason: disconnected
- apply auto_requeue behavior for the remaining user if appropriate

## Auto Requeue

- auto_requeue enabled: return to looking
- auto_requeue disabled: return to idle

This applies after:

- hangup
- disconnect
- extension declined
- extension timeout

## UI

The call screen should show:

- call status
- anonymous peer label
- selected speaking language
- selected listening language
- mock waveform placeholders
- mute placeholder
- hang up button
- stop after this call toggle
- five minute call limit label or countdown

The extension prompt should show:

```text
Time is up. Continue for another 5 minutes?
```

Buttons:

- Continue
- End

No WebRTC yet.

No browser microphone access yet.

No accounts.

No usernames.
