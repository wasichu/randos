# randos_voice: the voice processors

Phase 5 (voice anonymization, `docs/architecture/refactor_plan.md`). Every
processor is written once, here, and runs in both clients:

- **Browser:** compiled to WASM (`just voice-wasm`, committed as
  `assets/js/randos/voice/randos_voice.wasm`, since production builds have
  no Rust) and run inside an AudioWorklet by `assets/js/randos/voice/worklet.js`.
  Each variant is a small worklet entry (`passthrough.js`, `pitch_shift.js`)
  that names it and declares its parameters (`parameterDescriptors`, in
  `Processor::set_param`'s index order). The seam, `voice/seam.js`, puts
  one between the mic and the call.
- **TUI:** linked natively into the media helper (`clients/tui/native`),
  whose call runs one on every mic frame (`CallConfig::voice`).
- **The voice lab** (`/dev/voice-lab`, dev only) renders clips through the
  same worklets, so what's judged there is what calls run.

## Processors

| Variant | id | Parameters | Algorithmic delay |
| --- | --- | --- | --- |
| Passthrough | 0 | none | 0 |
| Pitch shift (`src/pitch.rs`): a delay-line ("Doppler") shifter, two crossfaded read heads | 1 | `semitones` (-12..12, default -4), `window_ms` (10..100, default 40) | about half the window (≈ 20 ms by default) |

The pitch shifter moves formants with the pitch, so voices sound smaller or
larger rather than like someone else: v0's baseline, not the answer.

## Rendering offline (`examples/render.rs`)

Mono little-endian `f32` samples on stdin, processed, the same out on
stdout, in 128-sample blocks like a worklet. `tools/voice-eval` uses it,
so the benchmark measures exactly the code calls run:

```bash
cargo run --release -p randos_voice --example render -- \
  --variant pitch_shift --rate 48000 --param 0=-4 --param 1=40 < in.f32 > out.f32
```

## The WASM interface

No bindings generator: `src/wasm.rs` exports plain functions over numbers
(`voice_new`, `voice_input`, `voice_output`, `voice_set_param`,
`voice_process`) and the worklet shim writes and reads the instance's memory
directly. Each AudioWorklet node instantiates its own copy of the module, so
module state is one processor's. The module imports nothing.

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
