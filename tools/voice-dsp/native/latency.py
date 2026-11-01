"""Prefill-only experiment on disposable copies; shipping core and defaults stay put."""

import argparse
import hashlib
import json
import platform
import re
import shutil
import subprocess
import sys
from datetime import UTC, datetime
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
OUT = ROOT / "tmp/voice-latency/native"
SHARED = ROOT / "tmp/voice-dsp/browser"
RESULT = HERE.parent / "results/latency-native.json"


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def run(binary, style, source, out, seconds=0, jitter="none"):
    with subprocess.Popen(
        [binary, str(style), source, out, str(seconds), jitter],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    ) as child:
        try:
            status = child.wait(timeout=seconds + 15)
            stdout, stderr = child.stdout.read(), child.stderr.read()
            if status:
                raise ValueError(
                    f"Native latency probe failed ({status}): {stderr.decode()}"
                )
            return json.loads(stdout)
        finally:
            child.stdin.close()
            try:
                child.wait(timeout=5)
            except subprocess.TimeoutExpired:
                child.kill()
                child.wait()


def build():
    OUT.mkdir(parents=True, exist_ok=True)
    subprocess.run(
        [sys.executable, HERE.parent / "browser/check_vendor.py"], cwd=ROOT, check=True
    )
    messages = subprocess.check_output(
        [
            "cargo",
            "build",
            "--offline",
            "--release",
            "-p",
            "randos_voice_native",
            "--message-format=json",
        ],
        cwd=ROOT,
        text=True,
    )
    actual = None
    for line in messages.splitlines():
        item = json.loads(line)
        if (
            item.get("reason") == "compiler-artifact"
            and item["target"]["name"] == "randos_voice_native"
        ):
            actual = next(Path(p) for p in item["filenames"] if p.endswith(".rlib"))
    if actual is None:
        raise ValueError("Shipping library artifact not found")
    archive = OUT / "librandos_signalsmith.a"
    args = [
        "clang++",
        "-O3",
        "-std=c++17",
        "-ffp-contract=off",
        "-fPIC",
        f"-I{ROOT / 'vendor/signalsmith/stretch'}",
        f"-I{ROOT / 'vendor/signalsmith'}",
        "-c",
        ROOT / "voice-native/src/bridge.cpp",
        "-o",
        OUT / "bridge.o",
    ]
    subprocess.run(args, check=True)
    subprocess.run(["ar", "rcs", archive, OUT / "bridge.o"], check=True)
    original = (ROOT / "voice-native/src/lib.rs").read_text()
    anchor = "    pub fn new(style: Style) -> Result<Self, Error> {"
    prefill_line = re.findall(r"const PREFILL: usize = (?:7680|3840|BATCH);", original)
    if original.count(anchor) != 1 or len(prefill_line) != 1:
        raise ValueError("Research copy anchors changed")
    binaries = {}
    for name, prefill in [("shipping", 7680), ("baseline", 7680), ("short", 3840)]:
        folder = OUT / name
        folder.mkdir(exist_ok=True)
        lib = actual
        if name != "shipping":
            text = original.replace(
                prefill_line[0], f"const PREFILL: usize = {prefill};"
            )
            text = text.replace(
                anchor,
                "    pub fn research_state(&self) -> (usize, usize, bool) { (self.fill, self.length, self.primed) }\n"
                + anchor,
            )
            (folder / "lib.rs").write_text(text)
            shutil.copyfile(ROOT / "voice-native/src/ffi.rs", folder / "ffi.rs")
            lib = folder / "librandos_voice_native.rlib"
            subprocess.run(
                [
                    "rustc",
                    "--edition=2024",
                    "-O",
                    "--crate-type=rlib",
                    "--crate-name=randos_voice_native",
                    folder / "lib.rs",
                    "-L",
                    f"native={OUT}",
                    "-lstatic=randos_signalsmith",
                    "-lc++",
                    "-o",
                    lib,
                ],
                check=True,
            )
        binary = folder / "probe"
        subprocess.run(
            [
                "rustc",
                "--edition=2024",
                "-O",
                "-Clto",
                *(["--cfg", "research_copy"] if name != "shipping" else []),
                HERE / "latency_probe.rs",
                "--extern",
                f"randos_voice_native={lib}",
                "-L",
                f"dependency={ROOT / 'target/release/deps'}",
                "-L",
                f"native={OUT}",
                "-o",
                binary,
            ],
            check=True,
        )
        # Explicit EOF ownership, including a process stopped while its parent dies.
        child = subprocess.Popen(
            [
                binary,
                "0",
                SHARED / "input/mid_voice.f32",
                OUT / "eof-unused",
                "60",
                "none",
            ],
            stdin=subprocess.PIPE,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )
        child.stdin.close()
        try:
            if child.wait(timeout=5) != 72:
                raise ValueError("Probe outlived control pipe")
        finally:
            if child.poll() is None:
                child.kill()
                child.wait()
        binaries[name] = binary
    paths = [
        HERE / "latency.py",
        HERE / "latency_probe.rs",
        ROOT / "voice-native/src/lib.rs",
        ROOT / "voice-native/src/ffi.rs",
        ROOT / "voice-native/src/bridge.cpp",
        ROOT / "vendor/signalsmith/manifest.json",
        actual,
        archive,
        *binaries.values(),
        *[OUT / k / "lib.rs" for k in ["baseline", "short"]],
    ]
    return binaries, {str(p.relative_to(ROOT)): sha(p) for p in paths}


def main():
    global OUT
    parser = argparse.ArgumentParser()
    parser.add_argument("--finite-only", action="store_true")
    args = parser.parse_args()
    if args.finite_only:
        OUT = ROOT / "tmp/voice-latency/native-validation"
    binaries, provenance = build()
    report = {
        "generated_at": datetime.now(UTC).isoformat(),
        "scope": "Actual safe Rust Masker code in hash-guarded copies. Only prefill differs; core/window/hop unchanged. Independent synthetic capture producer, synchronous worker/send-equivalent consumer, no audio device, AEC, codec, network or playback measurement.",
        "host": {"system": platform.system(), "machine": platform.machine()},
        "toolchain": {
            name: subprocess.check_output(command, text=True).splitlines()[0]
            for name, command in [
                ("rust", ["rustc", "--version"]),
                ("cpp", ["clang++", "--version"]),
            ]
        },
        "finite_only": args.finite_only,
        "provenance": provenance,
        "cases": [],
        "paced": [],
        "complete": False,
    }
    accepted = ROOT / "tools/voice-dsp/results/engine-comparison-probe.json"
    inputs = json.loads(accepted.read_text())["inputs"]
    report["accepted_inputs_sha256"] = sha(accepted)
    for clip, c in inputs.items():
        source = SHARED / "input" / f"{clip}.f32"
        if sha(source) != c["input_sha256"]:
            raise ValueError("Input cache changed")
        for style in range(4):
            outputs = {}
            stats = {}
            for name, binary in binaries.items():
                path = OUT / f"{clip}-{style}-{name}.f32"
                stats[name] = run(binary, style, source, path)
                outputs[name] = np.fromfile(path, dtype="<f4")
            if not np.array_equal(outputs["shipping"], outputs["baseline"]):
                raise ValueError("Research baseline differs from shipping Masker")
            if not np.array_equal(outputs["baseline"], outputs["short"]):
                raise ValueError("Prefill-only change altered aligned audio")
            if len(outputs["short"]) != c["samples"]:
                raise ValueError("Finite tail truncated")
            report["cases"].append(
                {
                    "clip": clip,
                    "style": style,
                    "input_sha256": sha(source),
                    "output_sha256": sha(OUT / f"{clip}-{style}-short.f32"),
                    "shipping_baseline_exact": True,
                    "short_baseline_exact": True,
                    "stats": stats,
                }
            )
        print(
            f"{clip}: all4styles match shipping exactly after measured offsets",
            flush=True,
        )
    if not args.finite_only:
        for style in [1, 3]:
            for name in ["baseline", "short"]:
                for jitter, seconds in [("none", 60), ("phases", 6), ("bursts", 6)]:
                    stats = run(
                        binaries[name],
                        style,
                        SHARED / "input/mid_voice.f32",
                        OUT / "discarded",
                        seconds,
                        jitter,
                    )
                    report["paced"].append(
                        {
                            "variant": name,
                            "style": style,
                            "seconds": seconds,
                            "jitter": jitter,
                            "stats": stats,
                        }
                    )
                    print(
                        f"{name}/style{style}/{jitter}: offset {stats['additional_frame_offset_ms']}ms, compute p95 {stats['compute_p95_ms']:.3f}ms, late {stats['late_completions']}, capture backlog {stats['capture_backlog_max_ms']:.1f}ms",
                        flush=True,
                    )
    for path, wanted in provenance.items():
        if sha(ROOT / path) != wanted:
            raise ValueError("Source/build changed during measurement")
    report["complete"] = True
    destination = (
        RESULT.with_name("latency-native-validation.json")
        if args.finite_only
        else RESULT
    )
    destination.write_text(json.dumps(report, indent=2) + "\n")


if __name__ == "__main__":
    main()
