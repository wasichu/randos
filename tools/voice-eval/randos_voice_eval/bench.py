"""The benchmark run: for each processor setting, can ECAPA-TDNN still tell
who is speaking, and can Whisper still understand them?

Speakers are enrolled from 2 utterances each (their embeddings averaged);
the other utterances are trials against every enrolled speaker. Attackers,
as in the VoicePrivacy Challenge:

- ignorant: enrolled from the original voices, tested on processed ones;
- informed: knows the processor and its setting, so enrolls from voices
  processed the same way (VoicePrivacy's "lazy-informed");
- undo: shifts the processed voice back, then compares with the original
  voices. For a fixed shift, by the same amount; for random shifts (the
  amount is unknown), it tries every whole shift from -7 to +7 and keeps
  each trial's best score against each speaker.

A processor only anonymizes if the informed attacker is fooled too: the
ignorant one is fooled by almost any change.

    uv run --group models python -m randos_voice_eval.bench
"""

import json
import random
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

import numpy as np
import soundfile

from randos_voice_eval import data, metrics, render, verdict

RESULTS = Path(__file__).resolve().parents[1] / "results" / "benchmark.json"
ENROLL = 2
SPEAKER_MODEL = "speechbrain/spkrec-ecapa-voxceleb"
ASR_MODEL = "openai/whisper-base.en"
WINDOW_MS = 40.0

# (id, label, how to process one clip, how to undo it or None)
FIXED_SHIFTS = [-7, -4, -2, 2, 4, 7]
RANDOM_RANGE = (3.0, 7.0)


def settings():
    found = [("passthrough", "Passthrough", lambda rng: ("passthrough", {}), None)]
    for s in FIXED_SHIFTS:
        found.append(
            (
                f"pitch_shift_{'plus' if s > 0 else 'minus'}_{abs(s)}",
                f"Pitch shift {s:+d} semitones",
                lambda rng, s=s: ("pitch_shift", {0: s, 1: WINDOW_MS}),
                -s,
            )
        )
    lo, hi = RANDOM_RANGE

    def random_shift(rng):
        semitones = rng.choice([-1, 1]) * rng.uniform(lo, hi)
        return "pitch_shift", {0: round(semitones, 2), 1: WINDOW_MS}

    found.append(
        ("pitch_shift_random", f"Pitch shift, random ±{lo:g} to {hi:g} per clip", random_shift, UNDO_SEARCH)
    )
    return found


# The undo attacker's guesses when the shift is unknown.
UNDO_SEARCH = list(range(-7, 8))


class Models:
    def __init__(self):
        import torch
        from speechbrain.inference.speaker import EncoderClassifier
        from transformers import WhisperForConditionalGeneration, WhisperProcessor

        self.torch = torch
        device = "mps" if torch.backends.mps.is_available() else "cpu"
        self.device = device
        cache = data.CACHE / "models"
        # ECAPA on the CPU: small, and some of its ops lack MPS kernels.
        self.speaker = EncoderClassifier.from_hparams(
            source=SPEAKER_MODEL, savedir=str(cache / "ecapa"), run_opts={"device": "cpu"}
        )
        self.asr_processor = WhisperProcessor.from_pretrained(ASR_MODEL, cache_dir=str(cache))
        self.asr = WhisperForConditionalGeneration.from_pretrained(ASR_MODEL, cache_dir=str(cache)).to(device)
        self.asr.eval()

    def embed(self, wave):
        with self.torch.no_grad():
            tensor = self.torch.from_numpy(np.asarray(wave, dtype=np.float32)).unsqueeze(0)
            vector = self.speaker.encode_batch(tensor).squeeze().numpy()
        return vector / np.linalg.norm(vector)

    def transcribe(self, waves, batch=8):
        texts = []
        for start in range(0, len(waves), batch):
            chunk = [np.asarray(w, dtype=np.float32) for w in waves[start : start + batch]]
            inputs = self.asr_processor(chunk, sampling_rate=16_000, return_tensors="pt").input_features
            with self.torch.no_grad():
                ids = self.asr.generate(inputs.to(self.device), max_new_tokens=200)
            texts += self.asr_processor.batch_decode(ids, skip_special_tokens=True)
        return texts


def verification(enroll_vectors, trial_vectors, trial_speakers, speakers):
    """EER and identification accuracy of trials against enrolled models.
    A trial may be a list of candidate vectors (the undo attacker's
    guesses): its score against a speaker is the best candidate's."""
    models = np.stack([np.mean(enroll_vectors[s], axis=0) for s in speakers])
    models /= np.linalg.norm(models, axis=1, keepdims=True)
    matrix = np.stack([np.max(np.atleast_2d(t) @ models.T, axis=0) for t in trial_vectors])
    truth = [speakers.index(s) for s in trial_speakers]
    scores, labels = [], []
    for row, true in zip(matrix, truth):
        for column, score in enumerate(row):
            scores.append(score)
            labels.append(column == true)
    return metrics.eer(scores, labels), metrics.identification_accuracy(matrix, truth)


def main():
    started = time.time()
    root = data.ensure_downloaded()
    chosen = data.select(root)
    speakers = sorted(chosen, key=int)
    enroll = {s: chosen[s][:ENROLL] for s in speakers}
    trials = [u for s in speakers for u in chosen[s][ENROLL:]]
    print(f"{len(speakers)} speakers, {len(trials)} trial utterances", file=sys.stderr)

    render.build()
    models = Models()
    audio = {u.id: soundfile.read(u.path, dtype="float32")[0] for s in speakers for u in chosen[s]}
    references = [u.text for u in trials]

    original_enroll = {s: [models.embed(audio[u.id]) for u in enroll[s]] for s in speakers}
    original_trials = [models.embed(audio[u.id]) for u in trials]
    trial_speakers = [u.speaker for u in trials]
    base_eer, base_acc = verification(original_enroll, original_trials, trial_speakers, speakers)
    base_wer = metrics.wer(references, models.transcribe([audio[u.id] for u in trials]))
    baseline = {"eer": base_eer, "identification": base_acc, "wer": base_wer}
    print(f"original: EER {base_eer:.3f}, id {base_acc:.2f}, WER {base_wer:.3f}", file=sys.stderr)

    results = []
    for key, label, how, undo in settings():
        rng = random.Random(f"randos-voice-eval:{key}")

        def run(wave, how=how, rng=rng):
            variant, params = how(rng)
            return render.process(wave, variant, params)

        processed_trials = [run(audio[u.id]) for u in trials]
        trial_vectors = [models.embed(w) for w in processed_trials]
        informed_enroll = {s: [models.embed(run(audio[u.id])) for u in enroll[s]] for s in speakers}

        eer_ignorant, acc_ignorant = verification(original_enroll, trial_vectors, trial_speakers, speakers)
        eer_informed, acc_informed = verification(informed_enroll, trial_vectors, trial_speakers, speakers)
        wer = metrics.wer(references, models.transcribe(processed_trials))
        result = {
            "id": key,
            "label": label,
            "eer_ignorant": eer_ignorant,
            "eer_informed": eer_informed,
            "identification_ignorant": acc_ignorant,
            "identification_informed": acc_informed,
            "wer": wer,
        }
        if undo is not None:
            guesses = undo if isinstance(undo, list) else [undo]
            candidates = [
                [models.embed(render.process(w, "pitch_shift", {0: g, 1: WINDOW_MS})) for g in guesses]
                for w in processed_trials
            ]
            eer_undo, acc_undo = verification(original_enroll, candidates, trial_speakers, speakers)
            result |= {"eer_undo": eer_undo, "identification_undo": acc_undo}
        result["verdict"] = verdict.of(result, baseline)
        results.append(result)
        print(
            f"{key}: EER ignorant {eer_ignorant:.3f}, informed {eer_informed:.3f}"
            + (f", undo {result['eer_undo']:.3f}" if "eer_undo" in result else "")
            + f", WER {wer:.3f} — {result['verdict']['kind']}",
            file=sys.stderr,
        )

    report = {
        "generated_at": datetime.now(timezone.utc).isoformat(timespec="seconds"),
        "seconds": round(time.time() - started),
        "dataset": {
            "name": "LibriSpeech test-clean (CC-BY 4.0)",
            "speakers": len(speakers),
            "female": sum(1 for s in speakers if chosen[s][0].sex == "F"),
            "male": sum(1 for s in speakers if chosen[s][0].sex == "M"),
            "enrollment_per_speaker": ENROLL,
            "trials": len(trials),
        },
        "models": {"speaker": SPEAKER_MODEL, "asr": ASR_MODEL},
        "thresholds": {"hidden_eer": verdict.HIDDEN_EER, "wer_margin": verdict.WER_MARGIN},
        "baseline": baseline,
        "results": results,
    }
    RESULTS.parent.mkdir(parents=True, exist_ok=True)
    RESULTS.write_text(json.dumps(report, indent=2) + "\n")
    print(f"wrote {RESULTS} in {report['seconds']} s", file=sys.stderr)


if __name__ == "__main__":
    main()
