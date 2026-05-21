# Randos Step 6: Browser WebRTC Skeleton Without Audio

Add browser-side WebRTC structure, but do not request microphone access yet.

Goal:

Create and connect RTCPeerConnection objects between matched users using the existing signaling boundary.

## Requirements

Implement JavaScript modules for:

- creating a peer connection
- consuming offerer and answerer role from the server
- sending SDP offers
- receiving SDP offers
- sending SDP answers
- receiving SDP answers
- sending ICE candidates
- receiving ICE candidates
- closing peer connections

Use public STUN initially:

```js
stun:stun.l.google.com:19302
```

Do not implement:

- microphone access
- audio capture
- TURN
- Membrane
- SFU
- recording
- server-side media handling

## Signaling

Use the existing Phoenix signaling boundary from Step 5.

One peer should be assigned as the offerer.

The other peer should be assigned as the answerer.

Avoid both peers creating offers simultaneously.

## Client State

Track client-side WebRTC state separately from LiveView UI state.

Examples:

- not_started
- creating_peer_connection
- waiting_for_offer
- offer_sent
- answer_sent
- ice_checking
- connected
- failed
- closed

Do not overcomplicate this, but avoid unstructured ad hoc flags.

## Cleanup

On hangup, extension declined, extension timeout, peer disconnect, or page unload:

- close peer connection
- remove listeners
- notify server if appropriate

## Done Criteria

Two matched browser sessions can:

- create RTCPeerConnection objects
- exchange offers
- exchange answers
- exchange ICE candidates
- reach a connected or completed ICE state when possible
- close the peer connection cleanly when the call ends

No microphone or real audio yet.
