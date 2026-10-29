"""Fill missing browser-WASM listening cases; preserve existing review contexts."""

import hashlib
import json
import os
import subprocess
import sys
import tempfile
from pathlib import Path

import numpy as np
import soundfile as sf
from tvtsyn_inference import TVTSyn
from tvtsyn_inference.audio import resample

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
DATA = ROOT / "tmp/voice-browser"
AUDIO = ROOT / "tmp/voice-model"
sys.path.insert(0, str(ROOT / "tools/voice-eval"))
from randos_voice_eval.reconstruction import save_audio


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    preparation = json.loads((DATA / "preparation.json").read_text())
    destination = HERE / "results/browser-listening.json"
    report = (
        json.loads(destination.read_text())
        if destination.exists()
        else {"candidates": {"tvtsyn_browser": {}}, "runs": {}}
    )
    existing = report["candidates"]["tvtsyn_browser"]
    high = json.loads((HERE / "results/listening.json").read_text())
    runtime = None
    for clip in [
        "high_voice",
        "low_voice",
        "mid_voice",
        "mencken_wasichu",
        "test_tone",
    ]:
        tone = clip == "test_tone"
        source = (
            ROOT / "tmp/voice-tone/input.wav"
            if tone
            else ROOT / f"dev/voice_lab/clips/{clip}.wav"
        )
        if tone and not source.exists():
            continue
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
            expected = np.frombuffer(generated.stdout, dtype="<f4")
            actual, tone_rate = sf.read(source, dtype="float32")
            if tone_rate != 48000 or not np.array_equal(actual, expected):
                raise ValueError(
                    "Cached tone differs from the current generator; run just voice-tone first"
                )
        key = clip if tone else clip + ".wav"
        source_id = (
            digest(ROOT / "assets/js/voice_lab/test_tone.js")
            if tone
            else digest(source)
        )
        saved = existing.get(key)
        if (
            saved
            and saved["context"]["source_id"] == source_id
            and all(
                (AUDIO / name).exists()
                and digest(AUDIO / name) == Path(name).stem.split("__")[-1]
                for name in saved["audio"].values()
            )
        ):
            continue
        if (
            clip == "high_voice"
            and high["source_sha256"] == digest(source)
            and all(
                (AUDIO / name).exists()
                and digest(AUDIO / name) == Path(name).stem.split("__")[-1]
                for name in high["audio"].values()
            )
        ):
            # The existing manifest remains the authoritative high-voice case.
            continue
        if runtime is None:
            runtime = TVTSyn.from_pretrained(
                preparation["root"], backend="onnx", threads=4
            )
        raw, rate = sf.read(source, dtype="float32")
        samples = resample(raw, rate)
        speaker = np.fromfile(DATA / "speaker.f32", dtype="<f4").reshape(1, 704)
        native = runtime.convert(samples, speaker)
        prefix = f"listening-{clip}-"
        samples.astype("<f4").tofile(DATA / f"{prefix}input.f32")
        native.astype("<f4").tofile(DATA / f"{prefix}native.f32")
        prepared = {
            **preparation,
            "source_sha256": digest(source),
            "input_samples": len(samples),
            "output_samples": len(native),
            "input_kind": "synthetic tone" if tone else "public speech",
            "native_setup_seconds": None,
            "native_inference_seconds": None,
            "native_peak": float(np.max(np.abs(native))),
            "native_reference_note": "Fresh conversion from this clip using a shared native session; timings not measured in this listening-only completion run.",
        }
        prepared_path = DATA / f"{prefix}preparation.json"
        prepared_path.write_text(json.dumps(prepared))
        result_path = HERE / f"results/browser-{clip}.json"
        environment = {
            **os.environ,
            "PREPARATION_FILE": str(prepared_path),
            "INPUT_FILE": str(DATA / f"{prefix}input.f32"),
            "REFERENCE_FILE": str(DATA / f"{prefix}native.f32"),
            "OUTPUT_TAG": prefix,
            "RESULT_PATH": str(result_path),
            "PROVIDERS": "wasm",
            "WASM_THREADS": "4",
            "RESOURCE_PROFILE": "0",
            "MODES": "parity",
        }
        subprocess.run(
            ["node", str(HERE / "run.mjs")], cwd=ROOT, env=environment, check=True
        )
        run = json.loads(result_path.read_text())
        if run["runs"][0]["status"] != "complete":
            raise RuntimeError(f"Browser conversion failed for {clip}")
        wave = np.fromfile(DATA / f"{prefix}wasm-parity.f32", dtype="<f4")
        if len(wave) != len(samples) or not np.isfinite(wave).all():
            raise ValueError(
                "Browser output must be finite and preserve the whole clip"
            )
        identity = {
            "script_sha256": digest(Path(__file__)),
            "source": digest(source),
            "execution": run["execution"],
            "harness": run["harness_sha256"],
        }
        existing[key] = {
            "audio": {
                "original": save_audio(
                    clip, "browser_original", resample(raw, rate, 48000) * 0.25, AUDIO
                ),
                "converted": save_audio(
                    clip,
                    "browser_converted",
                    resample(wave, 16000, 48000) * 0.25,
                    AUDIO,
                ),
            },
            "context": {
                "view": "model",
                "mode": "browser_wasm",
                "processor": "tvtsyn_browser",
                "build_id": hashlib.sha256(
                    json.dumps(identity, sort_keys=True).encode()
                ).hexdigest(),
                "source_id": source_id,
                "sample": clip,
                "case_id": clip,
                "run_id": run["generated_at"],
            },
            "description": "Synthetic-tone diagnostic through browser WASM."
            if tone
            else "TVTSyn browser WASM, target-voice control."
            if clip == "mid_voice"
            else "TVTSyn output rendered by the browser WASM probe.",
            "note": "Actual browser WASM output, checked against native ONNX on identical input. Prepared WAV playback only; no weights load in this lab view."
            + (
                " Synthetic tone, not speech or evidence of masking quality."
                if tone
                else ""
            )
            + (
                " This recording is also the target voice: a control, not disguise evidence."
                if clip == "mid_voice"
                else ""
            ),
        }
        report["runs"][clip] = {
            "path": str(result_path.relative_to(ROOT)),
            "execution": run["execution"],
            "comparison": run["runs"][0]["comparison"],
        }
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
