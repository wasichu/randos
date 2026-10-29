"""Isolated Seed-VC V2 listening probe. Public clips only; never call audio.

Run with the separate environment described in README.md, from any directory.
Upstream inference stays in ignored tmp/seed-vc, outside our Rust/browser code.
"""

import hashlib
import json
import os
import platform
import random
import subprocess
import sys
import time
from datetime import UTC, datetime
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
UPSTREAM = ROOT / "tmp/seed-vc"
OUTPUT = ROOT / "tmp/voice-model"
REPORT = HERE / "results/seed-vc-v2.json"
CLIPS = ["high_voice", "low_voice", "mid_voice", "mencken_wasichu"]
SETTINGS = {
    "diffusion_steps": 30,
    "length_adjust": 1.0,
    "intelligebility_cfg_rate": 0.7,
    "similarity_cfg_rate": 0.7,
    "top_p": 0.9,
    "temperature": 1.0,
    "repetition_penalty": 1.0,
    "convert_style": True,
    "anonymization_only": True,
}
SEED = 20261024
LISTEN_GAIN = 0.25


def digest(path):
    with path.open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def main(*, tone_path=None):
    import numpy as np
    import soundfile as sf
    import torch
    import yaml
    from huggingface_hub import snapshot_download
    from hydra.utils import instantiate
    from omegaconf import OmegaConf

    manifest = json.loads((HERE / "models.json").read_text())
    revision = subprocess.check_output(
        ["git", "-C", str(UPSTREAM), "rev-parse", "HEAD"], text=True
    ).strip()
    if revision != manifest["upstream"]:
        raise RuntimeError("Unexpected upstream revision; use the pinned checkout")
    if subprocess.check_output(
        ["git", "-C", str(UPSTREAM), "diff", "HEAD", "--name-only"], text=True
    ).strip():
        raise RuntimeError(
            "Upstream has local changes; do not silently change the model"
        )
    snapshots = {}
    for repo, entry in manifest["models"].items():
        print(f"Preparing {repo} @ {entry['revision']}", flush=True)
        snapshots[repo] = Path(
            snapshot_download(
                repo,
                revision=entry["revision"],
                allow_patterns=entry["files"],
                local_files_only=tone_path is not None,
            )
        )

    # All constructors below receive local, revision-pinned snapshots. No model
    # code is fetched/executed from Hugging Face (trust_remote_code stays off).
    os.environ["HF_HUB_OFFLINE"] = "1"
    sys.path.insert(0, str(UPSTREAM))
    import hf_utils

    def pinned_model(repo_id, model_filename, config_filename=None):
        checkpoint = str(snapshots[repo_id] / model_filename)
        return (
            (checkpoint, str(snapshots[repo_id] / config_filename))
            if config_filename
            else checkpoint
        )

    hf_utils.load_custom_model_from_hf = pinned_model
    cfg = OmegaConf.create(
        yaml.safe_load((UPSTREAM / "configs/v2/vc_wrapper.yaml").read_text())
    )
    for key in ["content_extractor_narrow", "content_extractor_wide"]:
        cfg[key].tokenizer_name = str(snapshots["openai/whisper-small"])
        cfg[key].ssl_model_name = str(snapshots["facebook/hubert-large-ll60k"])
    cfg.vocoder.pretrained_model_name_or_path = str(
        snapshots["nvidia/bigvgan_v2_22khz_80band_256x"]
    )
    device = torch.device("mps" if torch.backends.mps.is_available() else "cpu")
    dtype = torch.float16 if device.type == "mps" else torch.float32
    torch.set_num_threads(4)
    print(f"Loading Seed-VC V2 on {device}, autocast/cache dtype {dtype}", flush=True)
    started = time.perf_counter()
    model = instantiate(cfg)
    model.load_checkpoints()
    model.to(device).eval()
    model.setup_ar_caches(
        max_batch_size=1, max_seq_len=4096, dtype=dtype, device=device
    )
    if device.type == "mps":
        torch.mps.synchronize()
    load_seconds = time.perf_counter() - started
    OUTPUT.mkdir(parents=True, exist_ok=True)
    REPORT.parent.mkdir(parents=True, exist_ok=True)
    weights = {
        repo: {
            str(p.relative_to(path)): digest(p)
            for p in path.rglob("*")
            if p.is_file() and p.suffix in [".pth", ".pt", ".bin", ".json", ".txt"]
        }
        for repo, path in snapshots.items()
    }
    build_id = hashlib.sha256(
        (HERE / "probe.py").read_bytes()
        + (HERE / "models.json").read_bytes()
        + (HERE / "requirements.lock").read_bytes()
    ).hexdigest()
    report = {
        "model": "Seed-VC V2",
        "generated_at": datetime.now(UTC).isoformat(timespec="seconds"),
        "upstream_revision": revision,
        "manifest": manifest,
        "weights_sha256": weights,
        "build_id": build_id,
        "settings": SETTINGS,
        "seed": SEED,
        "device": str(device),
        "dtype": str(dtype),
        "platform": platform.platform(),
        "torch_version": torch.__version__,
        "load_seconds": load_seconds,
        "listen_gain": LISTEN_GAIN,
        "target": "mid_voice",
        "target_sha256": digest(ROOT / "dev/voice_lab/clips/mid_voice.wav"),
        "results": [],
        "scope": "Four public LibriVox clips; offline whole-clip inference. Not a reconstruction attack, anonymity result, or live/browser latency measurement.",
    }
    report_path = HERE / "results/seed-vc-tone.json" if tone_path else REPORT
    if tone_path:
        report["scope"] = (
            "Synthetic tone diagnostic, not speech or masking-quality evidence."
        )

    def publish():
        pending = report_path.with_suffix(".json.tmp")
        pending.write_text(json.dumps(report, indent=2) + "\n")
        pending.replace(report_path)

    def save(clip, name, audio, rate):
        import io

        content = io.BytesIO()
        sf.write(content, audio * LISTEN_GAIN, rate, format="WAV", subtype="PCM_16")
        raw = content.getvalue()
        name = f"{clip}__{name}__{hashlib.sha256(raw).hexdigest()}.wav"
        target = OUTPUT / name
        if not target.exists():
            pending = target.with_suffix(".pending")
            pending.write_bytes(raw)
            pending.replace(target)
        return name

    for clip in ["test_tone"] if tone_path else CLIPS:
        source = tone_path or ROOT / f"dev/voice_lab/clips/{clip}.wav"
        row = {
            "id": clip,
            "clip": clip,
            "source_sha256": digest(source),
            "status": "running",
        }
        report["results"].append(row)
        publish()
        try:
            random.seed(SEED)
            np.random.seed(SEED)
            torch.manual_seed(SEED)
            start = time.perf_counter()
            result = None
            for _, full in model.convert_voice_with_streaming(
                source_audio_path=str(source),
                target_audio_path=str(ROOT / "dev/voice_lab/clips/mid_voice.wav"),
                device=device,
                dtype=dtype,
                stream_output=True,
                **SETTINGS,
            ):
                if full is not None:
                    result = full
            if device.type == "mps":
                torch.mps.synchronize()
            seconds = time.perf_counter() - start
            if result is None:
                raise RuntimeError("No final waveform returned")
            rate, wave = result
            wave = np.asarray(wave, dtype=np.float32)
            if (
                wave.ndim != 1
                or not len(wave)
                or not np.isfinite(wave).all()
                or np.max(np.abs(wave)) < 1e-5
            ):
                raise RuntimeError("Empty, silent or nonfinite output")
            original, source_rate = sf.read(source, dtype="float32")
            row.update(
                status="ready",
                inference_seconds=seconds,
                input_seconds=len(original) / source_rate,
                output_seconds=len(wave) / rate,
                sample_rate=rate,
                peak=float(np.max(np.abs(wave))),
                samples_at_unit_boundary=int(np.count_nonzero(np.abs(wave) >= 1)),
                listening_clipped_samples=int(
                    np.count_nonzero(np.abs(wave * LISTEN_GAIN) >= 1)
                ),
                audio={
                    "original": save(clip, "original", original, source_rate),
                    "converted": save(clip, "converted", wave, rate),
                },
            )
            print(json.dumps(row), flush=True)
        except Exception as error:
            row.update(status="failed", error=f"{type(error).__name__}: {error}")
            raise
        finally:
            publish()


if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--tone",
        type=Path,
        help="Synthetic tone WAV; writes a separate diagnostic report",
    )
    main(tone_path=parser.parse_args().tone)
