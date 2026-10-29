"""Prepare the canonical synthetic tone for every offline lab modification."""

import hashlib
import json
import subprocess
import sys
from datetime import UTC, datetime
from pathlib import Path

import numpy as np
import soundfile as sf
from sound_quality import match_levels
from tvtsyn_inference import TVTSyn
from tvtsyn_inference.audio import resample

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT / "tools/voice-eval"))
from randos_voice_eval import render
from randos_voice_eval.reconstruction import save_audio


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    folder = ROOT / "tmp/voice-tone"
    folder.mkdir(parents=True, exist_ok=True)
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
    raw = np.frombuffer(generated.stdout, dtype="<f4").copy()
    if len(raw) != 192000 or not np.isfinite(raw).all():
        raise ValueError("Expected the canonical four-second 48 kHz tone")
    source = folder / "input.wav"
    if source.exists():
        saved, rate = sf.read(source, dtype="float32")
    else:
        saved, rate = np.empty(0), None
    if rate != 48000 or not np.array_equal(saved, raw):
        sf.write(source, raw, 48000, subtype="FLOAT")
    seed_report = ROOT / "tools/voice-model/results/seed-vc-tone.json"
    if not seed_report.exists() or json.loads(seed_report.read_text())["results"][0][
        "source_sha256"
    ] != digest(source):
        subprocess.run(
            [
                str(ROOT / "tmp/seed-vc/.venv/bin/python"),
                str(ROOT / "tools/voice-model/probe.py"),
                "--tone",
                str(source),
            ],
            cwd=ROOT,
            check=True,
        )
    world = subprocess.run(
        [
            str(ROOT / "tmp/voice-dsp/.venv/bin/python"),
            str(ROOT / "tools/voice-dsp/probe.py"),
            "--worker",
            "test_tone",
        ],
        capture_output=True,
        check=True,
    )
    world = json.loads(world.stdout)
    subprocess.run(
        [sys.executable, str(HERE / "complete_listening.py")], cwd=ROOT, check=True
    )
    render.build()
    prep = json.loads((ROOT / "tmp/voice-browser/preparation.json").read_text())
    speaker = np.fromfile(ROOT / "tmp/voice-browser/speaker.f32", dtype="<f4").reshape(
        1, 704
    )
    model = TVTSyn.from_pretrained(prep["root"], backend="onnx", threads=4)
    converted = (
        resample(model.convert(resample(raw, 48000), speaker), 16000, 48000) * 0.25
    )
    quantized = TVTSyn.from_pretrained(
        str(ROOT / "tmp/voice-browser/int8"), backend="onnx", threads=4
    )
    int8 = (
        resample(quantized.convert(resample(raw, 48000), speaker), 16000, 48000) * 0.25
    )
    seed = json.loads(seed_report.read_text())
    source_id = digest(ROOT / "assets/js/voice_lab/test_tone.js")
    provenance = {
        "generator_sha256": source_id,
        "input_wav_sha256": digest(source),
        "script_sha256": digest(Path(__file__)),
        "rust_renderer_sha256": digest(render.BINARY),
        "world_extension_sha256": world["extension_sha256"],
        "world_script_sha256": digest(ROOT / "tools/voice-dsp/probe.py"),
        "seed_build_id": seed["build_id"],
        "tvtsyn_graph": prep["artifacts_sha256"],
        "int8_graph_sha256": digest(
            ROOT / "tmp/voice-browser/int8/onnx/tvtsyn_step_100ms.onnx"
        ),
    }
    build = hashlib.sha256(json.dumps(provenance, sort_keys=True).encode()).hexdigest()
    stamp = datetime.now(UTC).isoformat()
    candidates = {}
    output = ROOT / "tmp/voice-model"
    original = raw * 0.25
    original_file = save_audio("test_tone", "diagnostic_original", original, output)

    def add(name, mode, audio, *, matched=False):
        candidates[name] = {
            "test_tone": {
                "audio": audio,
                "level_matched": matched,
                "context": {
                    "view": "model",
                    "mode": mode,
                    "processor": name,
                    "build_id": build,
                    "source_id": source_id,
                    "sample": "test_tone",
                    "case_id": "test_tone",
                    "run_id": stamp,
                },
                "description": "Synthetic-tone diagnostic through this modification.",
                "note": "A generated 110–220 Hz harmonic glide, not speech. Useful for hearing artifacts; neural models may turn it into unrelated speech-like sound. This is not evidence of voice masking or speech quality.",
            }
        }

    def audio(name, wave):
        if not np.isfinite(wave).all() or not len(wave) or np.max(np.abs(wave)) >= 1:
            raise ValueError(f"Invalid or clipping diagnostic: {name}")
        return {
            "original": original_file,
            "converted": save_audio("test_tone", name, wave, output),
        }

    add("seed_vc_v2", "average_voice_style", seed["results"][0]["audio"])
    add("tvtsyn_native", "native_onnx", audio("tvtsyn_native", converted))
    add("tvtsyn_int8", "dynamic_int8_onnx", audio("tvtsyn_int8", int8))
    for name, alpha, pitch in [
        ("hybrid_down_2", 0.9, -2),
        ("hybrid_up_2", 0.9, 2),
        ("hybrid_mild", 0.85, -1),
    ]:
        resonance, _ = render.process_48k(original, params={0: alpha})
        wave, _ = render.process_48k(
            np.pad(resonance, (0, 4800)), "pitch_shift", {0: pitch, 1: 40}
        )
        add(name, "fixed_dsp", audio(name, wave))
    resonance, _ = render.process_48k(original, params={0: 0.9})
    pitch, _ = render.process_48k(
        np.pad(original, (0, 4800)), "pitch_shift", {0: -2, 1: 40}
    )
    both, _ = render.process_48k(
        np.pad(resonance, (0, 4800)), "pitch_shift", {0: -2, 1: 40}
    )
    waves, _ = match_levels(
        {
            "original": np.pad(original, (0, 4800)),
            "quality_pitch": pitch,
            "quality_resonance": np.pad(resonance, (0, 4800)),
            "quality_both": both,
            "quality_tvtsyn": np.pad(converted, (0, 4800)),
        }
    )
    matched_original = save_audio(
        "test_tone", "quality_original", waves.pop("original"), output
    )
    for name, wave in waves.items():
        add(
            name,
            "rms_matched",
            {
                "original": matched_original,
                "converted": save_audio("test_tone", name, wave, output),
            },
            matched=True,
        )
    for name in ["world_control", "world_pitch", "world_formants", "world_texture"]:
        add(
            name,
            "model_free_dsp",
            {"original": world["audio"]["original"], "converted": world["audio"][name]},
            matched=True,
        )
    # Browser case is retained in browser-listening.json with its actual run context.
    report = {
        "candidates": candidates,
        "experiment": {
            "generated_at": stamp,
            "provenance": provenance,
            "world": world,
            "scope": "Synthetic-tone diagnostics only; existing voice artifacts and review contexts unchanged.",
        },
    }
    destination = HERE / "results/tone.json"
    pending = destination.with_suffix(".pending")
    pending.write_text(json.dumps(report, indent=2) + "\n")
    pending.replace(destination)
    print(f"Prepared synthetic tone for {len(candidates) + 1} offline modifications")


if __name__ == "__main__":
    main()
