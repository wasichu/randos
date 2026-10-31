"""Native portable references and feature-port checks for the browser experiment."""

import ctypes
import json
import subprocess

import numpy as np
import soundfile as sf
from bootstrap import HERE, OUT, ROOT, digest
from browser_build import BROWSER
from combined_features import combined
from masking import c_dct
from probe import reference
from scipy.signal import resample_poly


def load():
    lib = ctypes.CDLL(str(BROWSER / "fargan.dylib"))
    lib.fg_new.argtypes = [ctypes.c_double, ctypes.c_double]
    for name in ["fg_input", "fg_output", "fg_feature_input", "fg_feature_output"]:
        getattr(lib, name).restype = ctypes.POINTER(ctypes.c_float)
    return lib


def render(lib, x, pitch, scale, packet):
    if lib.fg_new(pitch, scale) != 1:
        raise ValueError("Browser-core native setup failed")
    parts = []
    try:
        for i in range(0, len(x), packet):
            block = x[i : i + packet]
            np.ctypeslib.as_array(lib.fg_input(), shape=(len(block),))[:] = block
            n = lib.fg_process(len(block))
            if n < 0:
                raise ValueError(f"Browser core rejected input: {n}")
            parts.append(np.ctypeslib.as_array(lib.fg_output(), shape=(n,)).copy())
        n = lib.fg_finish()
        if n < 0:
            raise ValueError(f"Browser core rejected drain: {n}")
        parts.append(np.ctypeslib.as_array(lib.fg_output(), shape=(n,)).copy())
        output = np.concatenate(parts)
        if len(output) != len(x) or not np.isfinite(output).all():
            raise ValueError("Incomplete portable native stream")
        return output, {
            "down_input_delay_samples_48k": lib.fg_down_delay(),
            "up_input_delay_samples_16k": lib.fg_up_delay(),
            "delay_scope": "SILK input-domain delay fields, not complete filter/device latency",
            "pitch_bound_skips": lib.fg_skipped(),
        }
    finally:
        lib.fg_close()


def main():
    build = json.loads((BROWSER / "build.json").read_text())
    for path, expected in build["files"].items():
        if digest(ROOT / path) != expected:
            raise ValueError("Browser build changed: " + path)
    native = BROWSER / "native"
    source = BROWSER / "source"
    test = BROWSER / "core-test"
    subprocess.run(
        [
            "clang",
            "-std=c11",
            "-O1",
            "-g",
            "-D_DARWIN_C_SOURCE",
            "-fsanitize=address,undefined",
            "-fno-sanitize-recover=all",
            "-pthread",
            f"-I{native}",
            *[f"-I{source / p}" for p in [".", "include", "dnn", "celt"]],
            HERE / "browser_core.c",
            HERE / "browser_core_test.c",
            native / ".libs/libopus.a",
            "-lm",
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
            raise ValueError("Browser core sanitizer contract failed")
    quality = json.loads((HERE / "results/quality.json").read_text())
    lib = load()
    basis = c_dct(np.eye(18), "browser_basis").astype(float)
    inputs, feature_checks = {}, []
    for clip in [
        "high_voice",
        "mid_voice",
        "low_voice",
        "mencken_wasichu",
        "test_tone",
    ]:
        item = quality["cases"][clip if clip == "test_tone" else clip + ".wav"]
        path = ROOT / (
            "assets/js/voice_lab/test_tone.js"
            if clip == "test_tone"
            else f"dev/voice_lab/clips/{clip}.wav"
        )
        if digest(path) != item["context"]["source_id"]:
            raise ValueError("Accepted source changed")
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
            raw, rate = sf.read(path, dtype="float64")
            if rate != 24000:
                raise ValueError("Expected 24 kHz speech")
            raw = resample_poly(raw, 2, 1)
        x = np.pad((np.pad(raw * 0.25, (0, 4800))).astype("<f4"), (9600, 9600))
        if len(x) % 960:
            raise ValueError("Complete 20 ms frames required")
        input_path = BROWSER / f"input-{clip}.f32"
        x.astype("<f4").tofile(input_path)
        cached = OUT / f"{clip}.features"
        expected = next(r for r in quality["identity"]["checks"] if r["sample"] == clip)
        if digest(cached) != expected["features_sha256"]:
            raise ValueError("Accepted features changed")
        features = np.fromfile(cached, dtype="<f4").reshape(-1, 20)
        for profile, pitch, scale in [("fuller", -1, 0.8), ("brighter", 1, 1.25)]:
            target = combined(features, basis, pitch, scale)
            if lib.fg_new(pitch, scale) != 1:
                raise ValueError("Native feature setup failed")
            error = 0.0
            try:
                for f, wanted in zip(features[20:-20], target[20:-20], strict=True):
                    np.ctypeslib.as_array(lib.fg_feature_input(), shape=(20,))[:] = f
                    if lib.fg_edit() != 1:
                        raise ValueError("Native feature edit failed")
                    got = np.ctypeslib.as_array(lib.fg_feature_output(), shape=(20,))
                    error = max(error, float(np.max(np.abs(got - wanted))))
                if error > 5e-5:
                    raise ValueError("C feature port differs from accepted Python")
            finally:
                lib.fg_close()
            feature_checks.append(
                {"clip": clip, "profile": profile, "max_abs": error, "pass": True}
            )
            y, stats = render(lib, x, pitch, scale, 960)
            partitioned, _ = render(lib, x, pitch, scale, 480)
            if not np.array_equal(y, partitioned):
                raise ValueError("Native packet partition changed output")
            key = clip + "__" + profile
            y.astype("<f4").tofile(BROWSER / f"{key}-fargan.f32")
            spectral = reference(x, pitch, scale).astype("<f4")
            spectral.tofile(BROWSER / f"{key}-spectral.f32")
            inputs[key] = {
                "clip": clip,
                "profile": profile,
                "pitch": pitch,
                "scale": scale,
                "samples": len(x),
                "input": input_path.name,
                "input_sha256": digest(input_path),
                "source_id": digest(path),
                "native": {
                    name: digest(BROWSER / f"{key}-{name}.f32")
                    for name in ["fargan", "spectral"]
                },
                "native_stats": stats,
                "feature_probes": [
                    {"input": features[i].tolist(), "expected": target[i].tolist()}
                    for i in [20, len(features) // 2, len(features) - 21]
                ],
            }
            print(
                f"Prepared portable {key}; C feature max error {error:.3g}", flush=True
            )
    (BROWSER / "inputs.json").write_text(
        json.dumps(
            {
                "inputs": inputs,
                "feature_checks": feature_checks,
                "build_sha256": digest(BROWSER / "build.json"),
                "sources": {
                    str(p.relative_to(ROOT)): digest(p)
                    for p in [
                        HERE / "browser_prepare.py",
                        HERE / "browser_core_test.c",
                        HERE / "combined_features.py",
                    ]
                },
                "scope": "Common 48 kHz float input; FARGAN includes causal SILK 48→16→48 kHz conversions. Fixed 200 ms fixture padding, not live latency.",
            },
            indent=2,
        )
        + "\n"
    )


if __name__ == "__main__":
    main()
