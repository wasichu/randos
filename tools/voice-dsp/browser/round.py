"""Stronger Signalsmith auditions; exact native refs, browser PCM, immutable round."""

import hashlib
import json
import sys
from pathlib import Path

import numpy as np
from prepare import OUT, ROOT, digest, library

sys.path.insert(0, str(ROOT / "tools/voice-browser"))
from sound_quality import match_levels

sys.path.insert(0, str(ROOT / "tools/voice-eval"))
from publish import atomic_json
from randos_voice_eval.reconstruction import save_audio

HERE = Path(__file__).resolve().parent
VARIANTS = {
    "current": "Current",
    "more_pitch": "More pitch",
    "more_resonance": "More resonance",
    "opposing": "Opposing directions",
}


def prepare():
    previous = json.loads((HERE.parent / "results/browser-probe.json").read_text())
    inputs = json.loads((OUT / "inputs.json").read_text())
    for name in ["spectral.wasm", "spectral.mjs"]:
        if digest(OUT / name) != previous["assets"]["/build/" + name]["sha256"]:
            raise ValueError("Spectral build changed; rerun browser baseline first")
    (OUT / "round-native").mkdir(exist_ok=True)
    cases = {}
    for clip, item in inputs.items():
        source = ROOT / (
            "assets/js/voice_lab/test_tone.js"
            if clip == "test_tone"
            else f"dev/voice_lab/clips/{clip}.wav"
        )
        if (
            digest(source) != item["source_id"]
            or digest(OUT / "input" / f"{clip}.f32") != item["input_sha256"]
        ):
            raise ValueError("Input changed; regenerate baseline first")
        x = np.fromfile(OUT / "input" / f"{clip}.f32", dtype="<f4")
        direction = 1 if item["pitch"] > 0 else -1
        settings = {
            "current": (item["pitch"], item["scale"]),
            "more_pitch": (4 * direction, item["scale"]),
            "more_resonance": (item["pitch"], 1.25 if direction > 0 else 0.8),
            "opposing": (3 * direction, 0.9 if direction > 0 else 1.1),
        }
        for variant, (pitch, scale) in settings.items():
            key = clip + "__" + variant
            lib, process = library("spectral", pitch, scale)
            il, ol = lib.dsp_input_latency(), lib.dsp_output_latency()
            parts = [process(x[i : i + 3840]) for i in range(0, len(x), 3840)]
            parts += [process(np.zeros(il)), process(np.zeros(ol), True)]
            y = np.concatenate(parts)[il + ol : il + ol + len(x)].astype("<f4")
            lib.dsp_close()
            if len(y) != len(x) or not np.isfinite(y).all():
                raise ValueError("Invalid native round output")
            path = OUT / "round-native" / f"{key}-spectral.f32"
            y.tofile(path)
            cases[key] = {
                **item,
                "input_key": clip,
                "variant": variant,
                "pitch": pitch,
                "scale": scale,
                "native_sha256": {"spectral": digest(path)},
            }
    atomic_json(OUT / "round-inputs.json", cases)
    atomic_json(
        OUT / "round-native-build.json",
        {
            "round_script": digest(Path(__file__)),
            "spectral_library": digest(OUT / "spectral.dylib"),
            "sources": json.loads((HERE / "sources.json").read_text()),
        },
    )
    print("Prepared 20 exact native round references")


def publish():
    path = HERE.parent / "results/masking-round-probe.json"
    report = json.loads(path.read_text())
    if (
        not report.get("complete")
        or len(report["cases"]) != 20
        or not report["speech_tone_parity_pass"]
    ):
        raise ValueError("Twenty complete parity-checked outputs required")
    identity = {
        "probe_sha256": digest(path),
        "publisher_sha256": digest(Path(__file__)),
        "variant_order": ["original", *VARIANTS],
    }
    build = None
    baseline = json.loads((HERE.parent / "results/browser-probe.json").read_text())
    cases, candidates = (
        {},
        {"spectral_" + name: {} for name in VARIANTS if name != "current"},
    )
    for clip in dict.fromkeys(item["input_key"] for item in report["inputs"].values()):
        source = ROOT / (
            "assets/js/voice_lab/test_tone.js"
            if clip == "test_tone"
            else f"dev/voice_lab/clips/{clip}.wav"
        )
        config = report["inputs"][clip + "__current"]
        if (
            digest(source) != config["source_id"]
            or digest(OUT / "input" / f"{clip}.f32") != config["input_sha256"]
        ):
            raise ValueError("Stale round source")
        waves = {"original": np.fromfile(OUT / "input" / f"{clip}.f32", dtype="<f4")}
        descriptions = {"original": "Original sample, with matched average level."}
        for name in VARIANTS:
            key = clip + "__" + name
            pcm = OUT / f"{key}-spectral.f32"
            row = next(row for row in report["cases"] if row["clip"] == key)
            if digest(pcm) != row["output_sha256"]:
                raise ValueError("Browser output hash mismatch")
            if name == "current" and row["output_sha256"] != next(
                old["output_sha256"]
                for old in baseline["cases"]
                if old["clip"] == clip and old["name"] == "spectral"
            ):
                raise ValueError("Current changed from accepted browser reference")
            waves[name] = np.fromfile(pcm, dtype="<f4")
            spec = report["inputs"][key]
            descriptions[name] = (
                f"Pitch {spec['pitch']:+d} semitones · resonances ×{spec['scale']:.2f}"
            )
        if any(len(y) != config["samples"] for y in waves.values()):
            raise ValueError("Incomplete round output")
        waves, gains = match_levels(waves)
        files = {
            name: save_audio(
                clip, "strength_round_" + name, y, ROOT / "tmp/voice-model"
            )
            for name, y in waves.items()
        }
        context = {
            "view": "round",
            "mode": "signalsmith_strength_1",
            "processor": "signalsmith",
            "build_id": build,
            "source_id": config["source_id"],
            "sample": clip,
            "case_id": clip,
            "run_id": report["generated_at"],
        }
        key = clip if clip == "test_tone" else clip + ".wav"
        cases[key] = {
            "context": context,
            "audio": files,
            "descriptions": descriptions,
            "gains": gains,
            "settings": {
                name: {
                    field: report["inputs"][clip + "__" + name][field]
                    for field in ["pitch", "scale"]
                }
                for name in VARIANTS
            },
        }
        for name in VARIANTS:
            if name == "current":
                continue
            processor = "spectral_" + name
            candidates[processor][key] = {
                "audio": {"original": files["original"], "converted": files[name]},
                "level_matched": True,
                "description": descriptions[name],
                "note": "Actual Signalsmith browser output from the stronger masking round. Compare sound quality and resemblance. Existing synthetic impulse parity discrepancies remain unresolved; this is an exploratory audition, with no new performance or privacy guarantee.",
                "context": {
                    **context,
                    "view": "model",
                    "mode": "browser_dsp_round",
                    "processor": processor,
                },
            }
    identity["cases"] = {
        key: {
            "source_id": value["context"]["source_id"],
            "audio": value["audio"],
            "settings": value["settings"],
            "gains": value["gains"],
        }
        for key, value in cases.items()
    }
    build = hashlib.sha256(json.dumps(identity, sort_keys=True).encode()).hexdigest()
    for case in cases.values():
        case["context"]["build_id"] = build
    for group in candidates.values():
        for item in group.values():
            item["context"]["build_id"] = build
    # Publish the complete artifact set only after every source validates.
    atomic_json(
        HERE.parent / "results/masking-round.json",
        {
            "identity": identity,
            "variants": [
                {"id": "original", "label": "Original"},
                *[{"id": name, "label": label} for name, label in VARIANTS.items()],
            ],
            "cases": cases,
            "candidates": candidates,
        },
    )
    print(
        "Published five-way comparisons for all five sources; previous cases preserved"
    )


if __name__ == "__main__":
    publish() if "--publish" in sys.argv else prepare()
