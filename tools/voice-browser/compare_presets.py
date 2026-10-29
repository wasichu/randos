"""Four public clips: fixed DSP chains, TVTSyn and one bounded INT8 attempt."""

import hashlib
import json
import shutil
import sys
from datetime import UTC, datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(ROOT / "tools/voice-eval"))
from randos_voice_eval import render
from randos_voice_eval.reconstruction import save_audio

PRESETS = {
    "hybrid_down_2": {"alpha": 0.9, "semitones": -2},
    "hybrid_up_2": {"alpha": 0.9, "semitones": 2},
    "hybrid_mild": {"alpha": 0.85, "semitones": -1},
}


def main():
    import numpy as np
    import soundfile as sf
    import torch
    from onnxruntime.quantization import QuantType, quantize_dynamic
    from torchaudio.functional import resample
    from tvtsyn_inference import TVTSyn

    render.build()
    prep = json.loads((ROOT / "tmp/voice-browser/preparation.json").read_text())
    bundle = Path(prep["root"])
    model = TVTSyn.from_pretrained(str(bundle), backend="onnx", threads=4)
    speaker = np.fromfile(ROOT / "tmp/voice-browser/speaker.f32", dtype="<f4").reshape(
        1, 704
    )
    results = {
        "generated_at": datetime.now(UTC).isoformat(),
        "presets": PRESETS,
        "target": "mid_voice (same-source control when input is mid_voice)",
        "cases": [],
        "quantization": {},
    }
    candidates = {name: {} for name in [*PRESETS, "tvtsyn_native", "tvtsyn_int8"]}
    output = ROOT / "tmp/voice-model"
    output.mkdir(parents=True, exist_ok=True)
    quantized = None
    try:
        qroot = ROOT / "tmp/voice-browser/int8"
        (qroot / "onnx").mkdir(parents=True, exist_ok=True)
        source = ROOT / "tmp/voice-browser/quantization-source.onnx"
        shutil.copyfile(bundle / "onnx/tvtsyn_step_100ms.onnx", source)
        graph = qroot / "onnx/tvtsyn_step_100ms.onnx"
        quantize_dynamic(
            str(source),
            str(graph),
            op_types_to_quantize=["MatMul", "Gemm"],
            weight_type=QuantType.QInt8,
            per_channel=True,
        )
        shutil.copyfile(bundle / "config.json", qroot / "config.json")
        shutil.copyfile(
            bundle / "onnx/tvtsyn_step_100ms.onnx.json",
            qroot / "onnx/tvtsyn_step_100ms.onnx.json",
        )
        quantized = TVTSyn.from_pretrained(str(qroot), backend="onnx", threads=4)
        results["quantization"] = {
            "status": "ready",
            "method": "Dynamic INT8 MatMul/Gemm only, per-channel",
            "original_bytes": source.stat().st_size,
            "quantized_bytes": graph.stat().st_size,
            "sha256": hashlib.sha256(graph.read_bytes()).hexdigest(),
        }
    except Exception as error:  # noqa: BLE001 — preserve this bounded experiment's failure in its report
        results["quantization"] = {
            "status": "failed",
            "error": f"{type(error).__name__}: {error}",
        }
    identity = json.dumps(
        {
            "script": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
            "rust": hashlib.sha256(render.BINARY.read_bytes()).hexdigest(),
            "graph": prep["artifacts_sha256"],
            "speaker": prep["speaker_sha256"],
            "quantization": results["quantization"],
            "presets": PRESETS,
        },
        sort_keys=True,
    )
    build = hashlib.sha256(identity.encode()).hexdigest()
    for clip in ["high_voice", "low_voice", "mid_voice", "mencken_wasichu"]:
        path = ROOT / f"dev/voice_lab/clips/{clip}.wav"
        source, rate = sf.read(path, dtype="float32")
        raw48 = resample(torch.from_numpy(source), rate, 48000).numpy()
        raw16 = resample(torch.from_numpy(source), rate, 16000).numpy()
        original = raw48 * 0.25
        original_file = save_audio(clip, "comparison_original", original, output)
        for processor, cases in candidates.items():
            if processor == "tvtsyn_int8" and quantized is None:
                continue
            row = {"clip": clip, "processor": processor}
            if processor in PRESETS:
                preset = PRESETS[processor]
                formants, first = render.process_48k(
                    original, params={0: preset["alpha"]}
                )
                # Pitch delay varies; retain a generous 100 ms tail rather than
                # fitting alignment to the source or truncating final speech.
                wave, second = render.process_48k(
                    np.pad(formants, (0, 4800)),
                    "pitch_shift",
                    {0: preset["semitones"], 1: 40},
                )
                row["processing"] = {
                    "mcadams": first,
                    "pitch": second,
                    "order": "McAdams then pitch",
                    "tail_ms": 100,
                }
                mode = "fixed_dsp"
            else:
                runtime = quantized if processor == "tvtsyn_int8" else model
                converted = runtime.convert(raw16, speaker)
                if processor == "tvtsyn_int8" and clip == "high_voice":
                    exact_input = np.fromfile(
                        ROOT / "tmp/voice-browser/input.f32", dtype="<f4"
                    )
                    runtime.convert(exact_input, speaker).astype("<f4").tofile(
                        ROOT / "tmp/voice-browser/int8-native.f32"
                    )
                wave = (
                    resample(torch.from_numpy(converted), 16000, 48000).numpy() * 0.25
                )
                mode = (
                    "dynamic_int8_onnx" if processor == "tvtsyn_int8" else "native_onnx"
                )
                row["same_target_control"] = clip == "mid_voice"
            if not np.isfinite(wave).all():
                raise RuntimeError(f"Nonfinite output: {clip}/{processor}")
            row.update(
                peak=float(np.max(np.abs(wave))),
                export_clipped_samples=int(np.count_nonzero(np.abs(wave) >= 1)),
                seconds=len(wave) / 48000,
            )
            results["cases"].append(row)
            cases[clip + ".wav"] = {
                "audio": {
                    "original": original_file,
                    "converted": save_audio(clip, processor, wave, output),
                },
                "context": {
                    "view": "model",
                    "mode": mode,
                    "processor": processor,
                    "build_id": build,
                    "source_id": hashlib.sha256(path.read_bytes()).hexdigest(),
                    "sample": clip,
                    "run_id": results["generated_at"],
                    "case_id": clip,
                },
                "note": "Same-target control: this source is also the target voice; not a successful-disguise test."
                if processor.startswith("tvtsyn") and clip == "mid_voice"
                else "",
            }
        print(f"Prepared {clip}", flush=True)
    (HERE / "results/comparisons.json").write_text(
        json.dumps({"candidates": candidates, "experiment": results}, indent=2) + "\n"
    )
    print(json.dumps(results["quantization"]), flush=True)


if __name__ == "__main__":
    main()
