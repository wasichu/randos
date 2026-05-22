# Randos Step 10: Dynamic ICE Configuration Boundary for Future coturn

Prepare the app for TURN support, but do not require a deployed coturn server yet.

Goal:

Make ICE server configuration dynamic so public STUN can later be replaced or supplemented with coturn STUN/TURN.

## Requirements

Move ICE server configuration out of hardcoded JavaScript.

Provide ICE config from the Phoenix app to the browser.

Initial config:

```elixir
[
  %{urls: "stun:stun.l.google.com:19302"}
]
```

Prepare for future config:

```elixir
[
  %{urls: "stun:turn.example.com:3478"},
  %{
    urls: "turn:turn.example.com:3478",
    username: "...",
    credential: "..."
  }
]
```

## Architecture

Create a small module responsible for ICE server configuration.

Example:

```elixir
RandosWeb.IceServers
```

This module should later support:

- public STUN
- coturn STUN
- coturn TURN
- temporary TURN credentials
- environment variable configuration

Do not implement authenticated TURN credentials yet unless explicitly requested.

## Environment Configuration

Prepare for future environment variables such as:

- TURN_SERVER_URL
- TURN_SHARED_SECRET
- TURN_REALM
- TURN_CREDENTIAL_TTL_SECONDS

Do not require these yet.

## Privacy Principle

TURN should only relay encrypted WebRTC traffic when peer-to-peer connection fails.

Do not add server-side audio access.

Do not add recording.

Do not add monitoring.

## Done Criteria

Browser WebRTC code receives ICE server config from Phoenix instead of hardcoding it.

The default remains public STUN only.

TURN support is prepared but not required.
