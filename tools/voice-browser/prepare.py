"""Prepare pinned public input, target embedding and native ONNX reference."""

import hashlib
import json
import subprocess
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
UPSTREAM = "9aa67c0272620caaf43170fe98ec48438e1624e0"
REVISION = "e37063244a413f834fe976c1ba356d2ef37ece6c"
OUT = ROOT / "tmp/voice-browser"


def digest(path):
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def main():
    import numpy as np
    import onnxruntime
    import soundfile as sf
    from tvtsyn_inference import TVTSyn
    from tvtsyn_inference.audio import resample

    repo = ROOT / "tmp/tvtsyn"
    actual = subprocess.check_output(
        ["git", "-C", str(repo), "rev-parse", "HEAD"], text=True
    ).strip()
    if (
        actual != UPSTREAM
        or subprocess.check_output(
            ["git", "-C", str(repo), "diff", "HEAD", "--name-only"], text=True
        ).strip()
    ):
        raise RuntimeError("TVTSyn checkout must be unmodified and match the pin")
    OUT.mkdir(parents=True, exist_ok=True)
    import onnx
    from onnx import TensorProto, helper

    baseline = helper.make_model(
        helper.make_graph(
            [helper.make_node("Identity", ["x"], ["y"])],
            "runtime-baseline",
            [helper.make_tensor_value_info("x", TensorProto.FLOAT, [1])],
            [helper.make_tensor_value_info("y", TensorProto.FLOAT, [1])],
        ),
        opset_imports=[helper.make_opsetid("", 17)],
    )
    baseline.ir_version = 9
    onnx.save(baseline, OUT / "runtime-baseline.onnx")
    begin = time.perf_counter()
    model = TVTSyn.from_pretrained(
        "warisqr007/TVTSyn", revision=REVISION, backend="onnx", threads=4
    )
    setup_seconds = time.perf_counter() - begin
    source = ROOT / "dev/voice_lab/clips/high_voice.wav"
    target = ROOT / "dev/voice_lab/clips/mid_voice.wav"
    speaker = model.encode_speaker(str(target))
    speaker.astype("<f4").tofile(OUT / "speaker.f32")
    x, sr = sf.read(source, dtype="float32")
    x = resample(x, sr)
    x.astype("<f4").tofile(OUT / "input.f32")
    begin = time.perf_counter()
    y = model.convert(x, speaker)
    seconds = time.perf_counter() - begin
    if len(y) != len(x) or not np.isfinite(y).all():
        raise RuntimeError(
            "Native output must be finite and preserve complete input length"
        )
    y.astype("<f4").tofile(OUT / "native.f32")
    sf.write(OUT / "native.wav", y * 0.25, 16000, subtype="PCM_16")
    artifacts = {
        str(p.relative_to(model.root)): digest(p)
        for p in [
            model.root / "config.json",
            model.root / "onnx/tvtsyn_step_100ms.onnx",
            model.root / "onnx/tvtsyn_step_100ms.onnx.json",
        ]
    }
    report = {
        "upstream": UPSTREAM,
        "model_revision": REVISION,
        "artifacts_sha256": artifacts,
        "source_sha256": digest(source),
        "target_sha256": digest(target),
        "speaker_sha256": digest(OUT / "speaker.f32"),
        "root": str(model.root),
        "config": model.config,
        "metadata": model.runtime.metadata,
        "input_samples": len(x),
        "output_samples": len(y),
        "native_ort": onnxruntime.__version__,
        "native_threads": 4,
        "native_setup_seconds": setup_seconds,
        "native_inference_seconds": seconds,
        "native_peak": float(np.max(np.abs(y))),
        "listen_gain": 0.25,
    }
    (OUT / "preparation.json").write_text(json.dumps(report, indent=2) + "\n")
    print(
        f"Native reference: {len(y)} samples in {seconds:.3f}s; peak={report['native_peak']:.3f}"
    )


if __name__ == "__main__":
    main()
