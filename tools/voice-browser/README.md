# TVTSyn browser feasibility probe

`just voice-browser` prepares a native ONNX reference, then runs the **actual
published streaming model** in muted Chrome. It generates a listening and
timing report at `/dev/voice-lab/browser-probe`, linked from the lab's Models
view. Start the regular dev server with `just serve` to view it. No microphone
or live call is involved. This is an isolated research experiment.

## Why this candidate

Current goal: useful voice masking with natural, clear speech and sensible
download, memory, compute and latency costs. Recognition/reversal tests document
limits; they do not decide which candidates deserve listening. TVTSyn is a
quality reference, not a practical default established by this experiment.

`just voice-sound-check` covers all four public voices:
pitch only (−2 semitones for high/mid; +2 for low/Wasichu), McAdams resonance change only (.9), resonance then
pitch, and the saved native TVTSyn reference. No neural inference or downloads
run. Existing `comparisons.json` and its immutable TVTSyn WAVs are prerequisites.
Source and WAV hashes are checked, the Rust renderer is built, and
`results/sound-quality.json` records gains, peaks, RMS, settings, diagnostics and
provenance. All versions retain 100 ms of ending space; whole-clip RMS is matched
and one common attenuation per voice keeps peaks below .9, without limiting.
This is average signal-level matching, not a perceptual LUFS measurement.
The Modification menu groups these choices under Sound quality check, sharing
playback and saved reviews.
Mid voice supplies TVTSyn's target voice, so its model output is a labeled
target-voice control rather than disguise evidence.

Interpretation limit: these isolate processor operations, not pure acoustic
properties. The current pitch shifter also moves resonances; the McAdams path
includes bandwidth/resampling changes as well as pole warping. A rough McAdams
result alone cannot establish which part of that implementation caused it.

The owner's four Seed-VC reviews all described a different person. High/mid
voices were natural, low/Mencken slightly artificial; mid/Mencken had some
unclear speech. A changed accent and odd syllable stress made pronunciation
preservation a priority. The next uncertainty is browser feasibility.

[TVTSyn](https://github.com/PSI-TAMU/TVTSyn) publishes a complete stateful ONNX
step. StreamVoiceAnon has checkpoints but no published exporter was found;
LiveAnon's ONNX instructions still mark its own checkpoint download as pending.
TVTSyn lets us test a browser path without building a new model exporter.
Its **CC BY-NC 4.0 code and weights are research-only here**, not a production
selection. Passing this test says nothing about Seed-VC's browser feasibility,
other machines/browsers, speaker recognition or recovery resistance.

## Reproduce

For complete listening coverage after setup, `just voice-listening-complete`
fills missing browser-WASM cases across all four public voices. It preserves
the original high-voice manifest/context and any existing, hash-valid additional
cases. Each new case uses the same saved target embedding, exact-input native
reference and actual browser WASM with the waveform parity gate. Mid voice is
a labeled target-voice control. Additional runs are parity-only auditions,
not repeated paced/resource experiments; the original report stays intact.
No model weights are downloaded. `PREPARATION_FILE`, `INPUT_FILE` and
`MODES=parity` let the harness record the actual per-case inputs without
overwriting the original high-voice inputs or report.

With the dev server running, `just voice-lab-audit` checks every menu choice
against all four public voices, including earlier Seed-VC/INT8/DSP experiments
and WORLD. It validates source identity, prepared WAV hashes, complete playback
buffers and Original/Modified/paired playback, using muted Chrome and writing
no reviews. Artifact lengths are authoritative: some model outputs shorten
or lengthen speech. Results are saved to `tmp/voice-browser/lab-audit.json`.

The audit includes the generated test tone as the fifth source. After existing
research environments/cached models are ready, `just voice-tone` adds every
prepared modification for it without regenerating voices. The browser and Node
share `assets/js/voice_lab/test_tone.js`; source identity hashes that generator,
not the whole lab UI. Standalone browser completion checks cached tone PCM
against the generator before assigning that identity. The four-second harmonic
glide is not speech; all prepared tone cases are labeled diagnostics. Seed-VC's
`--tone` writes a separate report and requires cached-only weights; WORLD uses
the same worker on 48 kHz tone PCM. Fixed DSP, matched-level comparisons and
native/INT8/browser TVTSyn use their existing algorithms. Voice artifacts and
prepared review contexts remain unchanged. Browser tone parity checks a real
four-second conversion, not a six-second speech or paced-minute experiment.

The command uses separate Python 3.11.17 and npm environments. The exact Python
dependencies and npm dependencies are pinned in `requirements.lock` and
`package-lock.json`. Upstream TVTSyn is pinned to
`9aa67c0272620caaf43170fe98ec48438e1624e0`, and the published model bundle to
`e37063244a413f834fe976c1ba356d2ef37ece6c`. Existing tracked upstream edits or
a different revision are refused. Code, installed packages and generated
files stay in ignored local storage; no app/Rust dependency is added.

First run downloads the ~360 MB model and speaker-encoder dependencies.
`prepare.py` derives one fixed 704-value target embedding from the bundled
public mid-voice clip (Yoganandh T), then converts the six-second high-voice
clip (Elsie Selwyn) using native ONNX Runtime 1.24.3, CPU, four threads.
The model configuration pins both SpeechBrain speaker encoders. Source,
target, embedding, graph/config hashes and native timings are saved.

`run.mjs` builds first-party worker code with esbuild and serves all model,
runtime and input files from a temporary loopback server. No CDN or external
inference is used. The server lives in the same Node process as the runner.
Chrome uses the repo's CDP pipe, so it exits if that runner dies. All exit
paths close the browser/server and memory sampler. Default project tests
remain GPU-disabled and muted; this probe alone opts into GPU and the
`--enable-unsafe-webgpu` headless test flag. The actual adapter is recorded;
software/fallback adapters are rejected as hardware-performance evidence.
`CHROME_BIN` can select another Chrome executable. Runtime files use matching
ONNX Runtime Web 1.24.3. COOP/COEP headers enable four WASM threads; deployment
headers and cross-origin isolation are not established for production by this
throwaway site.

## What is measured

1. **Complete six-second conversion.** Every one of the 207 model states starts
   at zero, with the same chunk boundaries as native inference. One zero chunk
   drains the LA4 lookahead; output is cropped to exactly the received length,
   preserving the ending. Browser output must be finite and match native with
   relative RMS error ≤ .001 and maximum absolute error ≤ .01 before pacing.
   These are numeric compatibility checks, not privacy/quality thresholds.
2. **A paced minute.** The same public clip repeats ten times. Main-thread
   timers release 1600 samples every 100 ms on an absolute monotonic schedule,
   independently of inference. The worker receives only released chunks and
   starts from newly reset state. No sleep-after-inference can hide backlog.
3. **Whole-step time.** Includes input tensor/feed construction, inference,
   CPU-readable output/readback, state replacement/disposal and finite-output
   checking. Reported deadline counts exclude the final drain step; total
   elapsed time includes it. Output availability delay includes input chunking
   and lookahead, but **not microphone, audio playback or network-call buffers**.
   Unpaced timings are never interpreted as capture-to-output latency.
4. **Memory and startup.** Local model fetch and session construction are
   separate. Approximate RSS sums Chrome and descendant processes every two
   seconds; shared pages may be counted twice and GPU allocations are not
   isolated. The probe retains the minute's output (~3.84 MB) for inspection.
   The graph carries ~6.72 MB of fixed state. This short test cannot rule out
   leaks in longer sessions. A localhost 360 MB fetch does not represent an
   internet download time.

The report keeps failed/unavailable provider results. WebGPU requests may use
WASM for unsupported operators; a request alone is not proof of GPU execution.
The tested headless adapter was software SwiftShader, so hardware WebGPU
performance remains untested. WASM is evaluated independently.

## Follow-up comparisons and resources

After `just voice-browser`, `just voice-experiments` prepares the four public
clips through three fixed DSP chains, native TVTSyn, and one dynamic INT8
variant, then runs staged resource checks. The three DSP chains are McAdams
α=.9 followed by pitch −2 or +2 semitones, and α=.85 followed by −1 semitone,
all with 40 ms pitch slices. They use fixed .25 input headroom and retain a
100 ms pitch tail. Diagnostics show no failed frames or clipping for these
clips; that does not establish clean sound. The owner's listening found
partial masking and static-like degradation, with direction depending on the
source voice. Further strengthening these presets is not the next task.

All prepared choices are in **Listen & compare → Modification** with paired
fixed-gain original/modified WAVs, spectrograms, normal playback controls and
exact-context reviews. No neural weights or inference runtime are loaded by
selecting them. Microphone modification is unavailable for prepared choices;
original mic preview remains available. Existing model review contexts are
shared with the research section. Missing/unsupported samples clear stale
output and disable modified playback. The mid-voice source is also TVTSyn's
fixed target, so its conversion is explicitly a same-speaker control.

Resource follow-up uses fresh Chrome processes at empty page → runtime-only
(tiny identity graph, no speech model) → model ready → minute of streaming
without retaining PCM → worker terminated. Full-size four-thread runs repeat
once. The single-thread run omits cross-origin isolation. Process RSS remains
an approximation, but stage deltas show that the inference footprint is real:
roughly 316 MiB empty, 561–575 MiB runtime-only, 2434–2451 MiB model ready and
2203–2219 MiB after a minute. Four-thread p95 was ~30 ms; one-thread ~61.5 ms,
both below the 100 ms input interval with no paced misses/backlog on this Mac.
Worker termination does not return RSS to the clean-browser baseline.

The bounded dynamic INT8 attempt quantizes MatMul/Gemm weights per-channel,
leaving convolution and public audio/state types unchanged. The graph shrank
from 359,896,673 to 198,966,393 bytes. Native output is available for listening;
the owner found its masking effective. Browser/native parity still failed
after regenerating the native reference from the **exact same input.f32**
bytes (relative RMS ~.52, max absolute error ~1.15). No paced INT8 run is claimed.
Actual graph/input/speaker/reference hashes are recorded in its resource result.
The cause is not established; this variant is not browser-qualified.

Known-recording recognition is a separate optional experiment:

```sh
tmp/tvtsyn/.venv/bin/python tools/voice-browser/render_corpus.py
tools/voice-eval/.venv/bin/python tools/voice-browser/evaluate.py
```

It reuses the existing 20-speaker, five-utterance LibriSpeech selection. Two
utterances enroll each speaker; three different utterances are trials. The
renderer records source and output hashes; evaluation validates all IDs and
hashes before scoring. The saved result is `results/recognition.json`, using
fixed pretrained ECAPA and Whisper (no attacker retraining). Top-1 recognition
was 100% originally, 5% for transformed speech against original references,
and 21.7% with references transformed using the matching model/target. Matching
reference EER was 31.8%; word error rose from 5.7% to 9.2%. These findings show
some protection in this probe and retained identity evidence, not a calibrated
real-world probability or a full VoicePrivacy evaluation.

Original-voice reconstruction resistance remains **untested**. A model given
the original person's voice/embedding would be an oracle/reference attack,
not our recorded-output-only scenario. A meaningful learned recovery attack
would need paired training data from different speakers; a failed arbitrary
remapping would not establish protection. Pitch reversal/McAdams recovery
remain existing positive controls for simpler disguises.

CC BY-NC 4.0 is a **noncommercial** license, not inherently research-only.
Noncommercial sharing/adaptation still requires its attribution, notice and
change-marking conditions; quantization does not remove those. We keep these
experiments isolated and have not selected TVTSyn for production or promised
unrestricted redistribution. [Official license](https://creativecommons.org/licenses/by-nc/4.0/legalcode.en).

## Listening artifact

The generated page embeds fixed-gain PCM WAVs for Original, Native ONNX and
Browser, with exclusive native players and Original → Native → Browser
playback using the lab's existing cancellable comparison helper and 250 ms
pauses. Audio is scaled by .25 without per-clip loudness matching. The page
includes timing results and an approximate memory trace. Its JS and CSS are
local files built/copied from this repo. A dev-only controller serves exactly
three report filenames, never weights, raw input or arbitrary paths.

Exact data is in `results/browser.json`; audio/site output in ignored
`tmp/voice-browser`. These public-clip experiments neither record nor process
user conversations. Production call flow, audio processors and privacy policy
remain unchanged. Next work should be chosen from sound, mobile/memory/download
cost, and licensing evidence rather than assuming this prototype is shippable.
