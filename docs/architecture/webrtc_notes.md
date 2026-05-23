# WebRTC Notes

Randos uses browser-to-browser WebRTC for audio.

Phoenix coordinates calls, but audio should flow directly between browsers whenever possible.

## Mental Model

There are two separate layers:

1. Signaling and coordination
2. Media transport

## Signaling and Coordination

Phoenix handles:

- matchmaking
- call lifecycle
- WebRTC role assignment
- SDP offer relay
- SDP answer relay
- ICE candidate relay
- hangup events
- timeout events
- mutual extension events
- cleanup events

Signaling messages are small control messages.

No audio flows through Phoenix.

## Media Transport

Once WebRTC negotiation succeeds, browsers exchange audio packets directly.

Typical media flow:

```text
Browser A <-> Browser B
```

If direct peer-to-peer networking fails, TURN may relay encrypted packets:

```text
Browser A <-> TURN server <-> Browser B
```

Phoenix still does not process the audio.

## WebRTC Roles

Each matched call should assign deterministic roles:

- offerer
- answerer

The offerer creates the SDP offer.

The answerer receives the offer and creates the SDP answer.

This avoids offer collisions.

## Call Lifecycle

The server remains authoritative for the supported app lifecycle.

A call can be:

- connecting
- active
- extension_pending
- ended

When the ten minute timer expires, the call coordinator moves the call into `extension_pending`.

If both users accept, the call extends.

If either user declines or fails to respond, the call ends.

## Client Cleanup

When a call ends, the official client should:

- close the RTCPeerConnection
- stop local audio tracks
- remove remote audio streams
- clean up event listeners
- return to looking or idle based on auto requeue

## Limits of Enforcement

Because WebRTC is peer-to-peer, two modified clients could theoretically ignore the server’s call-ended message and keep talking.

This is acceptable.

The app controls the official user experience and protects its own infrastructure.

The main infrastructure concern is continued TURN bandwidth usage, which should be handled later with short-lived TURN credentials.

## Permanent Non Goals

Do not add:

- video
- recording
- server-side audio processing
- admin listening
- eavesdropping
- SFU
- Membrane

unless the product philosophy explicitly changes.

The current architecture intentionally avoids server-side media.
