"""Exact inputs and native reference outputs for the Worker screen."""

import ctypes
import json
import subprocess
import sys
from pathlib import Path

import numpy as np
import soundfile as sf
from scipy.signal import resample_poly

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
sys.path.insert(0, str(HERE.parent))
from chunked import chunk_render, digest, world_transform
from probe import SETTINGS

sys.path.insert(0, str(ROOT / "tools/voice-eval"))
from randos_voice_eval import render

OUT = ROOT / "tmp/voice-dsp/browser"


def library(name, pitch, scale):
    lib = ctypes.CDLL(str(OUT / f"{name}.dylib"))
    lib.dsp_new.argtypes = [ctypes.c_double, ctypes.c_double]
    for func in ["dsp_input", "dsp_output"]:
        getattr(lib, func).restype = ctypes.POINTER(ctypes.c_double)
    assert lib.dsp_new(pitch, scale) == 1

    def process(x, flush=False):
        if not flush:
            np.ctypeslib.as_array(lib.dsp_input(), shape=(len(x),))[:] = x
        n = (lib.dsp_flush if flush else lib.dsp_process)(len(x))
        if n < 0:
            raise ValueError("Native DSP failed")
        return np.ctypeslib.as_array(lib.dsp_output(), shape=(n,)).copy()

    return lib, process


def main():
    render.build()
    (OUT / "input").mkdir(exist_ok=True)
    (OUT / "native").mkdir(exist_ok=True)
    cases = {}
    for clip, (pitch, scale) in SETTINGS.items():
        source = ROOT / (
            "assets/js/voice_lab/test_tone.js"
            if clip == "test_tone"
            else f"dev/voice_lab/clips/{clip}.wav"
        )
        if clip == "test_tone":
            result = subprocess.run(
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
            raw = np.frombuffer(result.stdout, dtype="<f4")
        else:
            raw, rate = sf.read(source, dtype="float64")
            assert rate == 24000
            raw = resample_poly(raw, 2, 1)
        # The bytes supplied to native and browser are identical float32 PCM.
        x = np.pad(raw * 0.25, (0, 4800)).astype("<f4")
        x.tofile(OUT / "input" / f"{clip}.f32")
        lib, process = library("world", pitch, scale)
        world, _ = chunk_render(x.astype("float64"), 3840, process)
        accepted, _ = chunk_render(
            x.astype("float64"), 3840, world_transform(pitch, scale)
        )
        relative = float(
            np.linalg.norm(world - accepted) / max(np.linalg.norm(accepted), 1e-12)
        )
        if relative > 0.001 or np.max(np.abs(world - accepted)) > 0.01:
            raise ValueError(
                f"WORLD changed from accepted Python version: {clip} {relative}"
            )
        lib.dsp_close()
        lib, process = library("spectral", pitch, scale)
        il, ol = lib.dsp_input_latency(), lib.dsp_output_latency()
        parts = [process(x[i : i + 3840]) for i in range(0, len(x), 3840)]
        parts += [process(np.zeros(il)), process(np.zeros(ol), True)]
        spectral = np.concatenate(parts)[il + ol : il + ol + len(x)]
        lib.dsp_close()
        mc, _ = render.process_48k(x, "mcadams", {0: 0.9})
        time, _ = render.process_48k(mc, "pitch_shift", {0: pitch, 1: 40})
        for name, y in [("world", world), ("spectral", spectral), ("time", time)]:
            if len(y) != len(x) or not np.isfinite(y).all():
                raise ValueError("Invalid native output")
            y.astype("<f4").tofile(OUT / "native" / f"{clip}-{name}.f32")
        cases[clip] = {
            "pitch": pitch,
            "scale": scale,
            "samples": len(x),
            "source_id": digest(source),
            "input_sha256": digest(OUT / "input" / f"{clip}.f32"),
            "world_python_relative_rms": relative,
            "native_sha256": {
                name: digest(OUT / "native" / f"{clip}-{name}.f32")
                for name in ["world", "spectral", "time"]
            },
        }
        print(f"Native references: {clip}, WORLD agreement {relative:.3g}", flush=True)
    checks = {}
    for label in ["silence", "onset", "ending"]:
        x = np.zeros(8193 + 4800, dtype="<f4")
        if label != "silence":
            x[0 if label == "onset" else 8192] = 0.1
        key = "check_" + label
        x.tofile(OUT / "input" / f"{key}.f32")
        lib, process = library("world", -2, 0.9)
        world, _ = chunk_render(x.astype("float64"), 3840, process)
        lib.dsp_close()
        lib, process = library("spectral", -2, 0.9)
        il, ol = lib.dsp_input_latency(), lib.dsp_output_latency()
        spectral = np.concatenate(
            [process(x[i : i + 3840]) for i in range(0, len(x), 3840)]
            + [process(np.zeros(il)), process(np.zeros(ol), True)]
        )[il + ol : il + ol + len(x)]
        lib.dsp_close()
        mc, _ = render.process_48k(x, "mcadams", {0: 0.9})
        time, _ = render.process_48k(mc, "pitch_shift", {0: -2, 1: 40})
        for name, y in [("world", world), ("spectral", spectral), ("time", time)]:
            if len(y) != len(x) or not np.isfinite(y).all():
                raise ValueError("Invalid boundary fixture")
            y.astype("<f4").tofile(OUT / "native" / f"{key}-{name}.f32")
        checks[key] = {
            "pitch": -2,
            "scale": 0.9,
            "samples": len(x),
            "input_sha256": digest(OUT / "input" / f"{key}.f32"),
            "native_sha256": {
                name: digest(OUT / "native" / f"{key}-{name}.f32")
                for name in ["world", "spectral", "time"]
            },
        }
    (OUT / "checks.json").write_text(json.dumps(checks, indent=2) + "\n")
    (OUT / "native-build.json").write_text(
        json.dumps(
            {
                "renderer": digest(render.BINARY),
                "libraries": {
                    name: digest(OUT / f"{name}.dylib")
                    for name in ["world", "spectral"]
                },
                "prepare": digest(Path(__file__)),
            },
            indent=2,
        )
        + "\n"
    )
    (OUT / "inputs.json").write_text(json.dumps(cases, indent=2) + "\n")


if __name__ == "__main__":
    main()
