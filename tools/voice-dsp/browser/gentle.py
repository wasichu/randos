"""One-variable pitch audition; preferred resonances remain fixed per source."""

import hashlib
import json
import sys
from pathlib import Path

import numpy as np
from prepare import OUT, ROOT, digest, library
from publish import atomic_json

sys.path.insert(0, str(ROOT / "tools/voice-browser"))
from sound_quality import match_levels

sys.path.insert(0, str(ROOT / "tools/voice-eval"))
from randos_voice_eval.reconstruction import save_audio

HERE = Path(__file__).resolve().parent
VARIANTS = [
    ("current_pitch", "Current pitch shift", "current_pitch"),
    ("half_pitch", "Half the pitch shift", "half_pitch"),
    ("zero_pitch", "No pitch shift · resonance retained", "zero_pitch"),
]


def prepare():
    preferred = json.loads(
        (HERE.parent / "results/engine-comparison-probe.json").read_text()
    )
    cases = {}
    (OUT / "gentle-native").mkdir(exist_ok=True)
    for clip, item in preferred["inputs"].items():
        x = np.fromfile(OUT / "input" / f"{clip}.f32", dtype="<f4")
        if digest(OUT / "input" / f"{clip}.f32") != item["input_sha256"]:
            raise ValueError("Stale pitch-round input")
        for variant, _, _strength in VARIANTS:
            pitch = (
                item["pitch"]
                * {"current_pitch": 1, "half_pitch": 0.5, "zero_pitch": 0}[variant]
            )
            lib, process = library("spectral", pitch, item["scale"])
            il, ol = lib.dsp_input_latency(), lib.dsp_output_latency()
            y = np.concatenate(
                [process(x[i : i + 3840]) for i in range(0, len(x), 3840)]
                + [process(np.zeros(il)), process(np.zeros(ol), True)]
            )[il + ol : il + ol + len(x)]
            lib.dsp_close()
            if len(y) != len(x) or not np.isfinite(y).all():
                raise ValueError("Invalid native gentle output")
            key = clip + "__" + variant
            path = OUT / "gentle-native" / f"{key}-spectral.f32"
            y.astype("<f4").tofile(path)
            cases[key] = {
                **item,
                "input_key": clip,
                "variant": variant,
                "pitch": pitch,
                "native_sha256": {"spectral": digest(path)},
            }
    atomic_json(OUT / "gentle-inputs.json", cases)
    atomic_json(
        OUT / "gentle-native-build.json",
        {
            "script": digest(Path(__file__)),
            "library": digest(OUT / "spectral.dylib"),
            "preferred_probe": digest(
                HERE.parent / "results/engine-comparison-probe.json"
            ),
        },
    )


def publish():
    path = HERE.parent / "results/gentle-pitch-probe.json"
    report = json.loads(path.read_text())
    if (
        not report.get("complete")
        or len(report["cases"]) != 15
        or not report["speech_tone_parity_pass"]
    ):
        raise ValueError("Fifteen strict native/browser checks required")
    variants = [
        {"id": "original", "label": "Original"},
        *[
            {
                "id": name,
                "label": label,
                "engine": "spectral",
                "pitch_strength": strength,
            }
            for name, label, strength in VARIANTS
        ],
    ]
    cases, candidates = {}, {"gentle_" + name: {} for name, _, _ in VARIANTS}
    for clip in dict.fromkeys(row["input_key"] for row in report["inputs"].values()):
        item = report["inputs"][clip + "__current_pitch"]
        source = ROOT / (
            "assets/js/voice_lab/test_tone.js"
            if clip == "test_tone"
            else f"dev/voice_lab/clips/{clip}.wav"
        )
        if (
            digest(source) != item["source_id"]
            or digest(OUT / "input" / f"{clip}.f32") != item["input_sha256"]
        ):
            raise ValueError("Stale gentle source")
        waves = {"original": np.fromfile(OUT / "input" / f"{clip}.f32", dtype="<f4")}
        settings, descriptions = (
            {},
            {"original": "Original sample, with matched average level."},
        )
        for name, _, _ in VARIANTS:
            key = clip + "__" + name
            pcm = OUT / "gentle-output" / f"{key}-spectral.f32"
            row = next(r for r in report["cases"] if r["clip"] == key)
            if digest(pcm) != row["output_sha256"]:
                raise ValueError("Browser gentle output changed")
            if (
                name == "current_pitch"
                and row["output_sha256"] != item["accepted_spectral_sha256"]
            ):
                raise ValueError("Current pitch reference changed")
            waves[name] = np.fromfile(pcm, dtype="<f4")
            spec = report["inputs"][key]
            settings[name] = {"pitch": spec["pitch"], "scale": spec["scale"]}
            descriptions[name] = (
                f"Pitch {spec['pitch']:+g} semitones · resonances ×{spec['scale']:.2f}"
            )
        waves, gains = match_levels(waves)
        audio = {
            name: save_audio(clip, "gentle_" + name, y, ROOT / "tmp/voice-model")
            for name, y in waves.items()
        }
        key = clip if clip == "test_tone" else clip + ".wav"
        note = "Only pitch changes between the three processed versions; resonance is held fixed."
        if clip == "mid_voice":
            note += " Mid voice remains unresolved: less pitch movement may sound better without hiding its cadence or accent."
        if clip == "test_tone":
            note = "Tone diagnostic only; judge voice masking on speech."
        context = {
            "view": "round",
            "mode": "gentle_pitch_1",
            "processor": "signalsmith",
            "build_id": None,
            "source_id": item["source_id"],
            "sample": clip,
            "case_id": clip,
            "run_id": report["generated_at"],
        }
        cases[key] = {
            "context": context,
            "audio": audio,
            "settings": settings,
            "descriptions": descriptions,
            "gains": gains,
            "profile": item["profile"],
            "note": note,
        }
        for name, _, _ in VARIANTS:
            processor = "gentle_" + name
            candidates[processor][key] = {
                "audio": {"original": audio["original"], "converted": audio[name]},
                "description": descriptions[name],
                "note": note
                + " Signalsmith impulse-parity caveat remains; no privacy guarantee.",
                "level_matched": True,
                "context": {
                    **context,
                    "view": "model",
                    "mode": "gentle_pitch",
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
    for case in cases.values():
        case["context"]["build_id"] = build
    for group in candidates.values():
        for case in group.values():
            case["context"]["build_id"] = build
    atomic_json(
        HERE.parent / "results/gentle-pitch.json",
        {
            "identity": identity,
            "variants": variants,
            "cases": cases,
            "candidates": candidates,
            "title": "A gentler pitch change?",
            "intro": "Compare the current pitch shift, half the shift, and no pitch shift. Resonance stays fixed so you can judge pitch on its own.",
            "details": [
                "Current moves pitch two semitones; Half moves it one. No pitch shift still changes resonance: it is not the original recording or a bypass.",
                "All four versions are level-matched together. Pick the best balance of clear speech, naturalness and useful masking; None is useful remains a valid answer.",
                "Use live transfers the chosen pitch strength and resonance profile without opening your microphone. Existing Signalsmith impulse-parity discrepancies remain unresolved.",
            ],
        },
    )


if __name__ == "__main__":
    publish() if "--publish" in sys.argv else prepare()
