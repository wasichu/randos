"""The benchmark run: for each processor setting, can ECAPA-TDNN still tell
who is speaking, and can Whisper still understand them?

Speakers are enrolled from 2 utterances each (their embeddings averaged);
the other utterances are trials against every enrolled speaker. Attackers,
as in the VoicePrivacy Challenge:

- ignorant: enrolled from the original voices, tested on processed ones;
- informed: knows each trial call's exact parameters and processes all
  speakers' enrollment voices with those parameters;
- undo: shifts the processed voice back, then compares with the original
  voices. For a fixed shift, by the same amount; for random shifts (the
  amount is unknown), it tries every whole shift from -7 to +7 and keeps
  each trial's best score against each speaker.

McAdams additionally faces a bank of separately enrolled parameter values.
These fixed embedding attacks are a small research filter, not a claim of
anonymity or the full VoicePrivacy retrained attacker protocol.

    uv run --group models python -m randos_voice_eval.bench
"""

import argparse
import json
import sys
import time
from datetime import UTC, datetime
from pathlib import Path

import numpy as np
import soundfile

from randos_voice_eval import attacks, data, metrics, render, verdict

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
        semitones = rng.choice(list(range(-7, -2)) + list(range(3, 8)))
        return "pitch_shift", {0: semitones, 1: WINDOW_MS}

    found.append(
        ("pitch_shift_random", f"Pitch shift, random ±{lo:g} to {hi:g} per simulated call", random_shift, UNDO_SEARCH)
    )
    for alpha in [1.0, 0.7, 0.9]:
        found.append((
            f"mcadams_{alpha:g}",
            "McAdams matched control (α=1)" if alpha == 1 else f"McAdams α={alpha:g}",
            lambda _rng, alpha=alpha: ("mcadams", {0: alpha}),
            {"variant": "mcadams", "grid": [{0: value} for value in MCADAMS_GRID]},
        ))
    return found


MCADAMS_GRID = [0.5, 0.6, 0.7, 0.8, 0.9, 1.0]


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


def combined_diagnostics(reports):
    names = ["frames", "failed_frames", "clipped_samples", "samples", "seconds"]
    totals = {name: sum(r.get(name, 0) for r in reports) for name in names}
    totals["worst_block_ms"] = max((r.get("worst_block_ms", 0) for r in reports), default=0)
    return totals


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--only", nargs="+", help="setting IDs to run (default: all)")
    parser.add_argument("--output", type=Path, default=RESULTS, help="report path")
    args = parser.parse_args()
    selected_settings = settings()
    if args.only:
        unknown = set(args.only) - {item[0] for item in selected_settings}
        if unknown:
            parser.error(f"unknown settings: {', '.join(sorted(unknown))}")
        selected_settings = [item for item in selected_settings if item[0] in args.only]
    started = time.perf_counter()
    stage = time.perf_counter()
    root = data.ensure_downloaded()
    chosen = data.select(root)
    speakers = sorted(chosen, key=int)
    enroll = {s: chosen[s][:ENROLL] for s in speakers}
    trials = [u for s in speakers for u in chosen[s][ENROLL:]]
    print(f"{len(speakers)} speakers, {len(trials)} trial utterances", file=sys.stderr)
    timings = {"data": time.perf_counter() - stage}
    stage = time.perf_counter()
    render.build()
    timings["build"] = time.perf_counter() - stage
    stage = time.perf_counter()
    models = Models()
    timings["model_load"] = time.perf_counter() - stage
    stage = time.perf_counter()
    audio = {u.id: soundfile.read(u.path, dtype="float32")[0] for s in speakers for u in chosen[s]}
    references = [u.text for u in trials]
    trial_speakers = [u.speaker for u in trials]
    original_enroll = {s: [models.embed(audio[u.id]) for u in enroll[s]] for s in speakers}
    original_trials = np.stack([models.embed(audio[u.id]) for u in trials])
    base_eer, base_acc = attacks.verification(original_enroll, original_trials, trial_speakers, speakers)
    base_wer = metrics.wer(references, models.transcribe([audio[u.id] for u in trials]))
    baseline = {"eer": base_eer, "identification": base_acc, "wer": base_wer}
    original_models = attacks.prototypes(original_enroll, speakers)
    timings["baseline"] = time.perf_counter() - stage
    print(f"original: EER {base_eer:.3f}, id {base_acc:.2f}, WER {base_wer:.3f}", file=sys.stderr)
    reference_cache = {}
    reference_diagnostics = {}
    used_references = set()

    def reference_models(config):
        variant, params = config
        cache_key = (variant, tuple(sorted(params.items())))
        used_references.add(cache_key)
        if cache_key not in reference_cache:
            rendered = {
                s: [render.process(audio[u.id], variant, params, with_diagnostics=True) for u in enroll[s]]
                for s in speakers
            }
            enrollment = {
                s: [models.embed(wave) for wave, _ in rendered[s]]
                for s in speakers
            }
            reference_cache[cache_key] = attacks.prototypes(enrollment, speakers)
            reference_diagnostics[cache_key] = combined_diagnostics([
                diagnostics for clips in rendered.values() for _, diagnostics in clips
            ])
        return reference_cache[cache_key]

    results = []
    for key, label, how, attack in selected_settings:
        stage = time.perf_counter()
        used_references.clear()
        attack_diagnostics = []
        # Each speaker's three trial utterances simulate one consistent call.
        configs = [attacks.configuration(key, how, f"trial:{u.speaker}") for u in trials]
        rendered = [
            render.process(audio[u.id], variant, params, with_diagnostics=True)
            for u, (variant, params) in zip(trials, configs)
        ]
        waves = [item[0] for item in rendered]
        vectors = np.stack([models.embed(wave) for wave in waves])
        ignorant = attacks.summarize(vectors @ original_models.T, trial_speakers, speakers)
        informed_matrix = np.stack([v @ reference_models(c).T for v, c in zip(vectors, configs)])
        informed = attacks.summarize(informed_matrix, trial_speakers, speakers)
        wer = metrics.wer(references, models.transcribe(waves))
        result = {
            "id": key, "label": label,
            "eer_ignorant": ignorant[0], "identification_ignorant": ignorant[1],
            "eer_informed": informed[0], "identification_informed": informed[1],
            "wer": wer,
            "processing": combined_diagnostics([item[1] for item in rendered]),
            "call_parameters": {s: attacks.configuration(key, how, f"trial:{s}")[1] for s in speakers},
        }
        if isinstance(attack, dict):
            banks = np.stack([reference_models((attack["variant"], p)) for p in attack["grid"]])
            reference_banks = [banks[:, i, :] for i in range(len(speakers))]
            adaptive = attacks.summarize(attacks.bank_scores(vectors, reference_banks), trial_speakers, speakers)
            result |= {
                "eer_adaptive": adaptive[0], "identification_adaptive": adaptive[1],
                "adaptive_attack": "parameter_bank", "attack_grid": attack["grid"],
            }
        elif attack is not None:
            guesses = attack if isinstance(attack, list) else [attack]
            undo_rendered = [
                [render.process(w, "pitch_shift", {0: guess, 1: WINDOW_MS}, with_diagnostics=True) for guess in guesses]
                for w in waves
            ]
            candidates = [[models.embed(wave) for wave, _ in clips] for clips in undo_rendered]
            attack_diagnostics.extend(d for clips in undo_rendered for _, d in clips)
            undo = attacks.verification(original_enroll, candidates, trial_speakers, speakers)
            result |= {"eer_undo": undo[0], "identification_undo": undo[1], "adaptive_attack": "shift_search"}
        else:
            result["adaptive_attack"] = "not_run"
        result["reference_processing"] = [
            {"variant": variant, "parameters": dict(params), "processing": reference_diagnostics[(variant, params)]}
            for variant, params in sorted(used_references)
        ]
        attack_diagnostics.extend(item["processing"] for item in result["reference_processing"])
        result["attack_processing"] = combined_diagnostics(attack_diagnostics)
        result["verdict"] = verdict.of(result, baseline)
        result["seconds"] = round(time.perf_counter() - stage, 3)
        results.append(result)
        adaptive_eer = result.get("eer_adaptive", result.get("eer_undo"))
        print(
            f"{key}: EER ignorant {ignorant[0]:.3f}, known-parameter {informed[0]:.3f}, "
            f"adaptive {adaptive_eer}, WER {wer:.3f} — {result['verdict']['kind']}",
            file=sys.stderr,
        )
    report = {
        "protocol_version": 2,
        "attack_protocol": "Known trial-call parameters; separate reference prototypes per parameter. Search scores maximize genuine and impostor comparisons identically.",
        "alignment": "McAdams trials and references: flush 1022 samples of zeros at 48 kHz, remove the known leading delay, retain original duration. Pitch shift: causal output, no exact fixed delay alignment for its time-varying read heads.",
        "generated_at": datetime.now(UTC).isoformat(timespec="seconds"),
        "seconds": round(time.perf_counter() - started),
        "timings": {name: round(value, 3) for name, value in timings.items()},
        "dataset": {
            "name": "LibriSpeech test-clean (CC-BY 4.0)", "speakers": len(speakers),
            "female": sum(chosen[s][0].sex == "F" for s in speakers),
            "male": sum(chosen[s][0].sex == "M" for s in speakers),
            "enrollment_per_speaker": ENROLL, "trials": len(trials),
        },
        "models": {"speaker": SPEAKER_MODEL, "asr": ASR_MODEL},
        "thresholds": {"hidden_eer": verdict.HIDDEN_EER, "wer_margin": verdict.WER_MARGIN},
        "baseline": baseline, "results": results,
    }
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(report, indent=2) + "\n")
    print(f"wrote {args.output} in {report['seconds']} s", file=sys.stderr)


if __name__ == "__main__":
    main()
