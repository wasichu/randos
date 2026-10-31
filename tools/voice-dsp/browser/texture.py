"""Two independent, full-band prepared auditions, with matched reconstruction."""

import hashlib
import json
import subprocess
import sys
import time
from datetime import UTC, datetime
from pathlib import Path

import numpy as np
from envelope import render
from prepare import OUT, ROOT, digest
from publish import atomic_json
from texture_core import FRAME, HOP, ORDER, PRE, transform

sys.path.insert(0, str(ROOT / "tools/voice-browser"))
from sound_quality import match_levels

sys.path.insert(0, str(ROOT / "tools/voice-eval"))
from randos_voice_eval.reconstruction import save_audio

HERE = Path(__file__).resolve().parent
ROUNDS = {
    "bandwidth": [
        ("narrower", "Narrower resonances", {"bandwidth": 0.75}),
        ("wider", "Wider resonances", {"bandwidth": 1.35}),
    ],
    "source": [
        ("softer", "Softer excitation pulses", {"gamma": 0.8}),
        ("sharper", "Sharper excitation pulses", {"gamma": 1.25}),
    ],
}


def main():
    subprocess.run(["python3", HERE / "check_vendor.py"], check=True, cwd=ROOT)
    subprocess.run(
        [
            "clang++",
            "-O3",
            "-std=c++17",
            "-ffp-contract=off",
            "-shared",
            "-fPIC",
            f"-I{ROOT / 'vendor/signalsmith'}",
            f"-I{ROOT / 'vendor/signalsmith/stretch'}",
            HERE / "spectral.cpp",
            "-o",
            OUT / "texture_reference.dylib",
        ],
        check=True,
    )
    subprocess.run(
        [
            sys.executable,
            "-m",
            "unittest",
            "discover",
            "-s",
            HERE,
            "-p",
            "test_texture.py",
        ],
        check=True,
    )
    provenance = {
        str(p.relative_to(ROOT)): digest(p)
        for p in [
            Path(__file__),
            HERE / "texture_core.py",
            HERE / "test_texture.py",
            HERE / "envelope.py",
            HERE / "prepare.py",
            HERE / "spectral.cpp",
            ROOT / "vendor/signalsmith/manifest.json",
            ROOT / "vendor/signalsmith/stretch/signalsmith-stretch.h",
            OUT / "texture_reference.dylib",
        ]
    }
    accepted = ROOT / "tools/voice-dsp/results/engine-comparison-probe.json"
    preferred = json.loads(accepted.read_text())
    provenance[str(accepted.relative_to(ROOT))] = digest(accepted)
    run = datetime.now(UTC).isoformat()
    cases = {name: {} for name in ROUNDS}
    candidates = {name: {} for name in ROUNDS}
    checks = []
    for clip, item in preferred["inputs"].items():
        source = ROOT / (
            "assets/js/voice_lab/test_tone.js"
            if clip == "test_tone"
            else f"dev/voice_lab/clips/{clip}.wav"
        )
        input_path = OUT / "input" / f"{clip}.f32"
        if (
            digest(source) != item["source_id"]
            or digest(input_path) != item["input_sha256"]
        ):
            raise ValueError("Stale source/input")
        x = np.fromfile(input_path, dtype="<f4")
        pitch, scale = (
            (1, 1.25) if clip in ["low_voice", "mencken_wasichu"] else (-1, 0.8)
        )
        reference = render("texture_reference", x, pitch, scale)
        for kind, variants in ROUNDS.items():
            control, control_stats = transform(
                reference, sos_control=kind == "bandwidth"
            )
            err = float(np.max(np.abs(control - reference)))
            relative = float(
                np.sqrt(np.mean((control - reference) ** 2))
                / max(np.sqrt(np.mean(reference**2)), 1e-12)
            )
            if err > (0.001 if kind == "bandwidth" else 1e-7) or relative > 0.01:
                raise ValueError("Matched reconstruction exceeds declared bounds")
            waves = {"original": x, "reference": reference, "control": control}
            stats = {"control": control_stats}
            settings = {
                "reference": {"pitch": pitch, "scale": scale},
                "control": {"bandwidth": 1.0, "gamma": 1.0},
            }
            for name, _, params in variants:
                start = time.perf_counter()
                waves[name], stats[name] = transform(reference, **params)
                stats[name]["offline_wall_ms"] = (time.perf_counter() - start) * 1000
                stats[name]["raw_peak"] = float(np.max(np.abs(waves[name])))
                stats[name]["rms_delta_from_reference"] = float(
                    np.sqrt(np.mean((waves[name] - reference) ** 2))
                )
                if stats[name]["voiced_frames"] == 0 or np.array_equal(
                    waves[name], control
                ):
                    raise ValueError("Candidate did not affect this source")
                settings[name] = {
                    "bandwidth": 1.0,
                    "gamma": 1.0,
                    **params,
                    "source_wet": 0.35 if kind == "source" else 0,
                    "frame": FRAME,
                    "hop": HOP,
                    "lpc_order": ORDER,
                    "preemphasis": PRE,
                }
            raw_hashes = {
                name: hashlib.sha256(y.astype("<f4").tobytes()).hexdigest()
                for name, y in waves.items()
            }
            waves, gains = match_levels(waves)
            audio = {
                name: save_audio(
                    clip, f"texture_{kind}_{name}", y, ROOT / "tmp/voice-model"
                )
                for name, y in waves.items()
            }
            context = {
                "view": "round",
                "mode": f"{kind}_1",
                "processor": "signalsmith_texture",
                "build_id": None,
                "source_id": item["source_id"],
                "sample": clip,
                "case_id": clip,
                "run_id": run,
            }
            descriptions = {
                "original": "Original recording · level matched",
                "reference": f"Released Signalsmith · pitch {pitch:+d} semitone · resonance ×{scale:.2f}",
                "control": "Same reference through matched source/filter analysis and reconstruction · no intentional change",
            }
            for name, _, params in variants:
                descriptions[name] = (
                    (
                        f"Resonance decay bandwidth ×{params['bandwidth']:.2f}; pole angles retained"
                        if kind == "bandwidth"
                        else f"Estimated excitation signed-power γ={params['gamma']:.2f} · 35% source blend"
                    )
                    + f" · {stats[name]['voiced_frames']}/{stats[name]['frames']} frames voiced"
                )
            key = clip if clip == "test_tone" else clip + ".wav"
            note = "Prepared full-band native/Python audition, not live or streaming-qualified. Compare the reconstruction control with Signalsmith first."
            if clip == "test_tone":
                note += " Diagnostic tone: this speech analysis can create artifacts here; do not rate disguise from it."
            cases[kind][key] = {
                "context": context,
                "audio": audio,
                "settings": settings,
                "descriptions": descriptions,
                "gains": gains,
                "note": note,
            }
            checks.append(
                {
                    "kind": kind,
                    "clip": clip,
                    "reference_pcm_sha256": raw_hashes["reference"],
                    "raw_pcm_sha256": raw_hashes,
                    "reconstruction_max_abs": err,
                    "reconstruction_relative_rms": relative,
                    "control_path": "roots_to_sos"
                    if kind == "bandwidth"
                    else "direct_filter",
                    "statistics": stats,
                }
            )
            for name, _, _ in [("control", "", {}), *variants]:
                processor = f"texture_{kind}_{name}"
                candidates[kind].setdefault(processor, {})[key] = {
                    "audio": {"original": audio["original"], "converted": audio[name]},
                    "description": descriptions[name],
                    "note": note,
                    "level_matched": True,
                    "context": {
                        **context,
                        "view": "model",
                        "mode": f"texture_{kind}",
                        "processor": processor,
                    },
                }
            print(
                f"Prepared {clip}/{kind}: matched reconstruction error {err:.3g}",
                flush=True,
            )
    for kind, variants in ROUNDS.items():
        identity = {
            "provenance": provenance,
            "checks": [x for x in checks if x["kind"] == kind],
            "cases": {
                k: {n: v for n, v in c.items() if n != "context"}
                for k, c in cases[kind].items()
            },
        }
        build = hashlib.sha256(
            json.dumps(identity, sort_keys=True).encode()
        ).hexdigest()
        for c in cases[kind].values():
            c["context"]["build_id"] = build
        for group in candidates[kind].values():
            for c in group.values():
                c["context"]["build_id"] = build
        details = [
            "Prioritize a pleasant disguise, clear words, emotional expression and conversational comfort. This is not a speaker-recognition contest.",
            "Both candidates add just one technique to the same released Signalsmith preset. Compare the matched reconstruction control first: quality loss there belongs to the analysis, not the new modification.",
            "40 ms full-band 48 kHz frames, 20 ms hops, fixed order-48 regularized LPC and a smoothed strength gate for periodic speech. Quiet/unvoiced frames bypass the extra stage. These prepared arrays are not a causal streaming implementation or a latency measurement.",
            "All four voices and the test tone are included. Average levels are matched with common peak headroom, without limiting. No microphone or model weights are used.",
        ]
        details.append(
            "Only eligible 150–4000 Hz complex poles change decay width, by factors .75 / 1.35; angles are retained. Narrowing that would go below 40 Hz stays unchanged, and pole/frame counts are recorded. Pole angles do not guarantee unchanged combined spectral peaks."
            if kind == "bandwidth"
            else "This is estimated excitation shaping, not recovered glottal flow or a physiological voice-source model. A voiced-frame residual gets nonlinear signed-power shaping, DC correction and RMS restoration, with a fixed 35% blend. The vocal-tract estimate is held fixed; separation is imperfect."
        )
        atomic_json(
            HERE.parent / f"results/{kind}.json",
            {
                "identity": identity,
                "variants": [
                    {"id": "original", "label": "Original"},
                    {"id": "reference", "label": "Signalsmith reference"},
                    {"id": "control", "label": "Matched reconstruction control"},
                ]
                + [{"id": n, "label": label} for n, label, _ in variants],
                "cases": cases[kind],
                "candidates": candidates[kind],
                "title": "Resonance width"
                if kind == "bandwidth"
                else "Estimated voice-source shape",
                "intro": "Does changing resonance width add a pleasant disguise while keeping the words and expression clear?"
                if kind == "bandwidth"
                else "Does changing the estimated excitation pulse shape add a pleasant disguise without roughness or lost expression?",
                "preference_label": "Best balance of pleasant disguise, clarity and expression",
                "details": details,
            },
        )


if __name__ == "__main__":
    main()
