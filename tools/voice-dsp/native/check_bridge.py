"""Compare the real Rust/FFI core and live frame adapter with saved browser PCM."""

import hashlib
import json
import subprocess
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[3]
REPORT = ROOT / "tools/voice-dsp/results/rust-bridge.json"


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    reference_path = ROOT / "tools/voice-dsp/results/native-cadence-browser.json"
    reference = json.loads(reference_path.read_text())
    if not reference.get("complete") or not reference["speech_tone_parity_pass"]:
        raise ValueError("Completed browser references required")
    for name in ["spectral.mjs", "spectral.wasm"]:
        if (
            sha(ROOT / "assets/vendor/voice_dsp" / name)
            != reference["assets"]["/build/" + name]["sha256"]
        ):
            raise ValueError("Browser reference modules changed")
    binary = ROOT / "target/release/examples/render_signalsmith"
    styles = {
        "lower_resonance_only": 0,
        "lower_resonance_pitch": 1,
        "higher_resonance_only": 2,
        "higher_resonance_pitch": 3,
    }
    voices = {"high_voice", "low_voice", "mid_voice", "mencken_wasichu", "test_tone"}
    boundaries = {"check_silence", "check_onset", "check_ending"}
    expected_inputs = {
        f"{voice}__{style}" for voice in voices | boundaries for style in styles
    }
    if set(reference["inputs"]) != expected_inputs:
        raise ValueError(
            "All five sources and three boundary fixtures required for each style"
        )
    if {row["clip"] for row in reference["cases"]} != {
        f"{voice}__{style}" for voice in voices for style in styles
    }:
        raise ValueError("Twenty complete speech/tone browser references required")
    rows = []
    provenance_files = [
        ROOT / "Cargo.lock",
        ROOT / "Cargo.toml",
        ROOT / "voice-native/Cargo.toml",
        Path(__file__).resolve(),
        ROOT / "vendor/signalsmith/manifest.json",
        *sorted((ROOT / "vendor/signalsmith").rglob("*.h")),
        *sorted((ROOT / "voice-native").rglob("*.rs")),
        ROOT / "voice-native/src/bridge.cpp",
    ]
    provenance = {str(p.relative_to(ROOT)): sha(p) for p in provenance_files}
    report = {
        "completed": False,
        "scope": "Actual safe Rust API and owned C++ boundary versus saved browser PCM; includes the live 20 ms adapter. Finite test rendering only, no devices.",
        "binary_sha256": sha(binary),
        "reference_sha256": sha(reference_path),
        "provenance": provenance,
        "cases": rows,
    }
    try:
        for name, item in reference["inputs"].items():
            source = ROOT / "tmp/voice-dsp/browser/input" / (item["input_key"] + ".f32")
            expected_path = (
                ROOT
                / "tmp/voice-dsp/browser/native-cadence-output"
                / (name + "-spectral.f32")
            )
            expected_row = next(
                row
                for row in reference["cases"] + reference["checks"]
                if row["clip"] == name
            )
            source_bytes, expected_bytes = (
                source.read_bytes(),
                expected_path.read_bytes(),
            )
            if (
                hashlib.sha256(source_bytes).hexdigest() != item["input_sha256"]
                or hashlib.sha256(expected_bytes).hexdigest()
                != expected_row["output_sha256"]
            ):
                raise ValueError("Stale fixture/output PCM")
            expected = np.frombuffer(expected_bytes, dtype="<f4")
            for mode in ["raw", "stream"]:
                result = subprocess.run(
                    [str(binary), str(styles[name.split("__")[1]]), mode],
                    input=source_bytes,
                    capture_output=True,
                    check=True,
                    timeout=15,
                )
                actual = np.frombuffer(result.stdout, dtype="<f4")
                if actual.shape != expected.shape or not np.isfinite(actual).all():
                    raise ValueError("Non-finite/truncated Rust audio")
                delta = actual.astype(np.float64) - expected
                relative = float(
                    np.linalg.norm(delta)
                    / max(np.linalg.norm(expected.astype(np.float64)), 1e-12)
                )
                maximum = float(np.max(np.abs(delta)))
                passed = relative <= 0.001 and maximum <= 0.01
                rows.append(
                    {
                        "case": name,
                        "mode": mode,
                        "boundary": name.startswith("check_"),
                        "relative_rms": relative,
                        "max_abs": maximum,
                        "pass": passed,
                        "input_sha256": item["input_sha256"],
                    }
                )
                print(
                    f"{name}/{mode}: {relative:.3g}, max {maximum:.3g}, {'pass' if passed else 'outside tolerance'}",
                    flush=True,
                )
        if (
            any(sha(ROOT / path) != expected for path, expected in provenance.items())
            or sha(binary) != report["binary_sha256"]
        ):
            raise ValueError("Bridge source/build changed during measurement")
        report["speech_tone_pass"] = all(
            row["pass"] for row in rows if not row["boundary"]
        )
        report["boundary_pass"] = all(row["pass"] for row in rows if row["boundary"])
        report["completed"] = True
    finally:
        REPORT.write_text(json.dumps(report, indent=2) + "\n")
    if not report["speech_tone_pass"]:
        raise RuntimeError(
            "Rust bridge speech/tone parity failed; diagnostics retained"
        )


if __name__ == "__main__":
    main()
