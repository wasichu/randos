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

Devices run at 48 kHz when they offer it. Otherwise the helper takes the
highest f32 rate with whole 20 ms frames (so Bluetooth headphones' 44.1 kHz
music mode wins over their 16 kHz call mode) and resamples each frame to and
from Opus's 48 kHz on the worker thread (`src/resample.rs`, rubato's FFT
resampler; its delay shows as `resample_ms`). The cpal callbacks only copy
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
| `call_start` | `role`: `offerer`\|`answerer`; `ice_servers` (the call's, from the channel's `state`; `stun:` URLs give server-reflexive candidates, the first UDP `turn:` URL with credentials a relayed one); `in`/`out` as above (default `device`); `bind_ip` (tests: `127.0.0.1`; default: the default route's address) | `{"input", "output"}` |
| `call_signal` | `type` and `payload` of a peer's signal, exactly as the channel's `signal` push has them (`offer`, `answer`, `ice_candidate`; others are ignored) | `true` |
| `call_stop` | | `true` (also when none was running) |

One loopback or one call at a time (`loopback already running`, `call
already running`); `call_signal` without a call is `no call running`.

Errors: `loopback already running`, `unknown input ...`, device failures
(e.g. no 48 kHz config), and `invalid request: ...` for anything that doesn't
parse. A request too malformed to have an id gets `{"reply": null, "error": ...}`.

| Event | Fields |
| --- | --- |
| `loopback_stats` | once a second: `latency_ms` and its parts (`capture_device_ms`, `capture_ring_ms`, `codec_ms`, `resample_ms`, `playback_ring_ms`, `playback_device_ms`), `kbps`, `input_peak_dbfs`, `underruns`, `overruns`, `dropped` |
| `loopback_failed` | `error`; the loopback stopped on its own |
| `stream_error` | `error`; a device stream reported a problem |
| `call_signal` | `type`, `payload`: a signal for the peer in the channel's shape; push it as the channel's `signal` event unchanged |
| `call_state` | `state`: `connected`, `disconnected` (may recover), or `failed` (the call stopped; `reason`) |
| `call_stats` | once a second: `packets_sent`, `packets_received`, `concealed`, `dropped`, `skipped_candidates`, `send_errors` (cumulative), `local_candidates` (kinds offered so far: `host`, then `srflx` and/or `relay` as they arrive), `input_peak_dbfs`, `output_peak_dbfs` (last second), `capture_ring_ms`, `playback_ring_ms` |

**Calls.** The helper binds one UDP socket and offers it as its host
candidate, which is in the offer or answer SDP (no local trickle yet). Remote
`ice_candidate`s are applied once the remote description is set (earlier
ones are buffered); end-of-candidates and browsers' mDNS `.local` host
candidates are skipped (counted in `skipped_candidates`), since the
browser's own checks still reach our host candidate. Mic audio is dropped
until `connected`. Received frames are decoded, with Opus concealment for
gaps, and played. For each `stun:` server in `ice_servers` the helper sends a STUN Binding
request from its call socket (`src/stun.rs`, messages via `stun-types`:
str0m's STUN parser requires MESSAGE-INTEGRITY, which public STUN servers
don't send), and trickles the mapped address as a `srflx` `ice_candidate`. That lets peers on other networks reach us
through most NATs. A failed UDP send (an unreachable candidate) is counted
in `send_errors`, never fatal.

For networks where that isn't enough (symmetric NATs, strict firewalls) the
helper allocates a relay on the first UDP `turn:` server (`src/relay.rs`,
over `turn-client-proto`): one allocation per call, freed when the call
stops; data goes in Send/Data indications (no channel binding). It trickles
the relayed address as a `relay` candidate (candidates are trickled once our
SDP is out, with `sdpMLineIndex` 0 and `sdpMid` once known: an answerer
learns its mid only later, and a relay candidate the peer never hears of
gets no TURN permission, so the peer's checks are dropped), installs a permission for each
remote candidate's IP, and wraps str0m's packets from the relay candidate
for the TURN server. A relay that fails (or credentials coturn refuses) only
means no relay candidate; the call never waits on it. `turns:` and TCP
TURN aren't supported.

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
| `str0m` 0.24 (+ `str0m-proto`, `str0m-rust-crypto`, `is`) | WebRTC: ICE (`is`), DTLS, SRTP, RTP, SDP. Sans-IO (no threads, async, or callbacks), so the call is one plain loop we own. Built with `--no-default-features --features rust-crypto` | MIT/Apache-2.0 | No: `rust-crypto` is pure Rust (no OpenSSL) |
| `serde` 1, `serde_json` 1 | The Port's JSON messages (the TUI side already uses Jason) | MIT/Apache-2.0 | No |
| `rubato` 5 | Sample-rate conversion between a device's rate (e.g. 44.1 kHz Bluetooth) and Opus's 48 kHz; pulls in `audioadapter`, `realfft`/`rustfft`, `windowfunctions` | MIT/Apache-2.0 (deps MIT, Apache, Zlib) | No |
| `turn-client-proto` 0.7 (+ `turn-types`, `stun-proto`, `stun-types`, `sans-io-time`) | TURN client (RFC 8656): allocate, refresh, permissions, Send/Data indications, long-term credentials. `stun-types` 2 is also a direct dependency: our STUN Binding requests and replies (`src/stun.rs`), so there is one STUN codec, not two. Sans-IO like str0m, so it runs inside the call loop. Pulls in `rand`, `hashbrown`, `smallvec`, `base64`, `tracing` and pure-Rust hashes for MESSAGE-INTEGRITY | MIT/Apache-2.0 | No |
| `turn-server-proto` 0.7 (dev only) | A fake TURN server for the hermetic relay tests; pulls in `pnet_packet` | MIT/Apache-2.0 | No |
| `hound` 3.5 | WAV output for `--out wav:PATH` (hardware-free checks) | Apache-2.0 | No |

The transitive tree has duplicate versions (`thiserror` 1/2, `syn`,
`jni-sys`); cargo-deny reports them as warnings and they don't fail the check.

## Checks

`just native-check` (part of `just precommit`): `cargo fmt --check`,
`cargo clippy --all-targets -- -D warnings`, `cargo test`, `cargo deny check`.

`just turn-check` (by hand, needs the coturn state passphrase in the
Keychain): the ignored `production_turn_*` tests against the real coturn,
with short-lived TURN REST credentials derived from the shared secret
without printing it. Two allocations relay data to each other, and a whole
call runs relay-only (no host or STUN candidates, like a browser's
`iceTransportPolicy: "relay"`; `CallConfig::relay_only`, not in the Port
protocol), so ICE, DTLS and audio all go through TURN. The hermetic tests
use a fake TURN server and can't prove that: on one machine the host pair
always wins.
