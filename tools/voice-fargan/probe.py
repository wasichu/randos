"""First FARGAN gate: unchanged synthesis vs matched-band source and shipped DSP."""

import ctypes
import hashlib
import json
import subprocess
import sys
import time
from datetime import UTC, datetime
from pathlib import Path

import numpy as np
import soundfile as sf
from bootstrap import HERE, OUT, ROOT, digest
from scipy.signal import resample_poly

sys.path.insert(0, str(ROOT / "tools/voice-dsp/browser"))
from publish import atomic_json

sys.path.insert(0, str(ROOT / "tools/voice-browser"))
from sound_quality import match_levels

sys.path.insert(0, str(ROOT / "tools/voice-eval"))
from randos_voice_eval.reconstruction import save_audio


def run(mode, source, destination):
    started = time.monotonic()
    with subprocess.Popen(
        [OUT / "probe", mode, source, destination],
        stdin=subprocess.PIPE,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
    ) as child:
        try:
            status = child.wait(timeout=60)
        finally:
            child.stdin.close()
            try:
                child.wait(timeout=5)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait()
        details = child.stderr.read().decode()
        if status:
            raise RuntimeError(f"FARGAN {mode} failed ({status}): {details}")
    metrics = json.loads(details)
    metrics["subprocess_wall_ms"] = (time.monotonic() - started) * 1000
    return metrics


def reference(x, pitch, scale):
    lib = ctypes.CDLL(str(OUT / "spectral.dylib"))
    lib.dsp_new.argtypes = [ctypes.c_double, ctypes.c_double]
    for name in ["dsp_input", "dsp_output"]:
        getattr(lib, name).restype = ctypes.POINTER(ctypes.c_double)
    if lib.dsp_new(pitch, scale) != 1:
        raise ValueError("Reference initialization failed")
    try:

        def process(x, flush=False):
            if not flush:
                np.ctypeslib.as_array(lib.dsp_input(), shape=(len(x),))[:] = x
            n = (lib.dsp_flush if flush else lib.dsp_process)(len(x))
            if n != len(x):
                raise ValueError("Incomplete reference output")
            return np.ctypeslib.as_array(lib.dsp_output(), shape=(n,)).copy()

        il, ol = lib.dsp_input_latency(), lib.dsp_output_latency()
        return np.concatenate(
            [process(x[i : i + 3840]) for i in range(0, len(x), 3840)]
            + [process(np.zeros(il)), process(np.zeros(ol), True)]
        )[il + ol : il + ol + len(x)]
    finally:
        lib.dsp_close()


def main():
    (HERE / "results").mkdir(exist_ok=True)
    build = json.loads((OUT / "build.json").read_text())
    for path, expected in build["files"].items():
        if digest(ROOT / path) != expected:
            raise ValueError("FARGAN build changed; rebuild before inference: " + path)
    wrapper = ROOT / "tools/voice-dsp/browser/spectral.cpp"
    subprocess.run(
        [
            "clang++",
            "-O3",
            "-std=c++17",
            "-ffp-contract=off",
            "-shared",
            "-fPIC",
            f"-I{ROOT / 'vendor/signalsmith/stretch'}",
            f"-I{ROOT / 'vendor/signalsmith'}",
            wrapper,
            "-o",
            OUT / "spectral.dylib",
        ],
        check=True,
    )
    subprocess.run(
        ["python3", ROOT / "tools/voice-dsp/browser/check_vendor.py"], check=True
    )
    stamp = datetime.now(UTC).isoformat()
    cases, candidates, checks = {}, {"fargan_control": {}}, []
    for clip in [
        "high_voice",
        "mid_voice",
        "low_voice",
        "mencken_wasichu",
        "test_tone",
    ]:
        source = ROOT / (
            "assets/js/voice_lab/test_tone.js"
            if clip == "test_tone"
            else f"dev/voice_lab/clips/{clip}.wav"
        )
        if clip == "test_tone":
            result = subprocess.run(
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
            raw = np.frombuffer(result.stdout, dtype="<f4")
        else:
            raw, rate = sf.read(source, dtype="float64")
            if rate != 24000 or raw.ndim != 1:
                raise ValueError("Expected mono 24 kHz source")
            raw = resample_poly(raw, 2, 1)
        x = np.pad(raw * 0.25, (0, 4800)).astype("<f4")
        down = resample_poly(x, 1, 3)
        if len(down) % 160 or np.max(np.abs(down)) >= 1:
            raise ValueError("Input must be complete unclipped 10 ms frames")
        pcm = np.rint(down * 32768).astype("<i2")
        padded = np.pad(pcm, (3200, 3200))
        paths = {kind: OUT / f"{clip}.{kind}" for kind in ["pcm", "features", "f32"]}
        padded.tofile(paths["pcm"])
        extract = run("features", paths["pcm"], paths["features"])
        features = np.fromfile(paths["features"], dtype="<f4")
        if len(features) != len(padded) // 160 * 20 or not np.isfinite(features).all():
            raise ValueError("Invalid extracted features")
        synthesis = run("synthesize", paths["features"], paths["f32"])
        output = np.fromfile(paths["f32"], dtype="<f4")
        if len(output) != len(padded) or not np.isfinite(output).all():
            raise ValueError("Incomplete/nonfinite synthesis output")
        features = features.reshape(-1, 20)
        periods = np.floor(0.5 + 256 / np.exp2(features[:, 18] + 1.5))
        native = output[3200 : 3200 + len(pcm)]
        pitch, scale = (
            (1, 1.25) if clip in ["low_voice", "mencken_wasichu"] else (-1, 0.8)
        )
        waves = {
            "original": x,
            "bandlimited": resample_poly(pcm.astype(float) / 32768, 3, 1),
            "fargan": resample_poly(native, 3, 1),
            "reference": reference(x, pitch, scale),
        }
        if any(len(y) != len(x) or not np.isfinite(y).all() for y in waves.values()):
            raise ValueError("Comparison wave lengths differ")
        timed_seconds = len(padded) / 16000
        checks.append(
            {
                "sample": clip,
                "input_pcm_sha256": digest(paths["pcm"]),
                "features_sha256": digest(paths["features"]),
                "output_float_sha256": digest(paths["f32"]),
                "timed_audio_seconds": timed_seconds,
                "extract": extract,
                "synthesis": synthesis,
                "native_total_rtf": (extract["total_ms"] + synthesis["total_ms"])
                / 1000
                / timed_seconds,
                "output_peak": float(np.max(np.abs(output))),
                "above_full_scale_samples": int(np.sum(np.abs(output) >= 1)),
                "first_100ms_output_rms": float(np.sqrt(np.mean(output[:1600] ** 2))),
                "period_below_32": int(np.sum(periods < 32)),
                "period_above_256": int(np.sum(periods > 256)),
            }
        )
        waves, gains = match_levels(waves)
        audio = {
            name: save_audio(clip, "fargan_" + name, y, ROOT / "tmp/voice-model")
            for name, y in waves.items()
        }
        note = "Unchanged synthesis control: no masking features have been edited. First compare FARGAN with Original · 16 kHz."
        if clip == "test_tone":
            note = "Tone diagnostic only. A speech-specific generator need not reproduce a synthetic tone faithfully."
        context = {
            "view": "round",
            "mode": "fargan_quality_1",
            "processor": "fargan",
            "build_id": None,
            "source_id": digest(source),
            "sample": clip,
            "case_id": clip,
            "run_id": stamp,
        }
        descriptions = {
            "original": "Original recording · full source bandwidth",
            "bandlimited": "Same original resampled to 16 kHz and quantized like the model input",
            "fargan": "Unchanged acoustic features → FARGAN · 16 kHz synthesis",
            "reference": f"Released Signalsmith reference · pitch {pitch:+g}, resonances ×{scale:.2f}",
        }
        key = clip if clip == "test_tone" else clip + ".wav"
        cases[key] = {
            "context": context,
            "audio": audio,
            "descriptions": descriptions,
            "gains": gains,
            "note": note,
        }
        candidates["fargan_control"][key] = {
            "audio": {"original": audio["bandlimited"], "converted": audio["fargan"]},
            "description": descriptions["fargan"],
            "note": note,
            "level_matched": True,
            "reference_title": "Original · 16 kHz",
            "reference_description": "The same original resampled to 16 kHz and quantized like the FARGAN input; average level matched.",
            "context": {
                **context,
                "view": "model",
                "mode": "fargan_resynthesis",
                "processor": "fargan_control",
            },
        }
        print(
            f"FARGAN {clip}: native RTF {checks[-1]['native_total_rtf']:.3f}, synthesis RSS {synthesis['peak_rss_bytes'] / 1048576:.1f} MiB",
            flush=True,
        )
    identity = {
        "build": build,
        "checks": checks,
        "sources": {
            str(p.relative_to(ROOT)): digest(p)
            for p in [Path(__file__), wrapper, OUT / "spectral.dylib"]
        },
        "cases": {
            key: {k: v for k, v in row.items() if k != "context"}
            for key, row in cases.items()
        },
    }
    build_id = hashlib.sha256(json.dumps(identity, sort_keys=True).encode()).hexdigest()
    for case in cases.values():
        case["context"]["build_id"] = build_id
    for case in candidates["fargan_control"].values():
        case["context"]["build_id"] = build_id
    atomic_json(
        HERE / "results/quality.json",
        {
            "identity": identity,
            "cases": cases,
            "candidates": candidates,
            "variants": [
                {"id": k, "label": label}
                for k, label in [
                    ("original", "Original"),
                    ("bandlimited", "Original · 16 kHz"),
                    ("fargan", "FARGAN · unchanged"),
                    ("reference", "Released Signalsmith"),
                ]
            ],
            "title": "Does compact neural resynthesis sound good enough?",
            "intro": "First compare the 16 kHz original with unchanged FARGAN. Judge clarity and naturalness before we try masking edits. The Signalsmith sample is our existing masking reference.",
            "review_prompt": "Quality of unchanged FARGAN",
            "preference_label": "Is the synthesis good enough to try masking edits?",
            "details": [
                "No masking features are edited. A changed sound in the FARGAN control is resynthesis behavior, not an established disguise or privacy guarantee.",
                "The C model uses 16 kHz audio and 10 ms features. All WAVs play at 48 kHz for comparison; upsampling restores no lost high-frequency detail. Levels are RMS-matched together with common peak headroom, without limiting.",
                "Input has 200 ms of leading and trailing silence. The driver retains upstream initial-feature repetition, 80-sample initial output skip and two ending synthesis frames, then trims only that fixed padding. It never aligns each output by correlation. This is an offline comparison, not measured live latency.",
                f"This research executable is {build['executable_bytes'] / 1048576:.2f} MiB and the FARGAN model object is {build['fargan_model_object_bytes'] / 1048576:.2f} MiB. These native artifacts include build/runtime overhead and are not a measured browser download. The {build['archive_bytes'] / 1048576:.1f} MiB upstream setup archive bundles multiple models.",
                "Fresh-process timings/RSS are recorded in the report. They include file processing and padded fixtures; they do not establish mobile or WASM performance. No microphone, transcription, training, network inference or product integration is involved.",
            ],
        },
    )


if __name__ == "__main__":
    main()
