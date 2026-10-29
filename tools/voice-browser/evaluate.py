"""Recognition and intelligibility probe, NOT an original-voice reconstruction attack.
Run in the existing voice-eval models environment after render_corpus.py.
"""

import hashlib
import json
import sys
from datetime import UTC, datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools/voice-eval"))


def main():
    import numpy as np
    import soundfile as sf
    from randos_voice_eval import attacks, data, metrics
    from randos_voice_eval.bench import Models

    chosen = data.select(data.ensure_downloaded())
    speakers = sorted(chosen, key=int)
    enroll = {s: chosen[s][:2] for s in speakers}
    trials = [u for s in speakers for u in chosen[s][2:]]
    folder = ROOT / "tmp/voice-browser/corpus"
    manifest = json.loads((folder / "manifest.json").read_text())
    expected = {u.id: u for values in chosen.values() for u in values}
    rows = {row["id"]: row for row in manifest["rows"]}
    if set(rows) != set(expected) or len(rows) != len(manifest["rows"]):
        raise RuntimeError("Corpus manifest IDs disagree with the selected dataset")
    for key, u in expected.items():
        if (
            hashlib.sha256(u.path.read_bytes()).hexdigest()
            != rows[key]["source_sha256"]
            or hashlib.sha256((folder / (key + ".npy")).read_bytes()).hexdigest()
            != rows[key]["output_sha256"]
        ):
            raise RuntimeError(f"Corpus source/output hash mismatch: {key}")
    models = Models()

    def raw(u):
        return sf.read(u.path, dtype="float32")[0]

    def changed(u):
        return np.load(folder / (u.id + ".npy"), allow_pickle=False)

    originals = {s: [models.embed(raw(u)) for u in enroll[s]] for s in speakers}
    matched = {s: [models.embed(changed(u)) for u in enroll[s]] for s in speakers}
    baseline = np.stack([models.embed(raw(u)) for u in trials])
    converted = np.stack([models.embed(changed(u)) for u in trials])
    labels = [u.speaker for u in trials]
    results = {}
    for key, refs, vectors in [
        ("original", originals, baseline),
        ("converted_original_references", originals, converted),
        ("converted_matching_transform", matched, converted),
    ]:
        eer, identification = attacks.verification(refs, vectors, labels, speakers)
        results[key] = {"eer": eer, "identification": identification}
        print(key, results[key], flush=True)
    texts = [u.text for u in trials]
    for key, get in [("original", raw), ("converted", changed)]:
        results[key + "_wer"] = metrics.wer(
            texts, models.transcribe([get(u) for u in trials])
        )
    report = {
        "generated_at": datetime.now(UTC).isoformat(),
        "speakers": len(speakers),
        "enrollment_per_speaker": 2,
        "trial_count": len(trials),
        "results": results,
        "render_manifest": manifest,
        "scope": "Fixed pretrained ECAPA, no attacker retraining. Different utterances for enrollment/trials. Target recording is separate from evaluated utterances. Recognition is not waveform recovery. TVTSyn reconstruction resistance remains untested.",
    }
    (ROOT / "tools/voice-browser/results/recognition.json").write_text(
        json.dumps(report, indent=2) + "\n"
    )
    print(json.dumps(results), flush=True)


if __name__ == "__main__":
    main()
