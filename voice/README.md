# randos_voice: the voice processors

Rust DSP and experimental processors; the [architecture map](../docs/architecture/refactor_plan.md)
distinguishes current product masking from lab research. The Rust processors
below can run natively or as WASM. Released masking uses Signalsmith through a separate
owned native bridge in `voice-native/`, connected to the TUI worker through
session-only product choices (off by default). Browser calls use the same
Signalsmith settings through the pinned WASM SDK; WORLD remains lab-only. `just voice-bridge-check` verifies
the real Rust/C++ boundary and live adapter against saved browser PCM.

- **Legacy/experimental Rust seam in the browser:** compiled to WASM (`just voice-wasm`, committed as
  `assets/js/randos/voice/randos_voice.wasm`, since production builds have
  no Rust) and run inside an AudioWorklet by `assets/js/randos/voice/worklet.js`.
  Each variant is a small worklet entry (`passthrough.js`, `pitch_shift.js`)
  that names it and declares its parameters (`parameterDescriptors`, in
  `Processor::set_param`'s index order). The seam, `voice/seam.js`, puts
  one between the mic and the call.
- **Legacy/experimental Rust seam in the TUI:** linked natively into the media helper (`clients/tui/native`),
  whose call runs one on every mic frame (`CallConfig::voice`).
- **The voice lab** (`/dev/voice-lab`, dev only) includes browser-rendered and
  prepared native/model auditions. Their labels and fingerprinted reports say
  which implementation produced them; a prepared audition is not proof of live
  browser/native call behavior. Unpromoted processors remain development-only.

## Processors

| Variant | id | Parameters | Algorithmic delay |
| --- | --- | --- | --- |
| Passthrough | 0 | none | 0 |
| Pitch shift (`src/pitch.rs`): a delay-line ("Doppler") shifter, two crossfaded read heads | 1 | `semitones` (-12..12, default -4), `window_ms` (10..100, default 40) | about half the window (≈ 20 ms by default) |
| Experimental McAdams (`src/mcadams.rs`, dev lab and renderer) | 2 | `alpha` (.5..1, Rust default .8, lab default .9); 48 kHz only | 1,022 samples (21.29 ms) |

The pitch shifter moves formants with the pitch, so voices sound smaller or
larger rather than like someone else: v0's baseline, not the answer.

### McAdams experiment

A fresh, dependency-free implementation of the LPC pole-angle method
described in [the McAdams paper](https://arxiv.org/abs/2011.01130), not a
copy of the reference implementation or an exact reproduction. It filters
and decimates 48 kHz to 16 kHz, analyzes 20 ms frames with a 10 ms hop and
LPC order 20, changes conjugate pole angles to `angle^alpha`, and retains
the excitation residual. Normalized square-root-Hann overlap-add and
interpolation reconstruct 48 kHz output. The two 63-tap FIRs intentionally
limit bandwidth around 6 kHz. Alpha=1 bypasses LPC and controls for this
bandwidth, resampling and overlap-add; a separate test checks LPC identity
analysis/synthesis.

Root solving has a fixed iteration bound, reconstruction and conjugacy
checks; analysis/synthesis failures mute the affected frame instead of
passing through the original voice. Diagnostics count failures and clipped
samples. Unsupported sample rates mute/count failures internally; the WASM
constructor and renderer reject them. The streaming processor allocates
only on construction, with fixed buffers in its processing path.

This candidate is available in the Rust renderer and dev-only lab worklet
(`assets/js/voice_lab/mcadams.js`), with no production call setting. Neither
tested coefficient (.7, .9) resists known-recording matching; .7 also clips.
Both remain available for listening: naturalness, intelligibility and how
different a voice sounds are separate judgments from this recognition test.
Recovering the original-sounding voice is assessed separately: the lab's
Recovery test has an initial approximate known-setting reversal, awaiting
listening feedback. Do not infer resistance to reconstruction from the
recognition results or from bandwidth loss.

The lab preserves the causal delay and appends 1,022 zero samples to emit
the complete audio tail. Live preview requests a 48 kHz AudioContext for
McAdams. The lab initializes both small worklets' controls once, remembers
settings independently, and automatically renders when the modification
changes. The candidate's wrapper is built only by the dev asset profile;
the production call registry is unchanged.

## Rendering offline (`examples/render.rs`)

Mono little-endian `f32` samples on stdin, processed, the same out on
stdout, in 128-sample blocks like a worklet. `tools/voice-eval` uses it,
so the benchmark measures exactly the code calls run:

```bash
cargo run --release -p randos_voice --example render -- \
  --variant pitch_shift --rate 48000 --param 0=-4 --param 1=40 < in.f32 > out.f32
```

Use `--variant mcadams --param 0=0.9` for the experiment. The optional
`--align-delay true` flushes McAdams with 1,022 zero samples and removes its
leading delay while preserving the original duration. The benchmark uses
this for both trials and references; streaming calls still incur the delay.
Pitch shifting has time-varying read heads, so it has no exact fixed delay
alignment here. A JSON diagnostics line goes to stderr; stdout stays raw
audio. Timings include processing in 128-sample blocks, not browser scheduling.

`--variant mcadams --inverse-alpha 0.9 --align-delay true` selects the
offline recovery probe. It receives disguised samples and the forward
coefficient, reestimates LPC, and uses the reciprocal exponent to move pole
angles back. This is distinct from `set_alpha`, whose forward range stays
.5..1. Reestimated poles can lie outside the theoretical forward image;
angles above π are capped at π−1e-6 instead of being folded by cosine.
Diagnostics separately count corrected poles/frames, failures, and clipping.
There is no inverse WASM variant or production call setting.

## The WASM interface

No bindings generator: `src/wasm.rs` exports plain functions over numbers
(`voice_new`, `voice_input`, `voice_output`, `voice_set_param`,
`voice_process`) and the worklet shim writes and reads the instance's memory
directly. Each AudioWorklet node instantiates its own copy of the module, so
module state is one processor's. The module imports nothing.

For an offline comparison of native and WASM output on the four bundled
speech clips, build the release renderer and WASM, then run
`node tools/voice-eval/check_wasm.mjs`. It checks sample agreement and reports
warm Node WASM timings including buffer copies. These are not AudioWorklet
deadline guarantees; browser and device measurements remain separate.

**Unsafe:** the crate denies `unsafe_code`; `src/wasm.rs` alone allows it,
for the `#[unsafe(no_mangle)]` attribute that exporting a symbol requires.
There is no unsafe block anywhere.

**No panics:** `unwrap`, `expect`, `panic!` and slice indexing are denied by
clippy outside tests (the workspace's shared lints, root `Cargo.toml`;
printing to stdout too, since the helper runs this code next to its Port);
a panic in the worklet would silence the call.

**Reproducible:** `just voice-wasm` remaps std's source paths to rustc's
own (`/rustc/<commit>`), so the build doesn't embed the machine's paths and
is byte-identical everywhere; `just voice-wasm-check` (in
`just native-check`) fails if the committed file is stale. It needs the
`wasm32-unknown-unknown` target (`mise.toml`).

## Dependencies

None.
