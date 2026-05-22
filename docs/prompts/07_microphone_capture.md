# Randos Step 7: Microphone Capture and Remote Audio Playback

Add real audio to the peer-to-peer WebRTC connection.

Goal:

Matched users should be able to speak and hear each other.

## Requirements

Use browser APIs:

- navigator.mediaDevices.getUserMedia
- RTCPeerConnection.addTrack
- remote track handling
- HTMLAudioElement or equivalent playback

Audio only.

Audio only is a permanent product constraint.

No video.

## Behavior

When entering a call:

1. request microphone permission
2. capture local audio stream
3. add local audio tracks to RTCPeerConnection
4. receive remote audio tracks
5. play remote audio automatically when allowed by browser policies

## UI

Add:

- microphone permission loading state
- microphone denied state
- mute button
- connection status display
- hang up button
- five minute countdown or call limit display

## Extension Behavior

When the call enters extension_pending:

- keep the WebRTC connection alive during the short extension decision window
- show the extension prompt
- do not renegotiate WebRTC if both users accept
- continue the existing audio connection if the call extends
- clean up audio if the call ends

## Cleanup

On hangup, extension declined, extension timeout, disconnect, or failed connection:

- stop local audio tracks
- close peer connection
- remove remote audio
- clean up event listeners
- return to looking or idle based on auto_requeue

## Privacy Constraints

Do not send audio to Phoenix.

Do not record audio.

Do not store audio.

Do not expose identity.

Do not add admin listening.

Do not add eavesdropping.

## Done Criteria

Two matched browser sessions can:

- establish a WebRTC audio call
- hear each other
- mute and unmute local microphone
- enter extension_pending at the time limit
- continue audio if both extend
- clean up audio if call ends
