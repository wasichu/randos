# randos_media: the TUI's media helper

A small Rust binary the TUI runs as an Erlang Port. It will own all call
media (WebRTC via str0m, Opus, mic/speaker via cpal, later echo
cancellation); Elixir keeps signaling and UI. Design:
[`docs/architecture/tui_audio.md`](../../../docs/architecture/tui_audio.md).

**Status: Stage 0 skeleton.** Port framing only.

## Port protocol

Each message is a 4-byte big-endian length plus the body (Erlang
`{:packet, 4}`). Bodies so far:

| From | Body | Meaning |
| --- | --- | --- |
| Elixir | `ping` | liveness check |
| helper | `pong` | reply to `ping` |
| helper | `error:unknown_message` | unrecognized message |

The helper exits when its stdin closes (the Port is closed or the TUI dies).

## Dependencies

None yet. Each one added must be justified here (purpose, license, whether it
pulls in C); `cargo deny check` enforces the license policy in `deny.toml`.

## Checks

`just native-check` (part of `just precommit`): `cargo fmt --check`,
`cargo clippy --all-targets -- -D warnings`, `cargo test`, `cargo deny check`.
