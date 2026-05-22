# Randos JavaScript Stabilization Pass

The app now has:

- LiveView hooks
- WebRTC peer connections
- media stream setup
- countdown timers
- realtime call lifecycle

Before adding more features, refactor and stabilize the JavaScript architecture.

Goals:

- improve maintainability
- isolate responsibilities
- centralize cleanup
- reduce hook complexity
- prepare for future debugging

## Requirements

Organize JavaScript into clear modules.

Suggested structure:

```text
assets/js/
  app.js

  hooks/
    call_hook.js
    countdown_hook.js
    waveform_hook.js

  randos/
    webrtc_client.js
    media.js
    timers.js
    cleanup.js
    signaling.js
```

## Architectural Rules

Hooks should:

- own DOM lifecycle integration
- delegate logic to modules
- remain small
- clean up resources

Modules should:

- encapsulate browser behavior
- expose explicit cleanup methods
- avoid global mutable state

## Cleanup Requirements

Every browser resource must have explicit cleanup behavior.

Examples:

- RTCPeerConnection.close()
- MediaStreamTrack.stop()
- AudioContext.close()
- clearInterval()
- cancelAnimationFrame()
- removeEventListener()

Cleanup should be idempotent.

The app should tolerate duplicate cleanup calls safely.

## Logging

Add structured console logging for:

- call lifecycle
- WebRTC state
- ICE state changes
- connection establishment
- cleanup events
- extension flow

Avoid noisy logs.

Logs should aid debugging.

## Constraints

Do not add:

- React
- Vue
- Svelte
- TypeScript
- additional frontend frameworks
- new build tooling

Keep the frontend lightweight and close to standard Phoenix LiveView conventions.

## Goal

The JavaScript layer should feel:

- small
- explicit
- modular
- boring
- debuggable
- cleanup-safe
