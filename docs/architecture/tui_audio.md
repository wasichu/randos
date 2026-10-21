# TUI audio (Phase 4.3): design

Status: **accepted 2026-10-19** (decisions below). Stage 0 in progress.
Researched 2026-10-19. Each claim is marked **[run]** (we ran it here, Elixir
1.20.4 / OTP 29.1.1, macOS arm64), **[source]** (read in package source,
metadata, or official docs), or **[unverified]** (reported but not checked;
treat as a risk). Raw research notes live outside the repo
(`/private/tmp/claude-501/research/`).

## Goal and constraints

Give the TUI (`clients/tui`) real two-way audio with a browser peer, so a
terminal user can actually talk. Constraints from the project:

- **As little native code as possible, and isolated.** A NIF crash takes the
  whole VM (and the TUI) down; native code also multiplies the 4.4 packaging
  matrix (macOS arm64/x86_64, Linux glibc/musl, Windows). ex_ratatui is
  already one precompiled NIF.
- **Interop with our browsers in both roles.** The participant who matched
  first offers; the other answers. Browsers use plain defaults: `addTrack`, no
  SDP munging, no codec preferences, `echoCancellation`/`noiseSuppression`/
  `autoGainControl` on [source: `assets/js/randos/media.js`,
  `webrtc_client.js`].
- **Our ICE setup.** Per-call `ice_servers` push: `stun:turn.slowinput.org:3478`,
  `turn:…:3478`, `turns:…:5349` with TURN REST credentials; trickle ICE through
  the channel's `signal` relay; coturn relays UDP only (`no-tcp-relay`) but
  clients may reach it over TCP/TLS.
- **Pronunciation matters** (language practice), and Phase 5 will put a voice
  anonymizer between the mic and the encoder.
- **The protocol and `Tui.Model` stay as they are**, apart from the TUI
  sending real offers/answers/candidates.

## The decision: where does the media stack run?

### Option A: WebRTC in the BEAM (`ex_webrtc`) + a small audio I/O helper

`ex_webrtc` 0.17.0 (2026-06-22) handles ICE/DTLS/SRTP/RTP in Elixir; mic,
speaker and Opus come from elsewhere.

What we found:

- **It works on OTP 29**: a two-peer loopback (Opus m-line, SDP through
  `to_json`/`from_json`, trickled candidates) reached ICE connected → DTLS
  connected → RTP delivered [run]. CI is ubuntu + OTP 29 only, no macOS [source].
- **But it brings native code into the VM, compiled on every user's machine**
  [source]: `ex_dtls` (NIF over OpenSSL, found via pkg-config), `ex_libsrtp`
  (NIF over libsrtp2; libsrtp precompiled only for linux/linux_arm/macos_arm,
  none for Intel Mac, musl, Windows), `crc` (C NIF). No precompiled NIF
  tarballs; no pure-Elixir fallback for DTLS/SRTP.
- **It broke on this Mac** [run]: bundlex refuses without pkg-config (not
  installed); the precompiled libsrtp wanted `libcrypto.3.dylib` while
  Homebrew's default OpenSSL is 4, so the NIF failed to load and the peer
  connection crashed at DTLS. Fixed only with a shim and a symlink. Open
  issues include a DTLS failure with OpenSSL 3.6 on aarch64 and Windows builds.
- **TURN: UDP only, and stricter than our URLs** [run]: `turn:host:3478`
  (no `?transport=`) is rejected as unsupported; `?transport=udp` reached
  coturn (401 with dummy credentials); `turns:` is rejected; no TURN over
  TCP/TLS. (RFC 7065 doesn't define a default transport when `?transport=` is
  absent; it defers to RFC 5928, so our URLs are valid and browsers accept
  them [source].)
- **No codec or audio I/O**: Opus would come from `membrane_opus_plugin`
  (libopus NIF, pulls in `membrane_core` and three more native builds) and
  mic/speaker from a helper anyway.
- Interop tests cover only the answerer role, against static browser SDP
  fixtures [source]. Firefox needs `ice_aggressive_nomination` when we offer
  [source].

Net: four or five NIFs inside the VM, compiled on users' machines, with
OpenSSL/libsrtp/libopus security updates landing in the BEAM, plus a helper
for audio I/O regardless.

### Option B (recommended): one Rust media helper, run as a Port

The TUI keeps signaling and UI in Elixir. A single helper binary
(`clients/tui/native/`, Rust) owns all media: WebRTC, Opus, mic/speaker,
echo handling. Elixir talks to it over an Erlang Port (framed stdin/stdout).

- **Zero new NIFs.** A helper crash closes the Port; a supervisor restarts it
  and the TUI keeps running.
- **One artifact per target**, built in CI and downloaded like ex_ratatui's
  precompiled NIF, so users need no C toolchain, pkg-config, or OpenSSL.
- **No OpenSSL anywhere**: str0m's `rust-crypto` feature is pure Rust
  (aes-gcm, p256, sha2, hmac; [source]).
- **`turns:` becomes possible** (see TURN below), which `ex_webrtc` can't do.
- **Cost: we own more code**, roughly 1.5–3k lines of Rust [unverified
  estimate]: host candidate gathering, TURN glue, a jitter buffer, the audio
  pipeline, and the Port protocol.

"As little native code as possible" cuts both ways: A means less code *we
write* (a few hundred lines for audio I/O) but four or five NIFs *we run* in
the VM. B means more code we write but nothing native in the VM and nothing
compiled on users' machines. On the two criteria named for this phase (crash
isolation and the packaging matrix), B wins clearly.

#### WebRTC library: str0m (fallback: webrtc-rs)

| | str0m 0.24.1 (2026-10-03) | webrtc-rs `webrtc` 0.21.1 (2026-10-11) |
| --- | --- | --- |
| Style | sans-IO, synchronous; we own sockets/timers (fits a single-threaded Port loop) | async (tokio default) |
| Maintenance | daily commits [source] | active; 0.21 is a layer over the sans-IO `rtc` core, pre-1.0 [source] |
| Crypto | `rust-crypto` = pure Rust, **no C** [source] (wrong in practice, found 2026-10-20: its DTLS certificate generation pulls in AWS-LC, see the helper README); also aws-lc, openssl, apple/windows native | `ring` (C/asm via cc) or aws-lc [source] |
| TURN client | **none built in** [source]; relayed candidates accepted, we do the allocation and wrapping | **UDP only**; `turns:` and non-UDP skipped [source] |
| Trickle ICE / both roles | yes / yes (offer, accept_offer, accept_answer) [source] | yes / yes [source] |
| Platforms | Windows, Linux gnu, macOS listed as tested; **musl not listed** [source] | undocumented [unverified] |
| Browser CI | none (browser-driven examples only) [source] | none (examples only) [source] |

**Recommendation: str0m**, because it's the only verified path with no C at
all and the only one that can reach `turns:`. TURN comes from ystreet's
sans-IO crates (`turn-client-proto` 0.7.3 covering RFC 5766/6062/6156/8656;
`turn-client-rustls` for TLS) [source]. Integration with str0m is
**[unverified]**. Expect edge cases in ChannelData, permissions and refresh.

**Checkpoint:** if str0m plus the TURN glue isn't working with a real TURN
allocation by the end of Stage 1, switch to webrtc-rs and accept UDP-only
`turn:` (which matches our coturn's UDP relaying) and ring's C build.

**Checkpoint passed (2026-10-20): staying on str0m.** `turn-client-proto`
0.7 glued to str0m in ~250 lines (`src/relay.rs` plus the call loop); a
whole relay-only call (ICE, DTLS, Opus both ways) runs through our coturn
(`just turn-check`). What the integration needed: relayed peer data handed
to str0m with the *relayed* address as its destination; permissions
installed per remote candidate; candidates trickled even before the
answerer knows its mid. One crate quirk: with bad credentials it reports
failure only after its transaction timeout (~40 s), by design; our wrapper
fails fast instead (it recognises coturn's refusal). `turns:` (TLS)
is still unbuilt; `turn-client-rustls` is the path if a network needs it.

#### Codec: Opus, statically linked reference libopus

- **G.711 is not good enough as the main codec for pronunciation.**
  - It's narrowband (8 kHz sampling, nothing above 4 kHz).
  - Recognition of /s/ needs ~4–5 kHz of bandwidth for male talkers and up to
    ~9 kHz for female and child talkers (Stelmachowicz et al. 2001, JASA
    110:2183), and energy above ~5 kHz is perceptually significant (Monson
    et al. 2014) [source].
  - Measured on a synthetic sibilant-heavy sentence [run]:

    | | Energy above 3.4 kHz (vs. full) | Above 8 kHz |
    | --- | --- | --- |
    | original | −13.1 dB | −41 dBFS |
    | Opus 24 kbps | −14.9 dB | −42 dBFS |
    | G.711 μ-law | −31.6 dB | gone |

    This is a spectral measurement on a synthetic voice, not a listening test.
- **Opus costs nothing noticeable**: libopus encode ~142 µs and decode ~16 µs
  per 20 ms frame [run]. Browsers offer Opus by default, and RFC 7874 makes
  Opus, PCMU and PCMA mandatory for every WebRTC endpoint [source].
- **In the helper: the `opus` crate over `opusic-sys`** (bundles libopus
  1.6.1, BSD, built with cmake and statically linked [source]). This is the
  helper's one piece of C, built on *our* CI, never on users' machines.
  - **Escape hatch:** `opus-rs` (pure-Rust port of libopus 1.6). It calls
    itself "production-ready" but is still fixing codec bugs as of Oct 2026
    [source] and hasn't been checked against the RFC 6716 test vectors
    [unverified].
- **G.711 stays as a fallback and test reference.** μ-law is about 20 lines of
  code and matched ffmpeg bit-for-bit [run]. It's negotiated only if Opus
  fails.

#### Mic and speaker: `cpal` inside the helper

- `cpal` 0.18.2 (2026-08-16) covers CoreAudio, ALSA (also PipeWire/PulseAudio
  via ALSA), JACK and WASAPI [source]. It needs `libasound2-dev` to build on
  Linux, and static alsa-lib on musl is known friction [source].
- **Options not chosen:**
  - **NIF** (`membrane_portaudio_plugin` 0.19.6): no crash isolation, compiled
    on the user's machine, nothing prebuilt for musl or Windows, and it drags
    in `membrane_core` [source].
  - **ffmpeg/sox as Ports**: fine for a quick macOS spike [run: the pipe
    framing worked, 1920 B per 20 ms frame of 48 kHz mono s16le], but sox is
    stale and ffmpeg lacks Windows audio output [unverified].
- **Latency:** ~10 ms device buffers each way plus jitter buffer. Stage 0
  measured the loopback's own pipeline on a MacBook Pro (built-in mic and
  speakers, both 48 kHz f32) at **≈81 ms**: capture device 12.2 ms + capture
  ring 1–8 ms + codec 26.5 ms (one 20 ms frame + 6.5 ms Opus lookahead) +
  playback ring 21–28 ms + playback device 12.9 ms [run, from cpal callback
  timestamps]. A real call adds the network and a jitter buffer, and drops
  the loopback's playback-ring slack.
- **Headphone test (2026-10-19), Bluetooth** [run, by the owner]: MacBook Pro
  mic (48 kHz) into Shokz OpenRun Pro 2 (bone conduction, output resampled
  to 44.1 kHz): **≈290 ms**, of which ≈192 ms is the playback latency macOS
  reports for the Bluetooth device. The rest: capture 12 + capture ring 3–9
  + codec 26.5 + resample 10 + playback ring 40–50 ms. Zero underruns,
  overruns, or drops. By ear the echo "felt super fast", so the reported
  Bluetooth figure may be conservative, or ~290 ms is unobtrusive over bone
  conduction; not settled. No feedback with open-ear headphones at a
  moderate volume. The TUI's `t` mic test (through `Tui.Media` and the Port)
  showed ≈280 ms, matching the standalone helper.
  - Worth trimming later: the playback ring holds 40–50 ms on Bluetooth
    versus ≈25 ms on the built-in speakers (Bluetooth pulls bigger chunks).

#### Echo cancellation

Browsers do AEC for free; a native client doesn't.

1. **v1: headphones required.** We can't reliably detect them (cpal only
   reports device names), so the TUI tells the user before the call. Add
   simple ducking (attenuate the mic while the far end speaks) as a cheap
   safety net.
2. **Then:** a pure-Rust AEC in the helper, either `sonora` 0.2.0 (described
   as a pure-Rust port of WebRTC's APM: AEC, noise suppression, AGC) or `aec3`
   0.4.0 (self-described work in progress). Both are **[unverified]** beyond
   crates.io metadata, and their licenses need checking. On macOS, the OS's
   VoiceProcessingIO unit gives AEC for free but means bypassing cpal there
   [source].
3. Not chosen: `webrtc-audio-processing` (wraps the C++ APM; heavy
   cross-builds), Speex DSP (weak AEC, stale).

AEC needs the far-end signal time-aligned with the mic, which is another
reason the helper owns both streams.

## Architecture

```
          Elixir (clients/tui)                               Rust helper (Port)
 ┌──────────────────────────────────────────┐        ┌─────────────────────────────────────────┐
 │ Tui.App ─ Tui.Model (unchanged, pure)     │        │ str0m PeerConnection (+ TURN glue)       │
 │ Tui.Connection (Slipstream, channel)      │        │ jitter buffer → Opus decode → speaker    │
 │ Tui.Media (new GenServer: owns the Port,  │◀──────▶│ mic → [AEC/duck] → SEAM → Opus encode    │
 │   relays signals helper ⇄ channel)        │ frames │ cpal capture/playback (48 kHz mono)      │
 └──────────────────────────────────────────┘        └─────────────────────────────────────────┘
```

- **`Tui.Media`** (new) starts the helper when a call reaches `in_call`.
  - It passes the call's `ice_servers` and the WebRTC role, relays
    `offer`/`answer`/`ice_candidate` between the helper and the channel, and
    reports `connection_established` / `connection_failed` /
    `peer_disconnected`, exactly as the browser does.
  - `Tui.Model` gains only "media up/down" display state. The participant
    state machine stays on the server.
- **Port protocol:** length-prefixed frames (`{:packet, 4}`), JSON or ETF
  control messages (start, signal in/out, stats, error) plus binary PCM frames
  when the seam's bounce mode is on (below). The helper exits when stdin
  closes.
- **Our TURN URLs need no server change**: the helper parses
  `turn:`/`turns:` itself, using UDP for `turn:` without `?transport=` (what
  browsers do).

### Phase 5 seam: a frame bus with two bindings

The anonymizer sits on the capture path: mic → AEC → **seam** → encoder,
carrying post-AEC 20 ms frames of 48 kHz mono PCM. The seam supports two
bindings, so Phase 5 isn't decided now:

- **In the helper:** a `Processor` trait (frame in → frame out) for DSP or an
  on-device model (e.g. ONNX). Lowest latency, and a crashing model can't take
  down the BEAM.
- **Bounce to Elixir:** frames go up the Port to an Elixir processor (e.g. Nx)
  and come back. More latency and copying. Kept only as an option for
  model-based experiments; DSP variants are Rust (decision 2).

The browser's matching seam is unchanged: `processLocalStream` in
`WebRTCClient.startConnection()`.

### What happens to the 4.2 rules

- **`end_call` on a peer's `offer` stays as the fallback** whenever the helper
  isn't usable: not built for this platform, no mic permission, no device, or
  it failed to start. Otherwise the helper answers the offer.
- **Helper crash mid-call:** the supervisor restarts the helper, the TUI sends
  `end_call` and shows why. No attempt to re-offer in v1.
- **`find` carries `audio: true` only once the helper can carry the call**
  (Stage 1, with a working device). Capability-aware matching is built: until
  then the TUI sends `audio: false` and only meets other text-only clients.

## Implications

- **Crash safety:** no new NIFs, and the helper is supervised. (Option A's NIFs
  would have needed dirty-scheduler care; `membrane_opus_plugin` runs on the
  regular scheduler [source].)
- **Packaging (Phase 4.4):** per target, ex_ratatui's NIF plus one helper
  binary. Built in CI as a matrix, checksummed, and fetched like ex_ratatui's
  precompiled releases. Cross-builds need cmake and a C cross-compiler for
  libopus (or `opus-rs` instead), and alsa-lib on Linux.
- **Licenses:** str0m MIT/Apache, cpal Apache-2.0, libopus BSD, turn-client
  crates and AEC crates to be verified; no GPL/LGPL (FFmpeg avoided).
- **Security updates:** `cargo audit` plus dependency alerts on the helper.
  There's no OpenSSL to track, and libopus is vendored and pinned (track its
  advisories).
- **Toolchain:** Rust joins `mise.toml` as a *build* dependency, needed only to
  build the helper (not added yet).
- **macOS mic permission (TCC):** access may be attributed to the hosting
  terminal app, and an unsigned helper unpacked by Burrito may behave
  differently [unverified, high impact]. Prove this in Stage 0.
  - Stage 0 result: the helper run directly from an already-authorized
    terminal got real mic audio (a −46 dBFS room floor; a denied mic yields
    all-zero samples) [run]. Launching through `Tui.Media` under `mix tui`
    (the `t` mic test) also worked, with **no prompt**: access is attributed
    to the hosting terminal, which already had it [run, 2026-10-19]. Still
    unproven: the first-time prompt on a terminal without mic access, and a
    Burrito-unpacked or Homebrew-installed binary (4.4/4.5).
- **Testing and CI:**
  - The helper takes `--in sine|wav:PATH|device` and
    `--out null|wav:PATH|device`, so CI runs the same binary without audio
    hardware.
  - `Tui.Media` is tested against the real helper binary rather than a fake
    Port, using the hardware-free `sine`/`null` loopback (stronger, and just
    as fast); `tests/port.rs` covers the same contract from the Rust side.
  - `just tui-smoke` grows a TUI↔browser scenario: Chrome with
    `--use-fake-device-for-media-stream` (already used by `just smoke`), the
    helper with `--in sine --out wav`, asserting received energy in both
    directions.
  - On Linux CI, the ALSA `snd-dummy` driver or a PulseAudio null sink could
    exercise the real device path [unverified].

## Staged plan

0. **Skeleton (macOS arm64):**
   - The helper with Port framing, cpal capture/playback, and Opus
     encode → decode loopback (mic → speaker through Opus).
   - `Tui.Media` starting, stopping and restarting it.
   - Proves the toolchain, the Port protocol, macOS mic permission, and
     latency (which we finally get to *measure*).
1. **Browser interop, the real test.**
   - str0m peer in the helper, trickle ICE through the channel, both roles,
     Chrome and Firefox.
   - A real TURN allocation with real REST credentials over UDP (the audit
     only ever saw a 401).
   - Headphones required.
   - Ends with the str0m-vs-webrtc-rs checkpoint and an automated TUI↔browser
     call in `just tui-smoke`.
   - **Status:** tracked in `refactor_plan.md` (4.3), not here.
   - **Moved up from Stage 2 (done 2026-10-19): resampling.** The first
     headphone test failed on Shokz OpenRun Bluetooth headphones, whose
     output offers only 44.1 kHz (music mode) or 16 kHz (call mode) [run].
     Bluetooth is common, so the helper now resamples any device rate with
     whole 20 ms frames to and from 48 kHz.
2. **Hardening:**
   - `turns:` via turn-client-rustls.
   - Jitter buffer tuning and packet-loss concealment.
   - Device selection, mute.
   - Scoped and ordered (2026-10-20) in `refactor_plan.md` (4.3).
3. **AEC:** sonora or aec3 (or macOS VoiceProcessingIO), so headphones become
   optional. Chosen (2026-10-20): `sonora` 0.2 (BSD-3-Clause, ~820k
   downloads, a pure-Rust port of WebRTC's audio processing, the canceller
   Chrome uses); `aec3` describes itself as a work in progress, and
   `webrtc-audio-processing` wraps C++. To verify on adding it: no C in its
   tree, 48 kHz mono, 10 ms frames.
4. **Packaging (with 4.4):** a CI matrix of helper binaries, starting with
   macOS arm64 plus Linux glibc x86_64; Intel Mac, musl and Windows after.

### Native code this introduces

- **One helper binary per target** (Rust). Its C is a statically linked
  libopus and (found 2026-10-20) AWS-LC, which str0m's DTLS pulls in; both
  built on our CI.
- **No new NIFs**, and nothing compiled on users' machines.

## Decisions (2026-10-19)

1. **Option B:** all media in one Rust helper run as a Port; no `ex_webrtc`.
2. **Phase 5 anonymizer:** written once in Rust, used natively by the
   helper's `Processor` and compiled to WASM for the browser (revised
   2026-10-19 from "prototype in Elixir, ship in Rust", so there's one
   implementation; see the roadmap's Phase 5). Not tied to Nx/Bumblebee.
3. **v1 platforms:** macOS arm64 and Linux glibc x86_64; Intel Mac, musl and
   Windows with 4.4 packaging.
4. **Headphones required in v1** (plus ducking); echo cancellation in Stage 3. Done (2026-10-20): calls cancel echo (sonora's AEC3), so headphones are now recommended, not required; no ducking.
5. **Capability-aware matching before Stage 1**, so the TUI and the browser
   offer equivalently good experiences: `find` carries `audio`, and the
   matchmaker only pairs compatible clients.
6. **Rust is a pinned build dependency** in `mise.toml`.
