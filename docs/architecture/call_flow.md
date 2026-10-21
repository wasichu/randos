# Call flow: how a call happens, for the browser and the TUI

Diagrams of the WebRTC call flow, as built (2026-10-20; the TUI helper's
parts updated 2026-10-21 for Stages 2 and 3). The protocol itself
is specified in [`participant_channel.md`](participant_channel.md) (its
"Client obligations" are the contract both clients follow); call timing
values live in `Randos.Calls.Lifecycle`. These diagrams show how the pieces
fit; when they disagree with the code or the protocol doc, those win.

The two clients are different UIs over the same behaviour: the server owns
matching and call health, and both clients meet the same obligations. Only
the transport to the server and the media stack differ.

## Shared: one call, start to finish

Both clients do exactly this. "Client" is the browser (LiveView) or the TUI
(participant channel); the server side is the same code for both.

```mermaid
sequenceDiagram
    autonumber
    participant A as Client A (waited first: offerer)
    participant S as Server (Participant core, Matchmaker, CallCoordinator)
    participant B as Client B (answerer)

    A->>S: find {speaks, listens, audio}
    S-->>A: state: looking
    B->>S: find {mirrored languages, same audio}
    Note over S: Matchmaker pairs them and starts a CallCoordinator
    S-->>A: state: connecting (role offerer, call: id, ice_servers, ice_transport_policy, media)
    S-->>B: state: connecting (role answerer, call: id, ice_servers, ice_transport_policy, media)

    Note over A,B: Obligation 1: start media at the match
    A->>S: signal offer
    S->>B: offer (relayed; relay-only calls: direct addresses removed)
    B->>S: signal answer
    S->>A: answer (relayed; relay-only calls: direct addresses removed)
    A-)S: signal ice_candidate (trickle)
    S-)B: ice_candidate
    B-)S: signal ice_candidate
    S-)A: ice_candidate

    Note over A,B: Direct media (UDP), never through the server
    A->>S: signal media_state connected
    B->>S: signal media_state connected
    Note over S: Both connected: activate, start the call clock
    S-->>A: state: in_call (call_deadline_unix_ms, media both connected)
    S-->>B: state: in_call

    Note over S: Time up: extension vote (see the state machine below)
    A->>S: end_call (or next, or a vote)
    S-->>A: state: idle (or looking, after next)
    S-->>B: state: looking (requeued)
    Note over A,B: Obligation 5: tear down when the status leaves the call
```

## Shared: call health, owned by the server

`CallCoordinator`'s states, with the rules both clients rely on. Clients run
none of these timers themselves.

```mermaid
stateDiagram-v2
    [*] --> connecting: match
    connecting --> active: both report media_state connected<br/>(text-only pairs: after a short delay)
    connecting --> ended: connect timeout,<br/>or media_state failed
    active --> extension_pending: segment time up
    extension_pending --> active: both vote continue
    extension_pending --> ended: a vote to end, vote timeout,<br/>or the 30-minute cap
    active --> ended: hang up, next, peer left,<br/>media_state failed, or<br/>disconnected past the grace
    ended --> [*]

    note right of active
        A participant's disconnected starts a grace
        timer (per participant; it survives
        active / extension_pending); reconnecting
        cancels it.
    end note
```

How a call ends decides who is requeued:

| Ending | `ended_reason` | Who goes back to `looking` |
| --- | --- | --- |
| `end_call` (incl. "can't start audio", with a reason) | `hangup` | only the peer; the sender goes `idle` (with `error`) |
| `next` | `hangup` | both |
| leaving on purpose (`peer_disconnected`) | `peer_disconnected` | the peer |
| a client's process just goes away | `disconnected` | the peer |
| never connects, `failed`, disconnected past the grace | `connection_failed` | both |

## Different: the browser

The browser talks to the server through its LiveView (`RandosWeb.HomeLive`)
and does media with the browser's own WebRTC.

```mermaid
flowchart LR
    subgraph Browser
        Hook["WebRTCAudio hook<br/>(assets/js/hooks/call_hook.js)<br/>on #webrtc-audio inside #call-media-&lt;call id&gt;"]
        Client["WebRTCClient<br/>(assets/js/randos/webrtc_client.js)"]
        PC["RTCPeerConnection<br/>+ getUserMedia"]
        Hook --> Client --> PC
    end

    subgraph Server
        Live["HomeLive<br/>(LiveView)"]
        Shell["ParticipantShell<br/>+ Participant core"]
        Live --> Shell
    end

    Live -- "renders data-webrtc-role,<br/>data-ice-servers, data-call-id" --> Hook
    Live -- "push_event randos:signal" --> Hook
    Hook -- "pushEvent signal<br/>(offer, answer, ice_candidate, media_state)" --> Live
    Hook -- "pushEvent end_call {reason}<br/>(mic denied, not found...)" --> Live
    Hook -- "pagehide: signal peer_disconnected" --> Live
```

- The call element is keyed by call id, so every call (even an instant
  rematch) gets a fresh hook and peer connection.
- ICE servers arrive as a DOM attribute when the call element renders.
- Media state comes from the peer connection's `iceConnectionState` /
  `connectionState`; each change is reported once.

## Different: the TUI

The TUI talks to the server over the participant channel (`Tui.Connection`,
Slipstream) and does media in a separate Rust process, the media helper,
over an Erlang Port. Elixir keeps signaling and UI; Rust owns all media.

```mermaid
flowchart LR
    subgraph TUI["TUI (Elixir, clients/tui)"]
        Conn["Tui.Connection<br/>(participant channel)"]
        App["Tui.App<br/>(ex_ratatui shell)"]
        Model["Tui.Model<br/>(pure: server state, form)"]
        MState["Tui.Media.State<br/>(pure: mic test, call audio)"]
        Media["Tui.Media<br/>(GenServer, owns the Port)"]
        Conn <--> App
        App --> Model
        App --> MState
        App <--> Media
    end

    subgraph Helper["randos_media (Rust, clients/tui/native)"]
        Port["Port server<br/>(main.rs, protocol.rs:<br/>JSON in {:packet, 4} frames)"]
        Call["call session thread (call.rs):<br/>str0m Rtc, UDP socket,<br/>Opus encode/decode, FEC, mute"]
        Cand["candidates.rs: STUN (stun.rs),<br/>TURN relay over UDP or TLS (relay.rs,<br/>tls_stream.rs), trickle, routing"]
        Echo["echo.rs: echo cancellation<br/>(sonora AEC3)"]
        Rep["report.rs: call_stats,<br/>call_levels (spectrum.rs)"]
        Dev["audio::Devices<br/>(capture, playback, resample)"]
        Cpal["cpal callbacks<br/>(lock-free rings only)"]
        Port --> Call --> Dev --> Cpal
        Call --> Cand
        Call --> Echo
        Call --> Rep
    end

    Server[("Server<br/>participant channel")] <--> Conn
    Media <-- "call_start / call_signal / call_mute / call_stop, devices<br/>events: call_signal, call_state, call_stats, call_levels" --> Port
```

How a signal travels inside the TUI (the server sees the same `signal`
events as from a browser):

```mermaid
sequenceDiagram
    participant S as Server (channel)
    participant C as Tui.Connection
    participant A as Tui.App + Tui.Media.State
    participant M as Tui.Media
    participant H as randos_media (str0m)

    S->>C: state: connecting (role, call: ice_servers)
    C->>A: {:push, "state", ...}
    A->>M: call_start {role, ice_servers}
    M->>H: call_start
    H-->>M: event call_signal (offer, for the offerer)
    M-->>A: {:media, "call_signal", ...}
    A->>C: push signal offer
    C->>S: signal offer
    S->>C: signal answer (relayed from the peer)
    C->>A: {:push, "signal", ...}
    A->>M: call_signal answer
    M->>H: call_signal
    H-->>M: event call_state connected
    M-->>A: {:media, "call_state", connected}
    A->>C: push signal media_state connected
    C->>S: signal media_state connected
```

- `Tui.Media.State` is pure: it turns server pushes and helper events into
  commands (requests to the helper, pushes to the channel), so the app is a
  thin shell.
- If the helper can't start or restarts mid-call, the TUI sends `end_call`
  with a reason (obligation 6); quitting mid-call sends `peer_disconnected`
  first (obligation 7).
- Without a working helper the TUI is text-only: it sends `audio: false` in
  `find` and is only matched with other text-only clients.

## What's the same, what's different

| | Browser | TUI |
| --- | --- | --- |
| Transport to the server | LiveView (`HomeLive`) | participant channel (`ParticipantChannel`) |
| Server code behind it | `ParticipantShell` + `Participant` (shared) | same |
| Call policy (activation, timeouts, failure) | server (`CallCoordinator`) | same |
| Client obligations | `participant_channel.md` | same, same tests |
| ICE servers and policy arrive in | DOM attributes on the call element (`data-ice-servers`, `data-ice-transport-policy`) | the `state` push's call map |
| Relay-only (obligation 8) | `iceTransportPolicy: "relay"` | `call_start`'s `relay_only`: no host or STUN candidates |
| WebRTC stack | the browser's | str0m in the Rust helper |
| STUN / TURN candidates | the browser's ICE agent | the helper's own (`stun.rs`, `relay.rs` over `turn-client-proto`): one relay per call over UDP, TLS (`turns:`) as the fallback when UDP is blocked |
| Echo cancellation | the browser's | the helper's (`echo.rs`, sonora's AEC3, the same canceller), on real devices only |
| Mic, speaker, codec | browser (Opus) | cpal + libopus + resampling in the helper |
| "I'm leaving" | `pagehide` → `peer_disconnected` | quit → `peer_disconnected` (`Tui.Connection.leave/2`) |
| Error text | from the server (`ParticipantErrors`) | same, via `error_message` |
