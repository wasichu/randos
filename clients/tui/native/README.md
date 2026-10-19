# randos_media: the TUI's media helper

A small Rust binary the TUI runs as an Erlang Port. It will own all call
media (WebRTC via str0m, Opus, mic/speaker via cpal, later echo
cancellation); Elixir keeps signaling and UI. Design:
[`docs/architecture/tui_audio.md`](../../../docs/architecture/tui_audio.md).

**Status: Stage 0.** Port framing (ping/pong) and a mic → Opus → speaker
loopback for measuring latency by hand.

## Loopback

```
just media-loopback            # default mic → Opus → default speaker, 20 s
randos_media --loopback [--in device|sine] [--out device|null|wav:PATH] [--seconds N]
```

`--seconds` defaults to 20. The TUI runs the same loopback over the Port
(`t` on the idle screen, 5 s). Once a second it reports where the latency goes: device
buffers (from cpal's callback timestamps), the two rings, and the codec's
fixed 26.5 ms (one 20 ms frame plus 6.5 ms of Opus lookahead). That's the
pipeline's own latency, not an acoustic mouth-to-ear measurement. Use
headphones: there is no echo cancellation yet (Stage 3).

Devices must offer 48 kHz f32 (Opus can't take 44.1 kHz); the helper refuses
to start rather than resample, until Stage 2. The cpal callbacks only copy
into or out of lock-free rings (`ringbuf`) and bump atomics; a worker thread
does the downmix, Opus, upmix, and stats. Playback queues at most 40 ms, and
extra frames are dropped, so device clock drift can't grow the latency.

## Port protocol

Each message is a 4-byte big-endian length plus a JSON object (Erlang
`{:packet, 4}`). The Elixir side is `Tui.Media` / `Tui.Media.Protocol`; the
Rust side is `src/protocol.rs`. Change all three, and this table, together.

Requests carry an integer `id`, and each gets exactly one reply echoing it as
`reply`, with either `ok` (a result) or `error` (a message). Events are
unsolicited and carry `event` instead.

| Request (`cmd`) | Fields | `ok` result |
| --- | --- | --- |
| `ping` | | `"pong"` |
| `loopback_start` | `in`: `device`\|`sine`; `out`: `device`\|`null`\|`wav:PATH` | `{"input": "...", "output": "..."}`: what was opened |
| `loopback_stop` | | `true` (also when none was running) |

Errors: `loopback already running`, `unknown input ...`, device failures
(e.g. no 48 kHz config), and `invalid request: ...` for anything that doesn't
parse. A request too malformed to have an id gets `{"reply": null, "error": ...}`.

| Event | Fields |
| --- | --- |
| `loopback_stats` | once a second: `latency_ms` and its parts (`capture_device_ms`, `capture_ring_ms`, `codec_ms`, `playback_ring_ms`, `playback_device_ms`), `kbps`, `input_peak_dbfs`, `underruns`, `overruns`, `dropped` |
| `loopback_failed` | `error`; the loopback stopped on its own |
| `stream_error` | `error`; a device stream reported a problem |

The helper exits when its stdin closes (the Port is closed or the TUI dies),
stopping any loopback. It never writes to stderr in Port mode except a fatal
startup error, since stderr is the user's terminal.

Contract tests: `tests/port.rs` drives the built binary over stdin/stdout;
`clients/tui/test/tui/media_test.exs` drives it through `Tui.Media`. Both use
`sine`/`null`, so neither needs audio hardware.

## Dependencies

Each one must be justified here (purpose, license, whether it pulls in C);
`cargo deny check` enforces the license policy in `deny.toml`.

| Crate | Purpose | License | C? |
| --- | --- | --- | --- |
| `cpal` 0.18 | Mic and speaker I/O | Apache-2.0 | Links the OS audio APIs (CoreAudio via `objc2`; ALSA via `alsa-sys` on Linux, which needs alsa-lib headers to build) |
| `opus` 0.4 (+ `opusic-sys`) | Opus encode/decode, the codec browsers offer by default | MIT/Apache-2.0; libopus BSD-3-Clause | Yes: `opusic-sys` builds the reference libopus from bundled source and links it statically. Needs `cmake` at build time (pinned in `mise.toml`) |
| `ringbuf` 0.5 | Lock-free SPSC rings between the real-time callbacks and the worker | MIT/Apache-2.0 | No |
| `serde` 1, `serde_json` 1 | The Port's JSON messages (the TUI side already uses Jason) | MIT/Apache-2.0 | No |
| `hound` 3.5 | WAV output for `--out wav:PATH` (hardware-free checks) | Apache-2.0 | No |

The transitive tree has duplicate versions (`thiserror` 1/2, `syn`,
`jni-sys`); cargo-deny reports them as warnings and they don't fail the check.

## Checks

`just native-check` (part of `just precommit`): `cargo fmt --check`,
`cargo clippy --all-targets -- -D warnings`, `cargo test`, `cargo deny check`.
