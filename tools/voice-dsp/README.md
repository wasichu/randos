# Model-free voice masking screen

`just voice-dsp` prepares four WORLD variants for each public recording in
**Listen & compare → Modification → Model-free DSP · WORLD**:

| Choice | Question |
| --- | --- |
| Unchanged resynthesis control | Does rebuilding the voice itself lose too much quality? |
| Pitch only | Is independent pitch control cleaner than our delay-line shifter? |
| Pitch + resonances | Does spectral-envelope warping provide a useful different voice? |
| Pitch + resonances + breathiness | Does a small excitation/noise change help, or just add hiss? |

No trained weights, text transcription, TTS model, remote inference, or real
call audio is involved. All four public clips are prepared; no microphone
recording or upload is added. The lab loads small immutable WAV pairs through
its existing playback, spectrogram and text-only review controls. These
choices are offline auditions; no production processor is selected.

`just voice-tone` also prepares synthetic-tone diagnostics for these choices
using the same worker. The tone is a fifth lab source, not speech or evidence
of masking quality. That command leaves the four-voice report untouched.

## Reproduce and inspect

The command creates `tmp/voice-dsp/.venv` with Python 3.11.17 and installs exact,
hash-checked requirements. This separate environment does not sync or modify
the translation, voice-evaluation or TVTSyn environments. NumPy/SciPy/SoundFile
support array handling, resampling and WAV I/O; PyWORLD wraps the C++ WORLD
algorithms. Setuptools 80.9.0 supplies the legacy `pkg_resources` import required
by this wrapper. These are research dependencies only, not app/native/WASM deps.

`probe.py` runs one fresh worker per public clip, then atomically publishes
`results/listening.json` only when all WAVs are complete. The report records
source/WAV/native-extension hashes, exact package versions, script/lock hashes,
settings, gains, RMS, peaks, generated length, timing and peak worker RSS.
Published audio lives under `tmp/voice-model`, using the existing fixed dev-only
WAV endpoint and content-addressed filenames. Regeneration creates new review
contexts; earlier saved reviews and audio remain available in local storage.

All inputs are resampled from 24 to 48 kHz with SciPy's polyphase resampler,
attenuated by .25 for processing and padded with 100 ms of ending space. WORLD
Harvest estimates F0 at 5 ms intervals, range 50–800 Hz. CheapTrick uses a matching
50 Hz floor (FFT4096), explicitly shared with D4C. Default CheapTrick's FFT2048
would treat F0 below ~70 Hz differently, biasing low-voice controls. D4C's default
voicing threshold remains .85; Harvest nonzero-F0 counts are before that decision.

The control retains pitch, envelope and aperiodicity. Pitch shifts are −2
semitones for high/mid and +2 for low/Wasichu; unvoiced F0 stays zero. Envelope
scales are .9 and 1.1 respectively: interpolate log power at `frequency/scale`.
This changes the full envelope, including unvoiced consonants and bandwidth;
it is not isolated vowel-formant editing. Texture adds .12 of the remaining
aperiodicity range, capped at one. Amounts are fixed experiments, not automatic
speaker adaptation or guarantees against identification/recovery.

Every version, including the control/original, keeps the same 6.1-second
length. Whole-clip RMS is matched and one shared attenuation per source keeps
peaks at or below .9 without limiting. This controls average signal levels,
not exact perceived loudness. A neutral WORLD control may still sound unlike
the original; judge it before attributing artifacts to masking changes.

## Resource and integration boundaries

No neural weights are downloaded. Native Python/C++ analysis and transform+
synthesis times exclude imports, resampling, normalization and WAV export.
Real-time factor divides analysis plus transform/synthesis time by six seconds;
it is an offline throughput number, not call delay. Fresh-worker peak RSS
includes Python, imported libraries and full-clip arrays; it is not browser
memory, optimized C++ streaming memory, or a measured incremental cost.
The extension's installed bytes are not the size of a future WASM bundle.

Harvest currently analyzes the whole recording. Streaming would need a new
analysis/windowing design and a fidelity check against these auditions. A
browser probe must measure actual WASM bytes, startup, sustained processing,
memory and capture-to-output delay before any production choice. Native Rust
integration of C++ would also need an explicit FFI/unsafe-boundary decision or
an alternative implementation under this repo's Rust rules. Do not start a
large port before the owner finds a listening candidate worth pursuing.

## Sources and alternatives

[WORLD](https://github.com/mmorise/World) is modified BSD; its
[Python wrapper](https://github.com/JeremyCCHsu/Python-Wrapper-for-World-Vocoder)
is MIT. Preserve required notices in any future distribution. This screen
adds neither to the production dependency graph.

[Rubber Band](https://breakfastquay.com/rubberband/) is another useful pitch/
formant processing reference, but GPL/commercial rather than the workspace's
permissive-only dependency policy. It was investigated, not installed or
selected. The installed FFmpeg lacks its optional rubberband filter. Other
future auditions include PSOLA/WSOLA or a phase-vocoder pitch shifter, different
spectral warps, and a small pitch-window sweep in our current combined DSP.
Use listening, pronunciation preservation and client resource costs to choose
the next one; strong recognition attacks document limitations rather than
vetoing useful voice masking.

## Chunking screen: same sound settings, bounded input windows

After preparing the existing WORLD listening references and tone diagnostics,
`just voice-dsp-chunks` creates **WORLD · chunking comparison** choices for all
five lab sources. Left is explicitly labeled **Whole-recording WORLD**, right
**Chunked WORLD**, and the back-to-back button plays reference → chunked.
The resemblance question refers to the reference voice in this mode; it is
not a new identity-masking score. Existing listening cases and reviews remain
unchanged. Each new context is distinct and uses the existing auto-save flow.

The three output hop sizes are 40/80/160 ms. Every window contains 80 ms of
past input, the hop, 20 ms of output overlap and 40 ms of right context. Thus
initial input buffering is 100/140/220 ms before computation. The current
hop is finalized using the prior block's retained overlap; the new trailing
20 ms waits for the next block. This avoids hiding an extra hop of lookahead.
Complementary linear fades sum to one, including first/last samples. Negative
start context is zero; end context is zero only after EOS is known. No reference
alignment, whole-input F0 analysis, or future input outside that window is used.

Harvest, CheapTrick, D4C and synthesis restart per window. This can cause pitch
instability and independent excitation phase, including beating/cancellation at
joins. It tests a simple reset-synthesis wrapper, not the best possible streaming
WORLD implementation. A stateful synthesis API exists upstream; it would need
its own small fidelity/resource experiment if these resets are the problem.

Native scheduling uses `finish=max(input_release,previous_finish)+compute`.
The clock starts at preprocessed 48 kHz PCM. Required fixed playout delay is the
largest `finish−output_start`; it is an offline native simulation, not measured
browser or end-to-end call delay. Analysis/crop/overlap copying are timed;
resampling, whole-clip RMS presentation, WAV I/O, capture/output and transport
are excluded. Report steady queue wait separately from EOS flushing: at end of
input several windows become available together, which is not sustained backlog.
`results/chunked.json` retains block timings, input bounds, end-flush time,
reference/source/native-extension hashes, gains and output levels.

Levels match across the saved whole-recording reference and all three variants
for each source, with shared peak headroom and no limiting. This normalization
is for listening; it is not a causal live gain algorithm. The harness retains
full output/weight arrays to publish WAVs, so it is not a bounded-memory live
implementation. Pure offline tests cover identity joining, odd final hops,
endpoint coverage, prefix causality and the scheduling arithmetic. Listen for
clicks, periodic roughness and changed consonants before choosing any port.

## Three-adapter browser experiment

`just voice-dsp-browser` builds two small C++/WASM research modules, prepares
exact float32 inputs and native references, then runs muted Chrome through a
same-origin temporary server. It publishes five sources for each option in
**Listen & compare → Modification → Browser DSP**:

- WORLD pitch + resonance: the accepted 80 ms reset-window synthesis.
- Signalsmith pitch + resonance: a stateful spectral phase vocoder, seeded
  deterministically, with independent formant compensation.
- McAdams + delay-line pitch: the existing Rust chain as a lightweight reference.

These are actual browser-produced WAVs. Playback loads only WAVs, not DSP
modules or weights. Earlier cases and review contexts remain intact. The
paired player compares each with the **raw original**, unlike the older
whole-WORLD-versus-chunked comparison. Levels are matched across all three and
the original, retaining 100 ms of ending space. Listen before choosing a port.

Setup requires the existing `just voice-dsp` Python environment, a native C++
compiler, Rust, Node and Chrome. First setup downloads a pinned Emscripten SDK
into ignored `tmp/emsdk` (roughly 2 GB of build tools, never an app download),
Signalsmith Stretch/Linear sources, and hash-checked PyWORLD 0.3.5 sources.
Revisions and source checksum are in `browser/sources.json`; upstream WORLD
is BSD-3-Clause and Signalsmith Stretch/Linear are MIT. Their license files
remain beside the downloaded sources. Emscripten is a build tool, not a new
production dependency. No shell profile is changed. Native library builds
currently target macOS (`.dylib`); Linux packaging is outside this experiment.

The shared Worker contract emits contiguous spans at original input sample
positions and drains on EOF. Each adapter owns its algorithm state and
buffering; WORLD alone resets per window. The producer releases an 80 ms
block only after its final sample would arrive, on an independent absolute
clock. More than two seconds pending is an explicit failure. WORLD needs
140 ms of input for its first output; 80 ms input releases quantize that to
160 ms before computation. Signalsmith drains its declared input and output
latencies; McAdams flushes/aligns its known 1022 samples, while pitch has
variable acoustic delay that output emission timing does not measure.

Before pacing, all 15 voice/tone cases must reproduce native PCM with
relative RMS error ≤.001 and maximum absolute error ≤.01. Nine additional
silence/onset/end-boundary cases use the same strict thresholds. Their failures
remain explicit diagnostics and mark the affected candidate as an experimental
audition, not qualified for arbitrary inputs; finite contiguous complete output
is always required. The WORLD native wrapper also reproduces the accepted
Python implementation. Float32 input bytes, native reference/output bytes,
modules, tool versions and source identities are fingerprinted. A failed
speech/tone check or incomplete run retains a partial diagnostic report and does not publish new listening data. Boundary failures are retained
in the report and affected listening notes, rather than described as passing.

Each candidate then processes one minute of independently paced mid-voice
input. The runner retains a short repeating source but no full-minute output.
It reports setup, computation, pending Worker input, worst required output
playout, linear WASM capacity/growth, and approximate Chrome process-tree RSS.
RSS includes shared pages and retained allocations, so its deltas are not
precise per-algorithm costs. Raw and offline Brotli/gzip asset sizes are separate
from memory; localhost startup does not represent internet transfer time.

Inspect `/dev/voice-lab/browser-probe/dsp.html`, linked from the lab, and
`results/browser-probe.json`. This is a bounded Worker feasibility screen on
one machine, not an AudioWorklet deadline test, microphone/call integration,
mobile guarantee or proof against recognition/recovery. No production call
path, Rust FFI boundary, or masking policy is selected by this experiment.

## Stronger masking: compact comparison round

`just voice-dsp-round` uses the existing built Signalsmith modules and exact
baseline inputs to publish **Masking round**, a five-way audition:

| Version | Pitch | Resonances |
| --- | --- | --- |
| Original | unchanged | unchanged |
| Current | ±2 semitones | ×.90 / ×1.10 |
| More pitch | ±4 semitones | same as Current |
| More resonance | ±2 semitones | ×.80 / ×1.25 |
| Opposing directions | ±3 semitones | ×1.10 / ×.90 |

Pitch goes down for high/mid voices, up for low/Wasichu; the two resonance
values follow that order. Opposing is a combined experiment, not a one-variable
isolation. The synthetic tone follows the high/mid direction for diagnostics.
This round tests masking strength after the owner found the initial browser
outputs clear and acceptable but subtle. It does not add a new performance,
phone, microphone or privacy qualification. Existing impulse-parity differences
remain explicitly unresolved in the view's details and individual notes.

`browser/round.py` prepares exact native references; the same `run.mjs --round`
server/Worker/adapter verifies all 20 browser/native outputs without rerunning
the three-minute timing probe. Every Current PCM must equal the earlier accepted
browser reference before publication. New output files and reports are separate;
earlier prepared artifacts and review contexts remain untouched. Publish
normalizes the original and four alternatives together with common headroom.
The content-addressed WAV names, source hashes, ordered settings, gains and
processing report are bound into the whole-round preference context.

The compact view has one source choice, five individually playable rows with
amplitude waveforms, loop/stop controls, current-clip highlighting and sequential
playback with 250 ms gaps. Preparation is atomic across all five; changing a
source aborts pending work, and every lab player shares exclusive playback.
A single preference (including Current, None is useful, and Unsure) plus optional
notes uses the existing automatic-save/outbox/draft machinery. Tone votes are
artifact feedback, not masking evidence. The three new alternatives also appear
in the normal Modification menu for all five sources.

## Preferred-settings engine comparison and live headphone monitor

`just voice-dsp-engines` publishes a separate **Engine comparison** tab: Original
→ Signalsmith → WORLD. High/mid use −2 semitones/.9, low uses +2/1.1, and Wasichu
uses +2/1.25 after the owner's listening round. Mid remains explicitly unresolved
and tone is diagnostic. Every source has the same settings through both engines,
matched as one three-way level set. All ten browser outputs must pass native
parity and the Signalsmith bytes must match the reviewed preferred preset. The
old rounds/WAVs/review contexts remain intact; whole-round preference hashes bind
the new ordered files/settings/gains. The new pair also appears in Modification.

**Use live** transfers a row's engine/profile into **Try your voice** without
opening the microphone. Select **Signalsmith / WORLD experiment**, an engine,
and one of the four fixed profiles, then explicitly press Hear original or
Hear modified. Changing a profile/engine stops capture. Original/modified
switching reuses one microphone and maintains a warm DSP stream. Headphones and
low initial volume are required to avoid acoustic feedback. This is a delayed
self-monitoring experiment, not call integration or a mask that hides cadence.

The shared `assets/js/voice_lab/dsp/adapter.js` drives both public-clip auditions
and the live Worker. Only the small duplex AudioWorklet handles 128-frame capture
and playback. A direct transferable MessagePort connects it to the Worker:
80 ms input blocks, five reusable input buffers, at most 320 ms input pending,
a 640 ms output ring and 160 ms output prefill. Input/output spans must remain
contiguous and finite. Output clipping, overflow, stalled credits, or starvation
after starting stops visibly, with no dry fallback or automatic rebuffering.
Live Stop disconnects/mutes, terminates the Worker, stops tracks and discards
pending speech; it never flushes queued audio. Open adapters require an explicit
finite sample count to drain fixture tests, avoiding an infinite WORLD finish.

Both live paths use fixed .25 input headroom; there is no whole-clip RMS matching
or normalization of microphone audio. Browser capture may apply echo/noise/gain
processing. The displayed buffered delay is measured from input/output sample
coordinates and excludes microphone/device/output hardware latency. Prefill is
additional buffering, not total delay. Actual worklet fixture tests observed
~240 ms Signalsmith and ~277 ms WORLD on the initial run, not device guarantees.
Mobile performance and the owner's subjective live experience remain unmeasured.
Other devices require a secure origin for microphone access (existing dev HTTPS
configuration/`just certs`); this does not add audio uploads or a hosted service.

Pinned C++/WASM binaries and licenses now live under `assets/vendor/voice_dsp`;
`build.py --vendor` rebuilds them, and `check_vendor.py` checks wrapper/pin/asset
hashes offline in precommit. Dev-only ESM entries bundle these bytes into a
same-origin module Worker; no CDN, external runtime code/model fetch, SAB,
COOP/COEP header requirement, Rust FFI or production call change is introduced.
The normal deployment build does not include the voice-lab entries.

`voice_dsp_stream_smoke.mjs` drives the actual 128-frame bridge with generated
fixtures, then compares its complete rendered PCM against a separate offline
Worker supplied the exact captured PCM. It verifies startup silence, contiguous
alignment, ending energy, full length and bounded queues for both engines, plus
stalled-input and starved-output failures. Bounded fixture-only capture options
are never enabled by the UI. `voice_dsp_live_smoke.mjs` uses muted fake microphones
for lifecycle/cancellation/error tests; no real mic or call audio is recorded.

The live palette includes both mild and stronger resonance shifts in each pitch
direction: lower −2 with ×.90 or ×.80, higher +2 with ×1.10 or ×1.25. The lower/stronger
option was added after the owner's live test; the earlier asymmetric three-profile
palette only mirrored recorded-voice preferences, not an algorithm restriction.

## Gentler pitch and a bounded playback-buffer experiment

`just voice-dsp-gentle` prepares Original plus three Signalsmith variants for all
four voices and the tone: current ±2 semitones, half ±1, and zero pitch movement.
Each source keeps its previously selected resonance scale fixed (.9 high/mid,
1.1 low, 1.25 Wasichu). Zero pitch still processes resonance; it is neither Original
nor the “None is useful” review answer. `zero_pitch` and `none` are distinct IDs.
All 15 browser/native waveform checks must pass, with Current matching the earlier
reviewed PCM. Levels are matched across the complete four-way set, and the new
source/settings/audio-bound preferences preserve all earlier rounds and notes.
The Gentler pitch tab has existing individual/sequence/loop controls and Use live
hands off the exact pitch strength and resonance profile without microphone access.
The same three pitch strengths are available with any of the four live profiles.

`just voice-dsp-buffering` changes only Signalsmith's output prefill from 160 to 80 ms.
Input batches stay 80 ms, native DSP/analysis settings and all ring/credit limits
stay unchanged. The shared actual-callback fixture checks complete PCM against a
separate exact-input Worker render. Each mode then streams the repeated public
mid-voice clip for 60 s, retaining statistics rather than a minute of audio.
The report records contiguous input/output counters, terminal faults, sample-delay,
minimum/maximum post-render output occupancy, pending-input peaks, WASM capacity
and teardown. It never treats average compute speed as sufficient proof.

The initial run completed both modes with zero terminal faults and identical
fixture PCM. Measured buffer delay fell from 240 to 160 ms, excluding device/network
latency. Minimum post-quantum output occupancy fell from 80 ms to 0 ms; that indicates
less margin, not a recorded underflow. Both peaked at 80 ms unacknowledged input
and kept 32 MiB WASM capacity. This one-machine minute is not a phone guarantee.

Current 160 ms prefill remains the default. The Signalsmith-only shorter option
lives under Playback delay experiment in Try your voice, and is enabled only when
both the local exact-PCM and 60 s gates pass for current source/module hashes.
The recipe verifies vendor pins and rebuilds first; the report fingerprints the
actual served worker/worklet bundles, vendor bytes, fixture and probe sources.
Setup and execution have bounded deadlines with guarded cancellation and teardown.
Changing it stops capture and requires an explicit restart. WORLD rejects the
shorter configuration. Overload/starvation still stops visibly without dry fallback.
A changed bridge/worker/adapter/module/fixture invalidates the recorded eligibility.

First release must include **both browser and TUI**. These browser experiments
settle sound and buffering questions; they do not authorize a browser-first launch
or choose the unresolved native integration/unsafe boundary. Signalsmith remains
the shared candidate and native/WASM behavior/presets must agree before shipping.

## Native core at TUI frame cadence

`just voice-dsp-native` uses the pinned checkouts/modules and exact fixture bytes
from `just voice-dsp-browser`; it installs/downloads nothing. Requires `clang++`
with address/undefined sanitizers, the existing Python DSP environment and Chrome.
It builds a standalone C++ probe linked directly with unchanged `spectral.cpp`.
It does **not** link C++ into Rust, change the helper, touch audio devices or
select an FFI/subprocess architecture for production.

Four candidate settings exercise both directions: `(pitch, resonance)` =
`(0, .8)`, `(-1, .8)`, `(0, 1.25)`, `(+1, 1.25)`. These are two proposed style
families, not four promised product options or finalized per-voice settings.
All four settings run across the four public voices and canonical tone. Native
input arrives in 960-sample/20 ms slices, aggregates into the same 3,840-sample
calls as the browser, crops the declared core latency and flushes the complete
finite tail. The shared browser runner checks the same output with strict
relative-RMS/max-absolute tolerances. Silence/onset/ending diagnostics remain in
the report even when an impulse exceeds tolerance; they are not silently waived.

The native finite cases also run under ASan/UBSan with findings fatal. Then each
setting streams the repeated mid-voice input for a minute. Input release and
output delivery use an absolute 20 ms monotonic clock, unchanged by computation.
The core still processes 80 ms batches; output is delivered in 20 ms frames
after the existing 160 ms aligned-output prefill. Fixed queues throw on overflow
or starvation. Reported delay is a sample-coordinate delivery delay, excluding
devices, AEC, Opus, network and playback. Delivered samples include the frame
starting at the final 60 s boundary; they do not claim completed audible playback.
Live Stop discards the bounded queue; finite fixture rendering alone flushes.

`results/native-cadence.json` records frame compute percentiles/max, release and
delivery lateness, missed 20 ms periods, queue bounds, delivered counts, core
latency, initialization, whole-process RSS high-water readings, executable size
and standard-library dependencies. RSS includes fixture/driver/metrics, not just
the algorithm. Only scalar statistics and the short source are retained during
the minute. The starter holds an open stdin pipe; its closure, including parent
SIGKILL, immediately ends the probe. The runner imposes a deadline too.

`results/native-cadence-browser.json` preserves browser parity and build evidence;
`tmp/voice-dsp/native/report.html` gives a visual summary. Code, binary, modules,
compiler arguments, pinned source commits and the measured input are fingerprinted.
Neither successful cadence nor speech parity establishes working Rust/TUI call
integration, real-time callback safety, Linux qualification, phone performance,
or privacy strength. Next is a deliberate safe native boundary and actual call
validation in both clients before their joint release.

## Rust bridge and first call integration

`voice-native/` now isolates an owned Signalsmith C++ context behind a safe Rust
API; its README contains the FFI audit. The helper still forbids unsafe code.
Pinned MIT headers are vendored for offline native builds, independently of the
browser SDK. Each call owns its state; no global processor or sidecar process.

`just voice-bridge-check` compares both the raw Rust boundary and its causal
20 ms frame adapter with all saved browser outputs from the native experiment.
It verifies complete speech/tone PCM and retains the known impulse discrepancies
separately in `results/rust-bridge.json`. `just native-check` additionally runs
fatal ABI ASan/UBSan tests, header integrity, and native crate/helper tests.

Both clients now expose session-only product choices, default Off: changed tone,
or changed tone plus gentle pitch, with Fuller/Brighter direction. The browser
uses the pinned spectral WASM SDK in an owned Worker/AudioWorklet; the TUI uses
`CallConfig::masking` via the optional Port field, guarded by helper capability
negotiation. Explicit local mic auditions stop before calls and on exit.
Post-AEC input is gated on connection/mute and uses ×.25 headroom. Closing purges
queued speech; reopening creates clean state. Errors stop audio rather than
passing the original through. The stable browser processed track stays attached
to WebRTC through gate changes. Shared lab mechanics retain fixture capture only
in the dev entry. See the product integration checkpoint in the roadmap for
validation and remaining release limits.
