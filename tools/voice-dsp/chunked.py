"""Offline causal-window screen: reset WORLD synthesis with bounded overlap."""

import hashlib
import json
import os
import platform
import subprocess
import sys
import tempfile
import time
from datetime import UTC, datetime
from pathlib import Path

import numpy as np
import soundfile as sf
from probe import SETTINGS, warp_envelope

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT / "tools/voice-browser"))
from sound_quality import match_levels

sys.path.insert(0, str(ROOT / "tools/voice-eval"))
from randos_voice_eval.reconstruction import save_audio

RATE = 48000
PAST = 3840  # 80 ms of already received input
OVERLAP = 960  # 20 ms of retained output, blended when the next block is ready
FUTURE = 1920  # 40 ms after the target output (including its retained overlap)
HOPS = [40, 80, 160]


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def chunk_render(samples, hop, transform):
    """Return complete joined audio and native sequential-release diagnostics.

    `transform` sees only a bounded input window. Finalize the current hop
    using the preceding retained overlap; keep the new trailing overlap for
    the next hop. No samples beyond the declared release time are available.
    """
    out = np.zeros(len(samples), dtype=np.float64)
    coverage = np.zeros(len(samples), dtype=np.float64)
    rows = []
    finished = 0.0
    for start in range(0, len(samples), hop):
        began = time.perf_counter()
        requested_end = start + hop + OVERLAP + FUTURE
        low, high = max(0, start - PAST), min(len(samples), requested_end)
        window = np.pad(
            samples[low:high],
            (max(0, PAST - start), max(0, requested_end - len(samples))),
        )
        wave = transform(np.ascontiguousarray(window, dtype=np.float64))
        length = min(hop + OVERLAP, len(samples) - start)
        segment = wave[PAST : PAST + length]
        if len(segment) != length or not np.isfinite(segment).all():
            raise ValueError("Incomplete or nonfinite chunk output")
        weight = np.ones(length, dtype=np.float64)
        if start:
            count = min(OVERLAP, length)
            weight[:count] = np.arange(count) / OVERLAP
        if length > hop:
            weight[hop:] = 1 - np.arange(length - hop) / OVERLAP
        out[start : start + length] += segment * weight
        coverage[start : start + length] += weight
        compute = time.perf_counter() - began
        release = high / RATE  # end padding becomes known only on EOS
        waiting = max(0.0, finished - release)
        finished = max(release, finished) + compute
        rows.append(
            {
                "output_start": start,
                "emitted_samples": min(hop, len(samples) - start),
                "required_input_end": high,
                "eos_padding": requested_end > len(samples),
                "compute_ms": compute * 1000,
                "release_ms": release * 1000,
                "queue_wait_ms": waiting * 1000,
                "finish_ms": finished * 1000,
                "playout_delay_ms": (finished - start / RATE) * 1000,
            }
        )
    if not np.allclose(coverage, 1, rtol=0, atol=1e-12):
        raise ValueError("Overlap weights left a gap or changed signal gain")
    times = [row["compute_ms"] for row in rows]
    steady = [row for row in rows if not row["eos_padding"]]
    metrics = {
        "hop_ms": hop * 1000 / RATE,
        "input_buffering_ms": (hop + OVERLAP + FUTURE) * 1000 / RATE,
        "blocks": len(rows),
        "compute_ms_mean": float(np.mean(times)),
        "compute_ms_p95": float(np.percentile(times, 95)),
        "compute_ms_max": max(times),
        "blocks_slower_than_hop": sum(value > hop * 1000 / RATE for value in times),
        "rtf": sum(times) / 1000 / (len(samples) / RATE),
        "max_queue_wait_ms": max(row["queue_wait_ms"] for row in rows),
        "steady_max_queue_wait_ms": max(
            (row["queue_wait_ms"] for row in steady), default=0
        ),
        "end_flush_ms": max(0, rows[-1]["finish_ms"] - len(samples) * 1000 / RATE),
        "required_playout_delay_ms": max(row["playout_delay_ms"] for row in rows),
        "steady_required_playout_delay_ms": max(
            (row["playout_delay_ms"] for row in steady), default=None
        ),
        "rows": rows,
    }
    return out, metrics


def world_transform(semitones, scale):
    import pyworld as pw

    def transform(window):
        f0, positions = pw.harvest(
            window, RATE, f0_floor=50, f0_ceil=800, frame_period=5
        )
        spectrum = pw.cheaptrick(window, f0, positions, RATE, f0_floor=50)
        noise = pw.d4c(
            window, f0, positions, RATE, fft_size=2 * (spectrum.shape[1] - 1)
        )
        return pw.synthesize(
            f0 * 2 ** (semitones / 12),
            warp_envelope(spectrum, scale),
            noise,
            RATE,
            frame_period=5,
        )

    return transform


def main():
    import pyworld as pw
    from scipy.signal import resample_poly

    whole = json.loads((HERE / "results/listening.json").read_text())["candidates"][
        "world_formants"
    ]
    tones = json.loads((ROOT / "tools/voice-browser/results/tone.json").read_text())[
        "candidates"
    ]["world_formants"]
    references = {**whole, **tones}
    output = ROOT / "tmp/voice-model"
    stamp = datetime.now(UTC).isoformat()
    provenance = {
        "script_sha256": digest(Path(__file__)),
        "world_wrapper_sha256": digest(HERE / "probe.py"),
        "requirements_sha256": digest(HERE / "requirements.lock"),
        "platform": platform.platform(),
        "world_extension_sha256": digest(
            next(Path(pw.__file__).parent.glob("pyworld*.so"))
        ),
        "numpy_version": np.__version__,
        "references": {},
    }
    cases = {}
    for clip, (pitch, scale) in SETTINGS.items():
        tone = clip == "test_tone"
        key = clip if tone else clip + ".wav"
        item = references[key]
        source_id = (
            digest(ROOT / "assets/js/voice_lab/test_tone.js")
            if tone
            else digest(ROOT / f"dev/voice_lab/clips/{key}")
        )
        if item["context"]["source_id"] != source_id:
            raise ValueError("Whole-recording reference does not match current source")
        path = output / item["audio"]["converted"]
        if digest(path) != path.stem.split("__")[-1]:
            raise ValueError("Whole-recording reference WAV hash mismatch")
        reference, rate = sf.read(path, dtype="float64")
        if rate != RATE:
            raise ValueError("Expected 48 kHz reference")
        if tone:
            generated = subprocess.run(
                [
                    "node",
                    "--input-type=module",
                    "-e",
                    "import {testToneSamples} from './assets/js/voice_lab/test_tone.js';process.stdout.write(Buffer.from(testToneSamples().buffer))",
                ],
                cwd=ROOT,
                capture_output=True,
                check=True,
            )
            raw = np.frombuffer(generated.stdout, dtype="<f4").astype(np.float64)
        else:
            raw, sr = sf.read(ROOT / f"dev/voice_lab/clips/{key}", dtype="float64")
            if sr != 24000:
                raise ValueError("Expected bundled 24 kHz voice")
            raw = resample_poly(raw, 2, 1)
        samples = np.ascontiguousarray(np.pad(raw * 0.25, (0, 4800)))
        if len(samples) != len(reference):
            raise ValueError("Reference and chunk input duration differ")
        provenance["references"][clip] = {
            "source_id": source_id,
            "wav_sha256": digest(path),
            "context": item["context"],
            "pitch": pitch,
            "spectral_scale": scale,
        }
        waves, timings = {"original": reference}, {}
        transform = world_transform(pitch, scale)
        for milliseconds in HOPS:
            name = f"world_chunk_{milliseconds}"
            waves[name], timings[name] = chunk_render(
                samples, milliseconds * RATE // 1000, transform
            )
            print(
                f"{clip} {milliseconds} ms: RTF {timings[name]['rtf']:.2f}, required playout {timings[name]['required_playout_delay_ms']:.0f} ms",
                flush=True,
            )
        waves, gains = match_levels(waves)
        files = {
            name: save_audio(clip, "chunk_" + name, wave, output)
            for name, wave in waves.items()
        }
        cases[clip] = {
            "key": key,
            "audio": files,
            "gains": gains,
            "timings": timings,
            "levels": {
                name: {
                    "rms": float(np.sqrt(np.mean(wave.astype(np.float64) ** 2))),
                    "peak": float(np.max(np.abs(wave))),
                }
                for name, wave in waves.items()
            },
        }
    build = hashlib.sha256(json.dumps(provenance, sort_keys=True).encode()).hexdigest()
    candidates = {f"world_chunk_{hop}": {} for hop in HOPS}
    for clip, case in cases.items():
        for hop in HOPS:
            name = f"world_chunk_{hop}"
            timing = case["timings"][name]
            candidates[name][case["key"]] = {
                "audio": {
                    "original": case["audio"]["original"],
                    "converted": case["audio"][name],
                },
                "reference_kind": "whole_world",
                "level_matched": True,
                "description": f"WORLD on {hop} ms output chunks, with overlap.",
                "note": f"Compare chunked quality with the whole-recording WORLD reference. Same pitch/resonance settings; 20 ms overlap, 80 ms past and 40 ms future context. At least {timing['input_buffering_ms']:.0f} ms of input buffering before computation. Synthesis resets for each window, which may cause periodic roughness. Offline simulation; browser and call delay unmeasured.",
                "context": {
                    "view": "model",
                    "mode": "chunked_world",
                    "processor": name,
                    "build_id": build,
                    "source_id": provenance["references"][clip]["source_id"],
                    "sample": clip,
                    "case_id": clip,
                    "run_id": stamp,
                },
            }
    report = {
        "candidates": candidates,
        "experiment": {
            "generated_at": stamp,
            "provenance": provenance,
            "past_ms": 80,
            "overlap_ms": 20,
            "future_ms": 40,
            "scope": "Reset-synthesis causal-window wrapper, not stateful streaming WORLD. Release clock starts at preprocessed 48 kHz input. Native timings exclude resampling, RMS matching and artifact I/O. Listening levels use whole-clip normalization, not a proposed live gain algorithm.",
            "cases": cases,
        },
    }
    destination = HERE / "results/chunked.json"
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
    main()
