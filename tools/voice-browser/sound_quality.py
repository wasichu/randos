"""Four public voices, isolated DSP changes and a saved TVTSyn reference.

No neural inference or downloads. Match whole-clip RMS, preserving a 100 ms
tail and applying common headroom to the entire comparison for each voice.
RMS matching controls average signal level, not exact perceived loudness.
"""

import hashlib
import json
import os
import sys
import tempfile
from datetime import UTC, datetime
from pathlib import Path

import numpy as np
import soundfile as sf

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT / "tools/voice-eval"))
from randos_voice_eval import render
from randos_voice_eval.reconstruction import save_audio

NAMES = ["quality_pitch", "quality_resonance", "quality_both", "quality_tvtsyn"]


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def match_levels(waves):
    """Use one RMS target and one common peak attenuation; never limit/clip."""
    levels = {
        key: float(np.sqrt(np.mean(x.astype(np.float64) ** 2)))
        for key, x in waves.items()
    }
    if (
        any(not np.isfinite(x).all() for x in waves.values())
        or min(levels.values()) <= 0
    ):
        raise ValueError("Comparison requires finite, non-silent audio")
    gains = {key: levels["original"] / level for key, level in levels.items()}
    peak = max(float(np.max(np.abs(x))) * gains[key] for key, x in waves.items())
    common = min(1.0, 0.9 / peak)
    matched = {
        key: (x * gains[key] * common).astype(np.float32) for key, x in waves.items()
    }
    return matched, {key: gains[key] * common for key in waves}


def main():
    import torch
    from torchaudio.functional import resample

    render.build()
    previous = json.loads((HERE / "results/comparisons.json").read_text())
    output = ROOT / "tmp/voice-model"
    stamp = datetime.now(UTC).isoformat()
    identity = {
        "script": digest(Path(__file__)),
        "renderer": digest(render.BINARY),
        "references": {},
    }
    cases = {}
    for clip, semitones in [
        ("high_voice", -2),
        ("low_voice", 2),
        ("mid_voice", -2),
        ("mencken_wasichu", 2),
    ]:
        path = ROOT / f"dev/voice_lab/clips/{clip}.wav"
        reference = previous["candidates"]["tvtsyn_native"][clip + ".wav"]
        if reference["context"]["source_id"] != digest(path):
            raise ValueError("Saved TVTSyn source does not match current clip")
        model_path = output / reference["audio"]["converted"]
        if digest(model_path) != model_path.stem.split("__")[-1]:
            raise ValueError("Saved TVTSyn WAV does not match its content hash")
        identity["references"][clip] = {
            "source": digest(path),
            "tvtsyn": digest(model_path),
            "context": reference["context"],
        }
        raw, rate = sf.read(path, dtype="float32")
        original = resample(torch.from_numpy(raw), rate, 48000).numpy() * 0.25
        resonance, first = render.process_48k(original, params={0: 0.9})
        pitch, second = render.process_48k(
            np.pad(original, (0, 4800)), "pitch_shift", {0: semitones, 1: 40}
        )
        both, third = render.process_48k(
            np.pad(resonance, (0, 4800)), "pitch_shift", {0: semitones, 1: 40}
        )
        neural, rate = sf.read(model_path, dtype="float32")
        if rate != 48000 or len(neural) != len(original):
            raise ValueError(
                "Saved TVTSyn reference must preserve the source duration at 48 kHz"
            )
        waves, gains = match_levels(
            {
                "original": np.pad(original, (0, 4800)),
                "quality_pitch": pitch,
                "quality_resonance": np.pad(resonance, (0, 4800)),
                "quality_both": both,
                "quality_tvtsyn": np.pad(neural, (0, 4800)),
            }
        )
        cases[clip] = {
            "waves": waves,
            "gains": gains,
            "semitones": semitones,
            "diagnostics": {
                "resonance": first,
                "pitch": second,
                "combined_pitch": third,
            },
        }

    build = hashlib.sha256(json.dumps(identity, sort_keys=True).encode()).hexdigest()
    report = {"generated_at": stamp, "provenance": identity, "cases": {}}
    candidates = {name: {} for name in NAMES}
    for clip, case in cases.items():
        waves = case.pop("waves")
        report["cases"][clip] = {**case, "levels": {}}
        original = save_audio(clip, "quality_original", waves["original"], output)
        for name, wave in waves.items():
            report["cases"][clip]["levels"][name] = {
                "rms": float(np.sqrt(np.mean(wave.astype(np.float64) ** 2))),
                "peak": float(np.max(np.abs(wave))),
                "gain": case["gains"][name],
            }
            if name == "original":
                continue
            direction = f"{case['semitones']:+d} semitones"
            settings = {
                "quality_pitch": f"Pitch only: {direction}, 40 ms slices.",
                "quality_resonance": "Resonance only: McAdams coefficient 0.9.",
                "quality_both": f"McAdams 0.9, then pitch {direction}, 40 ms slices.",
                "quality_tvtsyn": "TVTSyn target-voice control: this recording also supplies the target voice."
                if clip == "mid_voice"
                else "TVTSyn with a fixed mid-voice target. Prepared output.",
            }[name]
            candidates[name][clip + ".wav"] = {
                "audio": {
                    "original": original,
                    "converted": save_audio(clip, name, wave, output),
                },
                "context": {
                    "view": "model",
                    "mode": "rms_matched",
                    "processor": name,
                    "build_id": build,
                    "source_id": identity["references"][clip]["source"],
                    "sample": clip,
                    "run_id": stamp,
                    "case_id": clip,
                },
                "level_matched": True,
                "description": settings,
                "note": "Compare the four sound checks for roughness, clarity and how different the voice sounds. Average levels are matched (RMS, not exact perceived loudness). McAdams also filters out some high-frequency sound."
                + (
                    " Mid voice is also TVTSyn's target: its model output is a control, not a disguise test."
                    if clip == "mid_voice" and name == "quality_tvtsyn"
                    else ""
                ),
            }
        print(
            f"Matched {clip}: pitch {case['semitones']:+d}, resonance 0.9, both, TVTSyn",
            flush=True,
        )
    # Publish only once every WAV and all four voices are complete.
    destination = HERE / "results/sound-quality.json"
    with tempfile.NamedTemporaryFile(
        mode="w", dir=destination.parent, delete=False
    ) as pending:
        temporary = pending.name
        json.dump({"candidates": candidates, "experiment": report}, pending, indent=2)
        pending.write("\n")
    try:
        os.replace(temporary, destination)
    finally:
        Path(temporary).unlink(missing_ok=True)


if __name__ == "__main__":
    main()
