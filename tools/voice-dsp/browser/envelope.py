"""One native-only nonlinear-envelope audition. No product/vendor edits or downloads."""

import ctypes
import hashlib
import json
import subprocess
import sys
from datetime import UTC, datetime
from pathlib import Path

import numpy as np
from prepare import OUT, ROOT, digest, library
from publish import atomic_json

sys.path.insert(0, str(ROOT / "tools/voice-browser"))
from sound_quality import match_levels

sys.path.insert(0, str(ROOT / "tools/voice-eval"))
from randos_voice_eval.reconstruction import save_audio

HERE = Path(__file__).resolve().parent
BUILD = OUT / "envelope"
VARIANTS = [
    ("current", "Released style", 0),
    ("bend_a", "Bend A", 0.15),
    ("bend_b", "Bend B", -0.15),
]


def build():
    """Patch an ignored COPY of the pinned header; fail if the anchor changes."""
    subprocess.run(["python3", HERE / "check_vendor.py"], cwd=ROOT, check=True)
    BUILD.mkdir(parents=True, exist_ok=True)
    test = BUILD / "envelope_map_test"
    subprocess.run(
        [
            "clang++",
            "-std=c++17",
            "-fsanitize=address,undefined",
            "-fno-sanitize-recover=all",
            "-pthread",
            HERE / "envelope_map_test.cpp",
            "-o",
            test,
        ],
        check=True,
    )
    with subprocess.Popen([test], stdin=subprocess.PIPE) as child:
        try:
            status = child.wait(timeout=15)
        finally:
            child.stdin.close()
            try:
                child.wait(timeout=5)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait()
        if status:
            raise RuntimeError(f"Envelope mapping sanitizer check failed: {status}")
    source = ROOT / "vendor/signalsmith/stretch/signalsmith-stretch.h"
    text = source.read_text()
    anchor = "return freq*invFormantMultiplier;"
    if text.count(anchor) != 1:
        raise ValueError("Research envelope patch anchor changed")
    patched = '#include "envelope_map.h"\n' + text.replace(
        anchor, "return ::randosResearchWarp(freq, freq*invFormantMultiplier);"
    )
    header = BUILD / "research-signalsmith-stretch.h"
    header.write_text(patched)
    wrapper = BUILD / "envelope.cpp"
    wrapper.write_text(
        (HERE / "spectral.cpp")
        .read_text()
        .replace('"signalsmith-stretch.h"', '"research-signalsmith-stretch.h"')
        + '\nextern "C" int dsp_set_bend(double bend) {\n'
        "  if (!std::isfinite(bend) || std::abs(bend) > .15) return 0;\n"
        "  randosResearchBend = bend; return 1;\n}\n"
    )
    common = [
        "clang++",
        "-O3",
        "-std=c++17",
        "-ffp-contract=off",
        "-shared",
        "-fPIC",
        f"-I{HERE}",
        f"-I{ROOT / 'vendor/signalsmith'}",
    ]
    subprocess.run([*common, wrapper, "-o", OUT / "envelope.dylib"], check=True)
    subprocess.run(
        [
            *common,
            f"-I{source.parent}",
            HERE / "spectral.cpp",
            "-o",
            OUT / "envelope_control.dylib",
        ],
        check=True,
    )
    return {
        str(p.relative_to(ROOT)): digest(p)
        for p in [
            Path(__file__),
            HERE / "envelope_map.h",
            HERE / "envelope_map_test.cpp",
            HERE / "spectral.cpp",
            source,
            ROOT / "vendor/signalsmith/manifest.json",
            header,
            wrapper,
            OUT / "envelope.dylib",
            OUT / "envelope_control.dylib",
        ]
    }


def render(name, x, pitch, scale, bend=0):
    lib, process = library(name, pitch, scale)
    try:
        if name == "envelope":
            lib.dsp_set_bend.argtypes = [ctypes.c_double]
            if lib.dsp_set_bend(bend) != 1:
                raise ValueError("Invalid envelope bend")
        il, ol = lib.dsp_input_latency(), lib.dsp_output_latency()
        parts = [process(x[i : i + 3840]) for i in range(0, len(x), 3840)]
        parts += [process(np.zeros(il)), process(np.zeros(ol), True)]
        y = np.concatenate(parts)[il + ol : il + ol + len(x)]
        if len(y) != len(x) or not np.isfinite(y).all():
            raise ValueError("Invalid envelope output")
        return y
    finally:
        lib.dsp_close()


def mapping_checks():
    f = np.linspace(0, 0.5, 48001)
    cutoff = 4000 / 48000
    angle = np.pi * f / cutoff
    bump = cutoff / (2 * np.pi) * np.sin(2 * angle) * np.sin(angle) ** 2
    bump[f >= cutoff] = 0
    checks = []
    for scale in [0.8, 1.25]:
        for bend in [-0.15, 0, 0.15]:
            mapped = f / scale + bend * bump
            if not np.all(np.diff(mapped) > 0):
                raise ValueError("Envelope map must stay monotonic")
            if not np.array_equal(mapped[f >= cutoff], (f / scale)[f >= cutoff]):
                raise ValueError("High-frequency lookup changed")
            checks.append(
                {
                    "scale": scale,
                    "bend": bend,
                    "min_slope": float(np.min(np.diff(mapped) / np.diff(f))),
                    "max_lookup_delta_hz": float(np.max(np.abs(bend * bump)) * 48000),
                }
            )
    return checks


def main():
    provenance = build()
    boundary_checks = []
    for label in ["silence", "onset", "ending"]:
        x = np.zeros(8193 + 4800, dtype="<f4")
        if label != "silence":
            x[0 if label == "onset" else 8192] = 0.1
        for pitch, scale in [(-1, 0.8), (1, 1.25)]:
            control = render("envelope_control", x, pitch, scale)
            for _, _, bend in VARIANTS:
                y = render("envelope", x, pitch, scale, bend)
                if bend == 0 and not np.array_equal(y, control):
                    raise ValueError("Zero-bend boundary control changed")
                if label == "silence" and np.any(y != 0):
                    raise ValueError("Silence must remain silent")
                boundary_checks.append(
                    {
                        "fixture": label,
                        "pitch": pitch,
                        "scale": scale,
                        "bend": bend,
                        "samples": len(y),
                        "finite": True,
                    }
                )
    preferred = json.loads(
        (HERE.parent / "results/engine-comparison-probe.json").read_text()
    )
    stamp = datetime.now(UTC).isoformat()
    cases, checks = {}, []
    candidates = {"envelope_" + name: {} for name, _, _ in VARIANTS}
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
            raise ValueError("Stale source/input; regenerate accepted inputs first")
        x = np.fromfile(input_path, dtype="<f4")
        pitch, scale = (
            (1, 1.25) if clip in ["low_voice", "mencken_wasichu"] else (-1, 0.8)
        )
        control = render("envelope_control", x, pitch, scale)
        waves, settings = {"original": x}, {}
        for name, _, bend in VARIANTS:
            y = render("envelope", x, pitch, scale, bend)
            if bend == 0 and not np.array_equal(y, control):
                raise ValueError("Zero-bend output differs from untouched engine")
            if bend != 0 and clip != "test_tone" and np.array_equal(y, control):
                raise ValueError("Bend did not affect speech")
            waves[name] = y
            settings[name] = {
                "pitch": pitch,
                "scale": scale,
                "bend": bend,
                "cutoff_hz": 4000,
            }
        checks.append(
            {
                "sample": clip,
                "input_sha256": digest(input_path),
                "samples": len(x),
                "zero_bend_exact": True,
                "control_pcm_sha256": hashlib.sha256(
                    control.astype("<f4").tobytes()
                ).hexdigest(),
                "rendered_pcm_sha256": {
                    k: hashlib.sha256(y.astype("<f4").tobytes()).hexdigest()
                    for k, y in waves.items()
                },
            }
        )
        waves, gains = match_levels(waves)
        audio = {
            name: save_audio(clip, "envelope_" + name, y, ROOT / "tmp/voice-model")
            for name, y in waves.items()
        }
        descriptions = {"original": "Original recording · matched average level"}
        for name, _, bend in VARIANTS:
            descriptions[name] = (
                f"Pitch {pitch:+g} semitone · resonances ×{scale:.2f} · "
                + (
                    "no extra bend"
                    if bend == 0
                    else f"envelope bend {bend:+.2f} below 4 kHz"
                )
            )
        note = "Prepared native audio; the new bends are not available in live preview."
        if clip == "mid_voice":
            note += " This voice previously retained a recognizable cadence/accent; this experiment changes neither."
        if clip == "test_tone":
            note = "Synthetic tone diagnostic only; do not judge masking quality from this source."
        context = {
            "view": "round",
            "mode": "selective_resonance_1",
            "processor": "signalsmith_envelope",
            "build_id": None,
            "source_id": item["source_id"],
            "sample": clip,
            "case_id": clip,
            "run_id": stamp,
        }
        key = clip if clip == "test_tone" else clip + ".wav"
        cases[key] = {
            "context": context,
            "audio": audio,
            "settings": settings,
            "descriptions": descriptions,
            "gains": gains,
            "note": note,
        }
        for name, _, _ in VARIANTS:
            processor = "envelope_" + name
            candidates[processor][key] = {
                "audio": {"original": audio["original"], "converted": audio[name]},
                "description": descriptions[name],
                "note": note,
                "level_matched": True,
                "context": {
                    **context,
                    "view": "model",
                    "mode": "selective_resonance",
                    "processor": processor,
                },
            }
        print(
            f"Prepared {clip}: zero-bend exactly matches untouched engine", flush=True
        )
    if len(cases) != 5:
        raise ValueError("All four public voices and the tone are required")
    identity = {
        "compiler": subprocess.run(
            ["clang++", "--version"], capture_output=True, text=True, check=True
        ).stdout.splitlines()[0],
        "compile_flags": ["-O3", "-std=c++17", "-ffp-contract=off", "-shared", "-fPIC"],
        "provenance": provenance,
        "checks": checks,
        "boundary_checks": boundary_checks,
        "mapping_checks": mapping_checks(),
        "cases": {
            key: {k: v for k, v in case.items() if k != "context"}
            for key, case in cases.items()
        },
    }
    build_id = hashlib.sha256(json.dumps(identity, sort_keys=True).encode()).hexdigest()
    for case in cases.values():
        case["context"]["build_id"] = build_id
    for group in candidates.values():
        for case in group.values():
            case["context"]["build_id"] = build_id
    atomic_json(
        HERE.parent / "results/selective-resonance.json",
        {
            "identity": identity,
            "variants": [{"id": "original", "label": "Original"}]
            + [{"id": name, "label": label} for name, label, _ in VARIANTS],
            "cases": cases,
            "candidates": candidates,
            "title": "A different resonance pattern?",
            "intro": "Compare the released style with two gentle changes to the shape of its resonances. Pitch stays fixed. Does either disguise the voice better while keeping it clear?",
            "details": [
                "Bend A and B move lower and middle resonance regions in opposing directions, fading smoothly to the unchanged lookup at 4 kHz. They reshape the envelope, not the harmonic frequencies.",
                "The baseline uses the released strong-resonance + one-semitone style. High/mid voices use Fuller; low voice and Wasichu use Brighter. Pitch and overall resonance scale are identical across all three processed versions.",
                "These are native-produced WAVs, not browser-produced DSP. The zero-bend research copy must match the untouched pinned engine exactly. Browser parity, streaming performance and masking strength are not yet established for the bends.",
                "All versions share RMS matching and peak headroom, without limiting. Prefer the released style or None is useful if the bends add roughness or obscure speech. Cadence and accent are unchanged.",
            ],
        },
    )


if __name__ == "__main__":
    main()
