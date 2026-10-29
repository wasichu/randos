"""Preferred settings through two engines; separate immutable listening round."""

import hashlib
import json
import sys
from pathlib import Path

import numpy as np
from prepare import OUT, ROOT, chunk_render, digest, library
from publish import atomic_json

sys.path.insert(0, str(ROOT / "tools/voice-browser"))
from sound_quality import match_levels

sys.path.insert(0, str(ROOT / "tools/voice-eval"))
from randos_voice_eval.reconstruction import save_audio

HERE = Path(__file__).resolve().parent
PROFILES = {
    "lower_mild": (-2, 0.9),
    "higher_mild": (2, 1.1),
    "higher_resonance": (2, 1.25),
}
SELECTED = {
    "high_voice": "lower_mild",
    "low_voice": "higher_mild",
    "mid_voice": "lower_mild",
    "mencken_wasichu": "higher_resonance",
    "test_tone": "lower_mild",
}


def prepare():
    baseline = json.loads((OUT / "inputs.json").read_text())
    accepted = json.loads(
        (HERE.parent / "results/masking-round-probe.json").read_text()
    )
    cases = {}
    (OUT / "engine-native").mkdir(exist_ok=True)
    for clip, profile in SELECTED.items():
        config = baseline[clip]
        source = ROOT / (
            "assets/js/voice_lab/test_tone.js"
            if clip == "test_tone"
            else f"dev/voice_lab/clips/{clip}.wav"
        )
        if (
            digest(source) != config["source_id"]
            or digest(OUT / "input" / f"{clip}.f32") != config["input_sha256"]
        ):
            raise ValueError("Stale preferred-engine input")
        pitch, scale = PROFILES[profile]
        x = np.fromfile(OUT / "input" / f"{clip}.f32", dtype="<f4")
        lib, process = library("world", pitch, scale)
        world, _ = chunk_render(x.astype("float64"), 3840, process)
        lib.dsp_close()
        lib, process = library("spectral", pitch, scale)
        il, ol = lib.dsp_input_latency(), lib.dsp_output_latency()
        spectral = np.concatenate(
            [process(x[i : i + 3840]) for i in range(0, len(x), 3840)]
            + [process(np.zeros(il)), process(np.zeros(ol), True)]
        )[il + ol : il + ol + len(x)]
        lib.dsp_close()
        for name, y in [("world", world), ("spectral", spectral)]:
            if len(y) != len(x) or not np.isfinite(y).all():
                raise ValueError("Invalid engine reference")
            y.astype("<f4").tofile(OUT / "engine-native" / f"{clip}-{name}.f32")
        previous = next(
            row
            for row in accepted["cases"]
            if row["clip"]
            == clip + ("__more_resonance" if clip == "mencken_wasichu" else "__current")
        )
        cases[clip] = {
            **config,
            "pitch": pitch,
            "scale": scale,
            "profile": profile,
            "accepted_spectral_sha256": previous["output_sha256"],
            "native_sha256": {
                name: digest(OUT / "engine-native" / f"{clip}-{name}.f32")
                for name in ["world", "spectral"]
            },
        }
    atomic_json(OUT / "engine-inputs.json", cases)
    atomic_json(
        OUT / "engine-native-build.json",
        {
            "script": digest(Path(__file__)),
            "libraries": {
                name: digest(OUT / f"{name}.dylib") for name in ["world", "spectral"]
            },
        },
    )


def publish():
    path = HERE.parent / "results/engine-comparison-probe.json"
    report = json.loads(path.read_text())
    if (
        not report.get("complete")
        or len(report["cases"]) != 10
        or not report["speech_tone_parity_pass"]
    ):
        raise ValueError("Ten strict parity checks required")
    cases, candidates = {}, {"preferred_spectral": {}, "preferred_world": {}}
    variants = [
        {"id": "original", "label": "Original"},
        {"id": "spectral", "label": "Signalsmith"},
        {"id": "world", "label": "WORLD"},
    ]
    for clip, config in report["inputs"].items():
        source = ROOT / (
            "assets/js/voice_lab/test_tone.js"
            if clip == "test_tone"
            else f"dev/voice_lab/clips/{clip}.wav"
        )
        if (
            digest(source) != config["source_id"]
            or digest(OUT / "input" / f"{clip}.f32") != config["input_sha256"]
        ):
            raise ValueError("Stale input")
        waves = {"original": np.fromfile(OUT / "input" / f"{clip}.f32", dtype="<f4")}
        for engine in ["spectral", "world"]:
            pcm = OUT / "engine-output" / f"{clip}-{engine}.f32"
            row = next(
                row
                for row in report["cases"]
                if row["clip"] == clip and row["name"] == engine
            )
            if digest(pcm) != row["output_sha256"]:
                raise ValueError("Browser PCM changed")
            if (
                engine == "spectral"
                and row["output_sha256"] != config["accepted_spectral_sha256"]
            ):
                raise ValueError(
                    "Preferred Signalsmith output changed from reviewed round"
                )
            waves[engine] = np.fromfile(pcm, dtype="<f4")
        waves, gains = match_levels(waves)
        audio = {
            name: save_audio(
                clip, "engine_compare_" + name, y, ROOT / "tmp/voice-model"
            )
            for name, y in waves.items()
        }
        key = clip if clip == "test_tone" else clip + ".wav"
        note = (
            "Unresolved: you found no useful disguise for mid voice. Mild settings are included for comparison, not as a successful mask."
            if clip == "mid_voice"
            else "Tone diagnostic only; judge masking on speech."
            if clip == "test_tone"
            else "Your preferred settings, held constant across both engines."
        )
        settings = {"pitch": config["pitch"], "scale": config["scale"]}
        descriptions = {
            "original": "Original sample, with matched average level.",
            **{
                name: f"Pitch {config['pitch']:+d} semitones · resonances ×{config['scale']:.2f}"
                for name in ["spectral", "world"]
            },
        }
        context = {
            "view": "round",
            "mode": "engine_comparison_1",
            "processor": "signalsmith_world",
            "build_id": None,
            "source_id": config["source_id"],
            "sample": clip,
            "case_id": clip,
            "run_id": report["generated_at"],
        }
        cases[key] = {
            "audio": audio,
            "context": context,
            "descriptions": descriptions,
            "settings": settings,
            "profile": config["profile"],
            "note": note,
            "gains": gains,
        }
        for engine in ["spectral", "world"]:
            processor = "preferred_" + engine
            candidates[processor][key] = {
                "audio": {"original": audio["original"], "converted": audio[engine]},
                "level_matched": True,
                "description": descriptions[engine],
                "note": note
                + " "
                + (
                    "Signalsmith synthetic-impulse parity differences remain unresolved."
                    if engine == "spectral"
                    else "WORLD uses bounded 80 ms reset windows."
                ),
                "context": {
                    **context,
                    "view": "model",
                    "mode": "preferred_engines",
                    "processor": processor,
                },
            }
    identity = {
        "probe": digest(path),
        "publisher": digest(Path(__file__)),
        "variants": variants,
        "cases": {
            key: {k: v for k, v in item.items() if k != "context"}
            for key, item in cases.items()
        },
    }
    build = hashlib.sha256(json.dumps(identity, sort_keys=True).encode()).hexdigest()
    for item in cases.values():
        item["context"]["build_id"] = build
    for group in candidates.values():
        for item in group.values():
            item["context"]["build_id"] = build
    atomic_json(
        HERE.parent / "results/engine-comparison.json",
        {
            "identity": identity,
            "variants": variants,
            "cases": cases,
            "candidates": candidates,
            "title": "Same voice settings, two different engines",
            "intro": "Compare Original → Signalsmith → WORLD at the settings you preferred. Mid voice remains unresolved; changing engines may improve sound quality without hiding cadence or accent.",
            "details": [
                "Both engines receive exactly the same input and fixed pitch/resonance settings. Levels are matched together across all three recordings.",
                "WORLD rebuilds speech in overlapping 80 ms windows. Signalsmith continuously modifies the spectrum. Existing Signalsmith impulse-parity discrepancies remain unresolved.",
                "Use in live preview selects this profile without opening the microphone. Start monitoring explicitly in Try your voice, using headphones. No new performance or privacy claim is made.",
            ],
        },
    )


if __name__ == "__main__":
    publish() if "--publish" in sys.argv else prepare()
