# Compact FARGAN experiments

## Browser feasibility outcome: retain Signalsmith

**Listening outcome:** the owner heard robotic sound on the high voice, judged
FARGAN otherwise fairly equal to Signalsmith, and subjectively preferred
Signalsmith overall. `results/browser-listening.json` preserves the exact
conversation note against the browser report/input fingerprints; it does not
invent per-voice ratings or a disguise score. The recommendation is to retain
Signalsmith and park FARGAN mic/iPad/product integration for now. There is no
demonstrated listening advantage to justify that next investment, despite the
promising browser resource screen. Preserve all recordings and earlier reviews.

The next proposed small audition is independent formant-bandwidth modification:
test whether changing the width of resonances adds useful vocal character,
keeping their centers and pitch fixed relative to the Signalsmith reference.
Glottal-source shaping remains a separate subsequent candidate. Neither is
implemented or qualified by this outcome.

The owner found both final combined FARGAN and Signalsmith useful, with different
preferences by voice. Preserve those notes and fixed presets. Reproduce the screen
with `just voice-fargan-browser`, using the existing pinned native cache and Emscripten
SDK from the earlier DSP browser experiments. No new model download is needed.
It exports a separate Opus tree and builds separate portable/native and WASM
libraries; the accepted native quality build is never reconfigured. Source,
model, flags, compiler receipts and linked library hashes guard cache reuse.

Both engines receive the same public 48 kHz float fixtures. FARGAN includes
causal SILK conversion to 16 kHz, feature extraction/editing, synthesis and
conversion back to 48 kHz. Signalsmith retains its full 48 kHz bandwidth and
shipping 80 ms input batching. Neither is artificially restricted to the other's
bandwidth. The only profiles are Fuller (−1 semitone, .8 scale) and Brighter
(+1, 1.25). The causal editor also transforms silence: it cannot know in advance
which frames will be the final padding. This path received its own listening check.

FARGAN consumes 10 ms internal frames but emits variable counts: initially zero,
then 5 ms, then 10 ms per frame. EOF drains the retained final features. Never
pad missing output with original speech. Fatal owned-ABI sanitizer checks,
native/Python feature checks and bit-exact 10/20 ms partition checks precede
browser tests. Actual WASM outputs are compared with portable native outputs;
numerical conformance and successful execution are separate results. A numerical
mismatch requires new listening approval, not reuse of the native ratings.

Fresh Workers and independent 20 ms producer timers test sustained operation;
input and simulated output queues are bounded to two seconds. A common simulated
200 ms playout prefill is a test condition, not product policy. Compute, queue,
timer lateness, missed periods and starvation are separate. Required availability
includes producer/Worker scheduling; it is not device or call latency. SILK
input-delay fields are samples at the resampler's input rate, not total filter
latency. Fixed 200 ms fixture padding is not charged as live startup delay.

`results/browser.json` records provenance, transfer sizes, WASM linear memory,
numerical/partition results and fresh-Chrome process-tree RSS per timed engine
and preset. RSS includes Chrome overhead and is approximate; it is not just
model memory. The local `tmp/fargan/browser/report.html` gives a compact measured
table and level-matched actual browser recordings, with the new portable native
path as a control. It never changes saved owner reviews. This first screen uses
no microphone, physical audio, AudioWorklet, WebRTC or iPad. Browser sound and
sustained queues must pass before building that next live/device gate. Product
processors and bundles remain unchanged.

After this bounded gate, the next distinct DSP auditions are glottal-source
shaping and independent formant-bandwidth edits, one small comparison at a time.

## Previous round: final combined preset

The owner found the isolated pitch/resonance edits too subtle and authorized
one final combined comparison, potentially matching the Signalsmith settings.
`just voice-fargan-combined` reuses the accepted quality build/cache and the
validated native transform checker from the isolated screen. No new weights,
native rebuild, training or browser integration is required. Run the preceding
quality/isolated recipes first if their verified caches are missing.

Original16k / unchanged FARGAN / combined FARGAN / Signalsmith reference cover
the four voices and the test tone. Pitch is −1 with scale .8 for high/mid, +1
with scale 1.25 for low/Wasichu. These match Signalsmith's nominal pitch and
low-frequency scale, **not** its full transformation or resulting sound.
The approximate inverse envelope lookup is `f/scale` through 4 kHz, then a
linear continuation from `4000/scale` to the unchanged 8 kHz endpoint. Both
segments have positive slopes (.8: 1.25/.75; 1.25: .8/1.2); the derivative
changes at 4 kHz. This is materially stronger in the low/mid band than the
earlier smooth tapered warp. Eighteen-band conditioning and neural synthesis
remain different from Signalsmith's processing.

`combined_features.py` deliberately leaves the earlier bounded editor unchanged.
The existing pitch-only path is reused, with unsupported periods left unchanged
and counted. Envelope calculations preserve pitch, C0, voicing and fixed padding;
the combined result must equal those two separate calculations in their own
feature families. Eleven offline invariants include monotonicity, endpoint/
junction continuity, low-band scale, unchanged flat compensated spectrum,
identity bytes and input immutability. Native C DCT checks and nine silence/
onset/tail tests also run. All five raw unchanged controls must match accepted
hashes. Cached speech and boundary features are verified before reuse.

`results/combined.json` stores actual band lookups, settings, coefficient
excursions, output levels, native metrics and exact provenance. Older quality
and isolated reports/reviews stay intact under Previous experiments. The new
prepared modification is also available in Listen & compare. All four versions
use the same RMS matching/common peak headroom and sequential playback pauses.
Original is exact cached model-input PCM; Signalsmith is reused quantized
playback. Only the raw FARGAN control claims byte identity.

This is the final simple FARGAN feature-edit audition: if it still offers little
disguise or loses too much clarity, park this approach and move to a different
technique. A listening winner would merit an early browser feasibility test;
there is no live-mic handoff or product integration in this round.

## Previous round: isolated masking edits

The owner judged the unchanged control slightly less clear/crisp, but good
enough to try masking. `just voice-fargan-mask` reuses that accepted build,
feature cache and quality report; it does not download weights or rerun the
quality experiment. If the cache is absent, prepare the quality gate below first.

The isolated lab view compares **Original · 16 kHz / Unchanged FARGAN /
Pitch only / Resonance only / Signalsmith reference** on all four voices and
the test tone. The quality gate remains under Previous experiments, with its
own review contexts intact. The new three FARGAN choices also appear in Listen
& compare. This round still has no live-mic handoff or browser performance claim.

Pitch-only changes logarithmic feature 18 by ±1/12, preserving the other
nineteen features. High/mid pitch goes down one semitone; low/Wasichu goes up,
following the existing reference assignments, not an automatic classifier.
Proposed periods outside 32–256 samples remain unchanged and are counted;
the current five sources need no such skips. Fixed leading/trailing 20-frame
padding regions are never edited.

Resonance-only undoes the coefficient-zero bias (+4), applies the transpose
of the native orthonormal DCT, adds log10 band compensation, and interpolates
that log envelope over the pinned band's actual Hz coordinates. The inverse
sampling map is `g(f)=f+(1/s−1)f(1−f/8000)²`, where `s=.9` for high/mid and
`1.1` for low/Wasichu. It is monotonic, fixes DC/Nyquist, and tends to slope one
at Nyquist. This is a gentle frequency-dependent envelope warp, not uniform
formant scaling. After forward DCT and bias restoration, original C0 is
restored; that preserves mean log-band level, **not waveform RMS**. Pitch,
voicing and fixed padding are untouched. No combined edit is prepared yet.

The separate file-only `check_transform.c` links the pinned native library and
obtains its DCT basis by transforming all 18 unit vectors. Matrix orthogonality,
constant vectors and actual-frame forward/transpose round-trips must agree
within documented float32 tolerances (2e-6 matrix, 5e-5 feature coefficients).
The accepted native probe/build remains untouched. The checker uses the same
parent-pipe EOF ownership and bounded wait pattern; its small runner stays
separate from the accepted quality driver to preserve that baseline.

Identity features preserve bytes exactly; fresh unchanged synthesis must match
the accepted raw float output hash on all five sources. Pitch-only preserves
BFCC/voicing; envelope-only preserves pitch/voicing/C0. Finite complete outputs,
raw peaks, coefficient excursions, pitch limits and all settings are recorded
in `results/masking.json`. Full silence and synthetic onset/tail tests run for
control, both pitch directions and both envelope directions; silence peaks
above .001 fail preparation. These are technical guards, not listening scores.

Original comes from the verified cached model-input PCM; Signalsmith reuses
the accepted PCM16 playback with its old gain reversed approximately. Only
the raw FARGAN control has a byte-identity proof. All five playback versions
are RMS-matched together with shared peak headroom, without limiting. Audio
remains content-addressed, with new exact-context preferences and autosave.
Neither the old report nor the owner's feedback is overwritten.

`just voice-fargan-test` runs six numerical invariant tests in the existing
offline evaluation environment; precommit includes it without needing model
weights, native builds, a DSP environment or a network inference call. The
masking recipe separately runs the native transform and output checks.

The question is whether either isolated edit adds enough perceived disguise
to justify its clarity cost. Stop if neither does. Only a promising listening
candidate merits combining edits or an early WASM/Worker feasibility probe.

## Previous round: unchanged-synthesis quality gate

`just voice-fargan` builds the pinned official Opus C implementation in ignored
`tmp/fargan` and prepares **Previous experiments → FARGAN · synthesis quality**.
No training, PyTorch, text transcription, speech-to-text/TTS, microphone or
remote inference is involved. Prerequisites are git, curl, autotools/libtool,
make, clang/clang++, Node, and the existing `tmp/voice-dsp/.venv` (NumPy,
SciPy, SoundFile). It adds no product dependency or Homebrew installation.

The owner rejected both Selective resonance bends as worse than the released
Signalsmith reference. Preserve those recordings/reviews; do not promote them.
The next hypothesis is a small neural vocoder rebuilding speech from acoustic
features. **This first gate does not edit features or claim masking.** Listen
before building the feature-editing or browser path.

## What to compare

All four public voices and the test tone have:

1. Original at the existing lab's 48 kHz playback rate.
2. The same original resampled to 16 kHz and quantized like the model input.
3. Unchanged features extracted and synthesized with FARGAN at 16 kHz.
4. The released Signalsmith strong-resonance + one-semitone reference.

Compare **2 vs 3** for resynthesis loss, and **1 vs 2** for bandwidth loss.
The fourth sample keeps the product reference accessible; it is not a fair
masking-strength comparison with an unchanged synthesis control. Listen &
compare also offers FARGAN with the matched 16 kHz original explicitly labeled
on the left. Play-all pauses, looping and exact-context autosave are reused.
Feedback asks whether synthesis quality justifies masking edits. No live
handoff is offered. Tone output is diagnostic; this speech model need not
faithfully reproduce general audio.

## Reproducibility and signal handling

`pins.json` fixes the official Opus commit and SHA-256-checked data archive.
Existing source must match the pin and have no tracked edits. The upstream
archive is about 135 MB because it includes several Opus models and research
checkpoints; it is not FARGAN's required runtime download. Source license:
Opus BSD-style `COPYING`; the owned driver retains the upstream demo notice.
No runtime/model data is redistributed as part of randos.

The file-only driver uses the pinned encoder's actual 20 features and FARGAN
state. Features are never modified. Full 160-sample input frames get 200 ms
leading/trailing silence. Initialization repeats the first feature vector;
output follows the upstream initial 80-sample skip and two ending iterations.
Only fixed padding is cropped; no per-output correlation alignment is done.
The driver retains the last valid features at EOF explicitly, instead of
relying on the demo's loop-local array storage. All float outputs must be
finite and complete. Float WAV preparation avoids the demo's int16 saturation;
raw above-full-scale counts are reported before common playback attenuation.
RMS matching and shared peak headroom apply across all four versions, with no
limiter. Upsampling to 48 kHz restores no lost high-frequency detail.

The native worker owns no device. A raw-read stdin EOF watchdog exits 72 on
parent loss; the runner holds the pipe, imposes a 60 s deadline and closes,
waits, then kills on timeout. Bootstrap checks the EOF contract. Whole fixture
arrays are an offline rendering convenience, not bounded streaming buffers.

`results/quality.json` fingerprints source/driver/build/model files, exact PCM,
features, synthesized floats and immutable playback WAVs. It records padded
input duration, initialization/processing time, subprocess wall time, fresh
worker peak RSS, pitch-period clamp diagnostics and raw output levels.
The native executable and model-object file sizes are distinct from the
multi-model setup archive. Neither predicts browser asset transfer exactly.
RSS excludes the Python parent and browser; it is not directly comparable to
our earlier Chrome process-tree measurements. Offline real-time factor is
throughput, **not call latency** or a mobile/WASM qualification.

If this control sounds acceptable, the next small round is pitch-only and
approximate envelope-only edits with an untouched resynthesis control. The
current pinned encoder uses logarithmic pitch feature 18 and transformed
correlation feature 19; do not assume an older LPCNet raw-period convention.
Any cepstral edits need the exact Opus DCT, coefficient-zero bias and band
frequencies, with an identity round-trip test first. Only a useful listening
candidate warrants an early WASM/Worker size, memory and sustained-speed probe.

## Other DSP directions not yet auditioned

These are plausible research directions, not demonstrated masking winners:

| Direction | New question | Qualification |
| --- | --- | --- |
| Glottal-source/pulse shaping | Can excitation shape change vocal character without added hiss? | More targeted than our earlier WORLD breathiness/noise adjustment; inverse filtering and source estimation can add artifacts. |
| Formant bandwidth modification | Does widening/narrowing resonances help beyond moving their centers? | Our McAdams and current scale/bend experiments primarily move resonance positions. Language sounds must stay clear. |
| TD-PSOLA / pitch-synchronous overlap-add | Can a different pitch/spectral implementation sound cleaner? | This is a different engine, not a wholly new masking cue. Pitch marking and voiced/unvoiced boundaries are failure points. |
| Pitch-contour or modulation-spectrum reshaping | Do small changes to pitch dynamics or temporal envelopes reduce recognizable habits? | Lower priority: intonation, lexical tone, timing and pronunciation matter in language practice; low-latency causality also needs checking. |

Primary literature:

- [Voice conversion based on parameter transformation (1998)](https://www.isca-archive.org/icslp_1998/gutierrezarriola98_icslp.html): glottal source, formants and bandwidths as separate parameters.
- [Contribution of the glottal flow residual in affect-related voice transformation (2022)](https://www.isca-archive.org/interspeech_2022/wang22ca_interspeech.html): source/residual modeling and naturalness limitations; not an anonymization guarantee.
- [Speaker Anonymization by Pitch Shifting Based on Time-Scale Modification (2022)](https://www.isca-archive.org/spsc_2022/mawalim22_spsc.pdf): TD-PSOLA versus phase-vocoder processing under VoicePrivacy evaluation.
- [Preserving Mental Health Information in Speech Anonymization (2022)](https://psi.engr.tamu.edu/wp-content/uploads/2023/11/chaspari2022speechAnonimization.pdf): evaluates a DSP cascade including modulation smoothing; its results do not isolate the contribution of smoothing.
- [FARGAN paper](https://jmvalin.ca/papers/valin_fargan.pdf) and [official inference guide](https://github.com/xiph/opus/blob/main/dnn/torch/fargan/README.md).

Ordinary VTLN, uniform pitch shifting and McAdams are already represented in
our experiments. Renaming another frequency warp is not a new technique.
Judge sound, disguise and resource costs separately from strong recognition
attacks; none of these methods establishes anonymity by itself.
