# Randos Step 9: Failure Handling, Cleanup, and Requeue Reliability

Improve WebRTC and realtime lifecycle handling.

Goal:

The app should fail gracefully when WebRTC cannot connect, microphone access fails, the time limit is reached, extension decisions conflict, or a peer disappears.

## Requirements

Handle browser connection states:

- new
- checking
- connected
- completed
- disconnected
- failed
- closed

Handle:

- microphone permission denied
- no microphone available
- ICE failure
- peer refreshes browser
- peer closes tab
- peer hangs up
- call reaches five minute time limit
- one user accepts extension
- one user declines extension
- both users accept extension
- both users decline extension
- one user accepts and the other disconnects
- extension response timeout
- duplicate hangup events
- duplicate cleanup calls
- duplicate extension messages

## Time Limit and Extension Reliability

Ensure time limits and mutual extensions are handled cleanly.

Handle:

- timeout fires after one user already hung up
- duplicate timeout and hangup events
- call process terminates before timeout
- extension timeout fires after one user already declined
- both users accept at nearly the same time
- one user accepts after the call already ended
- extension cleanup does not leave users queued incorrectly

Call ending should be idempotent.

Call extension should be idempotent.

## Behavior

When connection fails or call ends:

- show a clear ended or failed state
- clean up local media resources
- close peer connection
- notify peer if possible
- terminate call coordination process
- return to looking if auto_requeue is enabled
- return to idle if auto_requeue is disabled

## Queue Safety

Ensure users do not remain stuck in:

- queue after disconnect
- connecting after failure
- in_call after peer leaves
- extension_pending after timeout
- duplicate queued state

Avoid zombie queue entries and zombie call processes.

## Logging

Add useful client and server logs for:

- matchmaking events
- signaling events
- ICE state changes
- call lifecycle events
- cleanup actions
- timeout events
- extension events

Do not log:

- audio content
- SDP bodies unless needed for local debugging
- personally identifying account data

There should be no account data.

## Done Criteria

The app handles common failures without zombie calls, broken UI states, stuck queues, duplicate extensions, or leaked media tracks.
