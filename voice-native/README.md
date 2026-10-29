# randos_voice_native

Owned native Signalsmith bridge for the TUI media worker. First integration
slice: `CallConfig::masking`, off by default, exercised in local real
Opus/WebRTC calls. The local Port choice now connects the TUI voice panel to
this path and its explicit audition. Browser calls use the same pinned
core/configuration through the production Worker/worklet.
Browser and TUI remain joint first-release requirements.

`Style` provides the two proposed families in both directions: resonance alone
at ×.8/×1.25, or that resonance plus −1/+1 semitone. These internal names are not
final UI labels or a promise of anonymity. Higher/lower direction is not inferred
from someone's voice. No inference model or runtime download.

## Boundary and safety audit

`src/ffi.rs` is the **only** Rust file allowing unsafe code. The helper remains
`forbid(unsafe_code)`; the workspace lints apply to this crate too. C++ Signalsmith
requires an FFI boundary, isolated here rather than weakening the helper or the
existing Rust/WASM voice crate.

- C++ allocates one `Context` per constructor; no global processor or shared
  scratch buffers. Rust holds one non-null opaque handle, with no Clone/Copy.
  Drop deletes it exactly once. C++ storage is never exposed as a Rust slice.
- Processing requires `&mut Engine`; Rust supplies non-overlapping borrowed
  input/output slices of identical checked length, 1..3,840 samples. C++ checks
  count and copies through fixed private scratch arrays, retaining no pointers.
  Output is checked for finite, representable f32 range before conversion.
  The finite flush has a fixed 1,920-element output buffer.
- C ABI entry points are `noexcept`. Constructors and processing catch every
  C++ exception and return null/status, never strings or ownership-bearing error
  pointers. The destructor releases standard containers with nonthrowing
  destructors. A fault is sticky. Rust clears output on every error.
- `Engine` is explicitly Send because all FFT/buffer/PRNG state belongs to that
  owner and has no thread affinity. This lets the existing call session move
  from its constructor to its worker. It is deliberately **not Sync** (Cell
  marker); safe callers cannot concurrently process a shared engine. There is
  no unsafe code in callers, tests, renderers or the TUI helper.
- C++/Rust scalar ABI types are `double`/`f64`, `float`/`f32`, `size_t`/`usize`,
  `int`/`i32`, and boolean, on the supported macOS/Linux native targets.

`Engine` preserves the raw core's startup/tail for exact finite comparisons.
`Masker` supplies bounded causal 960-sample ingress/egress around unchanged
3,840-sample core calls, crops the initial 3,840 invalid samples once and primes
7,680 output samples. Fixed input/output arrays never grow. Startup emits
silence; overflow, starvation, nonfinite or out-of-range output returns an error
and silence, with no dry fallback or automatic recovery. Explicit reset purges
both queues and replaces the C++ engine. Live Stop drops it without flushing.

The first valid frame is returned on the twelfth input call. This is 10,560
leading samples in concatenated returned frame arrays; with each 20 ms capture
frame available at its end, the first frame is delivered at 240 ms. These are
different coordinate conventions, **not** two additive delays. Relative to
unmasked 20 ms frame delivery, the adapter adds about 220 ms. Core latency,
batching and prefill overlap. Device, AEC, Opus and network delays are additional.

## Call placement

`clients/tui/native/src/voice.rs` owns the optional masker after echo cancellation
and before metering/Opus. It applies fixed ×0.25 input headroom, matching browser
live DSP, outside the raw engine. Normal unmasked/legacy calls retain their
existing gain/processing. The live adapter rejects output outside ±1 instead of
clipping or falling back. Finite raw rendering still exposes diagnostic PCM.

Native eligibility requires connected and unmuted. Closing that gate immediately
purges the DSP history and queues, even between frames. Reopening also discards
pending capture-ring samples and recreates resampler history, then re-primes;
muted/pre-connection samples never enter the native DSP. Capture/AEC keep draining
and RTP carries silence during mute/startup. Processing errors use the existing
call-failure path. Stacking a legacy processor and native masking is rejected.
All of this runs on the worker; cpal callbacks remain ring-copy-only. This does
not claim hard real-time callback safety for the C++ library.

## Build, dependencies and checks

- **Signalsmith Stretch / Linear:** MIT, vendored unchanged headers/licenses in
  `vendor/signalsmith`, at the browser experiment's exact commits. The manifest
  and `tools/voice-dsp/browser/check_vendor.py` guard bytes and matching pins.
  Generic FFT, seed 7, mono 48 kHz, configure(1, 3840, 960, false), no fast-math,
  floating-point contraction off. No Accelerate/IPP or external DSP runtime.
- **cc** (MIT OR Apache-2.0, build dependency already present in Cargo.lock):
  compiles our C++17 wrapper into a static archive using the system compiler.
  Requires a C++17 compiler and system C++ standard library on macOS/Linux.
  No build-time downloads, Emscripten SDK or Python needed to build the helper.

`just native-check` runs Rust fmt/clippy/tests, vendor integrity, and a fatal
ASan/UBSan black-box C ABI test (bounds, independent owners, destruction,
nonfinite input and sticky failure). The sanitizer subprocess is owned by stdin
EOF and has a deadline. Helper tests cover distinct preconnection/muted sentinel
tones, reconnect/re-prime, capture/resampler purge, gain/transients, and real
local Opus calls with continuing muted RTP and processed audio after unmute.

`just voice-bridge-check` additionally builds the finite renderer and compares
both the Rust raw core and live frame adapter with all saved browser fixtures
from `just voice-dsp-native`. This optional research check needs those local
PCM fixtures and the existing DSP Python environment; it never downloads them.
The result is `tools/voice-dsp/results/rust-bridge.json`. The known synthetic
impulse discrepancies remain reported separately from speech/tone agreement.
