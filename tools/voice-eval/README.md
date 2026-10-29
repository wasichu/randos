# The voice-anonymization benchmark (Phase 5)

**Scope:** this diagnoses identity-matching limitations, not a shipping gate
for voice masking. Our experiment prioritizes audible masking, naturalness,
intelligibility/pronunciation and practical download, memory, compute and
latency costs. Preserve failed attack results to explain limitations accurately;
a research verdict does not veto listening.

Does a voice processor stop a speaker-recognition model from telling who is
speaking, while speech recognition can still understand them? Each
processor setting gets two numbers that matter:

- **identity**: ECAPA-TDNN (`speechbrain/spkrec-ecapa-voxceleb`, Apache-2.0)
  speaker verification, as an equal error rate (EER). 0% means voices are
  told apart perfectly, 50% means it's guessing: anonymization wants it high;
- **intelligibility**: Whisper (`openai/whisper-base.en`, MIT) word error
  rate (WER) against the transcripts: it should stay close to the original's.

Its own Python project, never part of the app: Python 3.13 and exact
versions in `pyproject.toml` / `uv.lock`, installed by `uv`.

```bash
just voice-eval-test     # the metrics and verdicts (offline, no models)
just voice-eval          # the benchmark: writes results/benchmark.json
just voice-eval --only mcadams_1 mcadams_0.7 mcadams_0.9 --output results/mcadams.json
```

The voice lab (`/dev/voice-lab`) shows `results/benchmark.json` in its
Benchmark section.

## How a run works

- **Speech:** a balanced subset of LibriSpeech test-clean (CC-BY 4.0):
  10 women and 10 men, 5 utterances each of 4 to 15 s (`data.py`; the same
  subset every run). Downloaded once (346 MB) into
  `~/.cache/randos/voice-eval/`, with the models; never committed.
- **Processing:** every clip goes through the real processors, the `voice/`
  crate's `render` example (`render.py`), at a call's 48 kHz.
- **Enrollment and trials:** each speaker is enrolled from 2 utterances
  (embeddings averaged); the other 3 are trials against every enrolled
  speaker (60 target and 1,140 non-target trials).
- **Attackers** (inspired by VoicePrivacy; not its full evaluation protocol):
  - *ignorant*: enrolled from the original voices, tested on processed ones;
  - *matching settings*: knows each trial call's exact processor parameters
    and transforms every speaker's enrollment with those parameters. Different
    parameter values keep separate reference prototypes; we never average
    differently transformed voices into a weaker reference;
  - *shifted back* (pitch shifts): undoes the shift, then compares with
    the original voices. For a fixed shift, by the opposite amount; for
    random shifts it tries every whole shift from −7 to +7 and keeps the
    best score against each speaker;
  - *parameter bank* (McAdams): enrolls separate reference voices for
    alpha .5, .6, .7, .8, .9 and 1.0; maximizes each speaker's score across
    them. The same maximum operation applies to genuine and impostor scores.
    This is a fixed embedding-model attack, not a retrained VoicePrivacy attacker.
- **Verdict** (`verdict.py`, provisional thresholds, not a standard): the
  research filter requires every measured EER to reach 30%, and WER to
  remain within 10 percentage points of the original. Passing only asks
  for listening and further review, never establishes anonymity. Failed
  frames or more than .1% clipped samples reject a trial setting. Reference
  diagnostics are retained per configuration so damage cannot hide in an
  aggregate; defective attack audio cannot support a positive verdict.

Reports also give top-1 identification accuracy (5% uniform chance with 20
speakers), per-stage elapsed times, trial and reference processing diagnostics,
and worst native 128-sample processing time. They record the alignment policy:
McAdams clips and references flush the known delay before cropping back to
the original duration; the time-varying pitch shifter has no exact fixed
alignment. These offline scores do not measure live call delay.

Protocol version 2 fixes tied-score EER thresholds and holds random pitch
settings constant over each speaker's simulated call (three trial clips),
seeded by setting and call ID. The known-parameter attack replaces the old
weak random-per-clip enrollment. `results/calibration.json` reproduces the
historical controls before that change and is not comparable as a new
protocol result. A full run is only a few minutes on the owner's Mac, so
`--only` selects existing settings rather than introducing a second corpus
or quick-mode framework. Offline tests use `.venv-test`, separate from the
model environment.

`check_wasm.mjs` compares native and WASM samples and timings on bundled
public-domain speech without playing it. After `just voice-wasm` and building
the release renderer, run:

```bash
node tools/voice-eval/check_wasm.mjs > tools/voice-eval/results/wasm-comparison.json
```

Its linear interpolation only prepares identical 48 kHz fixtures for both
builds; it is not the model benchmark's resampler. The output records Node,
CPU and WASM hash. Node timing includes sample copies and warm execution,
but cannot establish browser AudioWorklet scheduling performance.

Numbers from 20 speakers are rough (an EER moves in steps of a few
percent); they're for comparing processors, not for publishing.

## Separate recovery and listening probe

`just voice-recovery` generates eight comparisons from the four bundled
public LibriVox excerpts, using α=.9 and .7. It imports the existing model
environment's resampler but loads no recognition/transcription models and
trains nothing. It writes `results/reconstruction.json` and generated WAVs
under ignored `tmp/voice-recovery/`; regenerate the WAVs locally when needed.
The dev lab's Recovery test tab plays Original, Disguised, and Approximate
recovery (known setting), with sham recovery and two-pass bandwidth controls
in a disclosure. The players are exclusive, support looping, and pause when
the case or view changes.

The inverse receives only disguised samples and the known coefficient.
Original samples are used for controls, listening and a log-spectrum-distance
diagnostic, never supplied to the inverse or used to fit its parameters/gain.
All inputs use a fixed .25 gain chosen before the run to provide common
headroom. This is a different input condition from the full-level identity
benchmark; its lack of clipping does not revise that benchmark's .7 finding.
Every McAdams pass flushes and removes the known delay before retaining the
original duration. The cap policy, corrected-frame/pole counts, numerical
failures and clipping remain visible. These are approximate reconstructions:
LPC reanalysis, overlap-add and filtering prevent assuming an exact inverse.

The first eight cases have no failed/clipped frames/samples. Recovered
log-spectral distances are lower than disguised/sham distances in all eight,
but many frames need angle caps (especially .7). This supports listening,
not a claim that the original voice was recovered or that other attacks fail.
Known-pole inversion, identity and cap coefficients are tested; a separate
pitch-reversal listening positive control and unknown-setting search remain
follow-ups. Do not run a larger recovery evaluation before the owner hears
these examples.

The identity benchmark borrows the reference/trial framework from the
[VoicePrivacy evaluation plan](https://www.voiceprivacychallenge.org/vp2024/docs/VoicePrivacy_2024_Eval_Plan_v2.1.pdf),
but is not an official reproduction: our fixed pretrained model is not
retrained as its 2024 attacker is, and our known-setting probe grants exact
parameters. The [McAdams paper](https://arxiv.org/html/2011.01130v2) discusses
reversibility and tests ignorant/semi-informed matching; these are distinct
from recovering the original-sounding waveform. Naturalness, comprehension,
perceptual disguise, reconstruction, and reference-based identity matching
are separate assessment questions.

## Owner listening feedback

Listen & compare and Recovery test collect optional categorical judgments
of naturalness, clarity, and resemblance to the original person, plus notes.
Recovery has separate disguised/recovered judgments. All start “Not judged”;
no numeric score or required questionnaire is imposed. Browser drafts follow
exact contexts, not display labels. Explicit Save review appends a versioned
JSONL record to git-ignored `results/listening-reviews.jsonl`.

Records include source and processing fingerprints, parameters/mode, and
recovery run/case/headroom. Only ratings and text are accepted. Generated
WAV names are content-addressed and published atomically: an old open page
still fetches the same bytes after regeneration. The report records source
and native-renderer SHA-256 values. Local drafts are not submitted in the
background; failed saves keep answers in memory/browser storage as available.
The assistant reads the file when the owner says reviews are ready; the save
does not automatically invoke a model. Use the latest appended answer for
each exact context, retaining earlier revisions instead of averaging different
settings/builds/runs. These are qualitative observations, not benchmark labels.
