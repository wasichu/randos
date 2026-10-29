"""Bounded, model-free WORLD listening screen on the four public lab clips."""

import hashlib
import importlib.metadata
import json
import os
import platform
import resource
import subprocess
import sys
import tempfile
import time
from datetime import UTC, datetime
from pathlib import Path

import numpy as np
import soundfile as sf

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT / "tools/voice-browser"))
from sound_quality import match_levels

sys.path.insert(0, str(ROOT / "tools/voice-eval"))
from randos_voice_eval.reconstruction import save_audio

SETTINGS = {
    "high_voice": (-2, 0.9),
    "low_voice": (2, 1.1),
    "mid_voice": (-2, 0.9),
    "mencken_wasichu": (2, 1.1),
    "test_tone": (-2, 0.9),
}
NAMES = ["world_control", "world_pitch", "world_formants", "world_texture"]


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def warp_envelope(envelope, scale):
    """Move resonant peaks by scale, independently of pitch; keep power positive."""
    bins = np.arange(envelope.shape[1], dtype=np.float64)
    log_power = np.log(np.maximum(envelope, 1e-12))
    return np.ascontiguousarray(
        np.exp([np.interp(bins / scale, bins, frame) for frame in log_power])
    )


def worker(clip):
    import pyworld as pw
    from scipy.signal import resample_poly

    source = (
        ROOT / "tmp/voice-tone/input.wav"
        if clip == "test_tone"
        else ROOT / f"dev/voice_lab/clips/{clip}.wav"
    )
    raw, rate = sf.read(source, dtype="float64")
    if rate not in (24000, 48000) or raw.ndim != 1:
        raise ValueError("This screen expects mono 24/48 kHz audio")
    # A common resampler and padded tail for every variant, including the control.
    upsampled = resample_poly(raw, 2, 1) if rate == 24000 else raw
    original = np.ascontiguousarray(np.pad(upsampled * 0.25, (0, 4800)))
    start = time.perf_counter()
    f0, positions = pw.harvest(
        original, 48000, f0_floor=50, f0_ceil=800, frame_period=5
    )
    spectrum = pw.cheaptrick(original, f0, positions, 48000, f0_floor=50)
    fft_size = 2 * (spectrum.shape[1] - 1)
    aperiodicity = pw.d4c(original, f0, positions, 48000, fft_size=fft_size)
    analysis_seconds = time.perf_counter() - start
    semitones, formants = SETTINGS[clip]
    waves = {"original": original}
    timings = {}
    for name in NAMES:
        start = time.perf_counter()
        pitch = f0.copy() if name == "world_control" else f0 * 2 ** (semitones / 12)
        envelope = (
            warp_envelope(spectrum, formants)
            if name in {"world_formants", "world_texture"}
            else spectrum
        )
        noise = (
            np.ascontiguousarray(
                np.clip(aperiodicity + 0.12 * (1 - aperiodicity), 0.001, 1)
            )
            if name == "world_texture"
            else aperiodicity
        )
        synthesized = pw.synthesize(pitch, envelope, noise, 48000, frame_period=5)
        synthesis_seconds = time.perf_counter() - start
        if len(synthesized) < len(original):
            raise ValueError("WORLD output unexpectedly shorter than padded input")
        waves[name] = synthesized[: len(original)]
        timings[name] = {
            "synthesis_and_transform_seconds": synthesis_seconds,
            "analysis_plus_synthesis_rtf": (analysis_seconds + synthesis_seconds)
            / (len(raw) / rate),
            "generated_samples": len(synthesized),
        }
    matched, gains = match_levels(waves)
    output = ROOT / "tmp/voice-model"
    output.mkdir(parents=True, exist_ok=True)
    audio = {
        name: save_audio(clip, name, wave, output) for name, wave in matched.items()
    }
    levels = {
        name: {
            "rms": float(np.sqrt(np.mean(wave.astype(np.float64) ** 2))),
            "peak": float(np.max(np.abs(wave))),
            "gain": gains[name],
        }
        for name, wave in matched.items()
    }
    extension = next(Path(pw.__file__).parent.glob("pyworld*.so"))
    rss = resource.getrusage(resource.RUSAGE_SELF).ru_maxrss
    return {
        "source_sha256": digest(source),
        "audio": audio,
        "levels": levels,
        "analysis_seconds": analysis_seconds,
        "timings": timings,
        "harvest_voiced_frames_before_d4c": int(np.count_nonzero(f0)),
        "frames": len(f0),
        "analysis_f0_floor_hz": 50,
        "fft_size": fft_size,
        "peak_python_worker_rss_bytes": rss if sys.platform == "darwin" else rss * 1024,
        "extension_bytes": extension.stat().st_size,
        "extension_sha256": digest(extension),
    }


def main():
    stamp = datetime.now(UTC).isoformat()
    cases = {}
    for clip in (name for name in SETTINGS if name != "test_tone"):
        result = subprocess.run(
            [sys.executable, str(Path(__file__)), "--worker", clip],
            input=b"",
            capture_output=True,
            check=False,
        )
        if result.returncode:
            raise RuntimeError(
                f"WORLD failed for {clip}:\n{result.stderr.decode(errors='replace')}"
            )
        cases[clip] = json.loads(result.stdout)
        print(f"WORLD prepared: {clip}", flush=True)
    provenance = {
        "script_sha256": digest(Path(__file__)),
        "level_matching_sha256": digest(ROOT / "tools/voice-browser/sound_quality.py"),
        "requirements_sha256": digest(HERE / "requirements.lock"),
        "versions": {
            name: importlib.metadata.version(name)
            for name in ["pyworld", "numpy", "scipy", "soundfile"]
        },
        "platform": platform.platform(),
        "python": platform.python_version(),
        "settings": SETTINGS,
        "world_extension_sha256": next(iter(cases.values()))["extension_sha256"],
    }
    build = hashlib.sha256(json.dumps(provenance, sort_keys=True).encode()).hexdigest()
    candidates = {name: {} for name in NAMES}
    for clip, result in cases.items():
        semitones, scale = SETTINGS[clip]
        for name in NAMES:
            descriptions = {
                "world_control": "Rebuilt by WORLD, with no intentional voice change.",
                "world_pitch": f"WORLD pitch {semitones:+d}; original resonances retained.",
                "world_formants": f"WORLD pitch {semitones:+d}, resonances ×{scale:.1f}.",
                "world_texture": f"WORLD pitch {semitones:+d}, resonances ×{scale:.1f}, breathier texture.",
            }
            candidates[name][clip + ".wav"] = {
                "audio": {
                    "original": result["audio"]["original"],
                    "converted": result["audio"][name],
                },
                "description": descriptions[name],
                "note": "No trained weights. Start with the unchanged control to hear WORLD's own sound, then compare pitch, resonances and added breathiness (may add hiss). Levels matched by RMS. These are offline auditions; browser streaming is untested.",
                "level_matched": True,
                "context": {
                    "view": "model",
                    "mode": "model_free_dsp",
                    "processor": name,
                    "build_id": build,
                    "source_id": result["source_sha256"],
                    "sample": clip,
                    "run_id": stamp,
                    "case_id": clip,
                },
            }
    report = {
        "candidates": candidates,
        "experiment": {
            "generated_at": stamp,
            "provenance": provenance,
            "trained_weight_bytes": 0,
            "scope": "Whole-clip native Python/C++ screen. Timings exclude imports and resampling; RSS includes Python, arrays and native libraries. Neither is browser streaming performance. WARPs and texture amounts are fixed listening experiments, not anonymity guarantees.",
            "cases": cases,
        },
    }
    destination = HERE / "results/listening.json"
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(
        mode="w", dir=destination.parent, delete=False
    ) as pending:
        temporary = pending.name
        json.dump(report, pending, indent=2)
        pending.write("\n")
    try:
        os.replace(temporary, destination)
    finally:
        Path(temporary).unlink(missing_ok=True)


if __name__ == "__main__":
    if len(sys.argv) == 3 and sys.argv[1] == "--worker":
        print(json.dumps(worker(sys.argv[2])))
    else:
        main()
