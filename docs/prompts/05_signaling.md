# Randos Step 5: Signaling Boundary and Role Assignment

Prepare the codebase for peer-to-peer WebRTC signaling.

Do not implement microphone/audio yet.

Goal:

Create clean boundaries so the next phase can add browser WebRTC without tangling signaling, matchmaking, call coordination, UI code, and extension logic.

## Signaling Concepts

Prepare message types for:

- offer
- answer
- ice_candidate
- hangup
- peer_disconnected
- connection_failed
- connection_established
- time_limit_reached
- extension_requested
- extension_accepted
- extension_declined
- extension_confirmed
- extension_timeout

## Architecture

Phoenix should act only as:

- matchmaking coordinator
- call lifecycle coordinator
- signaling relay

Phoenix should not process media.

Media should eventually flow:

```text
Browser <-> Browser
```

Not:

```text
Browser <-> Phoenix <-> Browser
```

## WebRTC Roles

Use assigned roles:

- offerer
- answerer

The offerer will eventually create the SDP offer.

The answerer will create the SDP answer.

Avoid offer collisions.

## Extension Signaling

The call coordinator owns extension state.

The browser only sends:

- extension_accepted
- extension_declined

The browser does not decide whether the call is extended.

The call coordinator extends only after both users accept.

## Code Organization

Separate:

- Matchmaker
- CallCoordinator
- Signaling
- LiveView UI
- future browser WebRTC JavaScript

Avoid one giant LiveView module.

## Future WebRTC Assumptions

The next phase will use:

- native browser RTCPeerConnection
- getUserMedia
- public STUN initially
- no TURN yet
- no Membrane
- no SFU
- no recording
- no eavesdropping
- no server-side audio

## Done Criteria

By the end of this step:

- users can match
- users can enter mock calls
- users can hang up
- calls enter extension_pending after five minutes
- both users can accept or decline extension
- calls extend only if both users accept
- calls end if either user declines or does not respond
- signaling boundary supports future WebRTC messages
- offerer and answerer roles are available to the client
- no real audio exists yet
