# The voice-anonymization benchmark (Phase 5)

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
- **Attackers** (as in the VoicePrivacy Challenge):
  - *ignorant*: enrolled from the original voices, tested on processed ones;
  - *informed* (VoicePrivacy's "lazy-informed"): knows the processor and its
    setting, so it processes its enrollment voices the same way;
  - *shifted back* (pitch shifts): undoes the shift, then compares with
    the original voices. For a fixed shift, by the opposite amount; for
    random shifts, whose amount it doesn't know, it tries every whole shift
    from −7 to +7 and keeps each trial's best match.
- **Verdict** (`verdict.py`, provisional thresholds, not a standard): the
  speaker counts as hidden at an EER of 30% or more, and speech as
  intelligible while WER is within 10 points of the original's. A
  processor "hides" the speaker only if every attacker is fooled: the
  ignorant one is fooled by almost any change.

Numbers from 20 speakers are rough (an EER moves in steps of a few
percent); they're for comparing processors, not for publishing.
