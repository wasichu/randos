"""Render the existing benchmark corpus through TVTSyn, without call audio."""

import hashlib
import json
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "tools/voice-eval"))


def main():
    import numpy as np
    import soundfile as sf
    from randos_voice_eval import data
    from tvtsyn_inference import TVTSyn

    prep = json.loads((ROOT / "tmp/voice-browser/preparation.json").read_text())
    model = TVTSyn.from_pretrained(prep["root"], backend="onnx", threads=4)
    speaker = np.fromfile(ROOT / "tmp/voice-browser/speaker.f32", dtype="<f4").reshape(
        1, 704
    )
    selected = data.select(data.ensure_downloaded())
    directory = ROOT / "tmp/voice-browser/corpus"
    directory.mkdir(exist_ok=True)
    rows = []
    for utterances in selected.values():
        for utterance in utterances:
            source, rate = sf.read(utterance.path, dtype="float32")
            wave = model.convert(source, speaker, sample_rate=rate)
            if len(wave) != len(source) or not np.isfinite(wave).all():
                raise RuntimeError(f"Invalid waveform: {utterance.id}")
            name = utterance.id + ".npy"
            np.save(directory / name, wave, allow_pickle=False)
            rows.append(
                {
                    "id": utterance.id,
                    "speaker": utterance.speaker,
                    "source_sha256": hashlib.sha256(
                        utterance.path.read_bytes()
                    ).hexdigest(),
                    "output_sha256": hashlib.sha256(
                        (directory / name).read_bytes()
                    ).hexdigest(),
                    "peak": float(np.max(np.abs(wave))),
                    "samples": len(wave),
                    "at_unit_boundary": int(np.count_nonzero(np.abs(wave) >= 1)),
                }
            )
        print(f"Rendered speaker {utterances[0].speaker}", flush=True)
    (directory / "manifest.json").write_text(
        json.dumps(
            {
                "graph": prep["artifacts_sha256"],
                "speaker_embedding": prep["speaker_sha256"],
                "rows": rows,
            },
            indent=2,
        )
        + "\n"
    )


if __name__ == "__main__":
    main()
