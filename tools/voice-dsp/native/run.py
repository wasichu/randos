"""Bounded native-core experiment, not Rust/TUI call integration. No downloads."""

import argparse
import gzip
import hashlib
import html
import json
import platform
import subprocess
import sys
import time
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
BROWSER = HERE.parent / "browser"
OUT = ROOT / "tmp/voice-dsp/native"
SHARED = ROOT / "tmp/voice-dsp/browser"
RESULTS = HERE.parent / "results"
SETTINGS = {
    "lower_resonance_only": (0, 0.8),
    "lower_resonance_pitch": (-1, 0.8),
    "higher_resonance_only": (0, 1.25),
    "higher_resonance_pitch": (1, 1.25),
}
SOURCES = ["high_voice", "low_voice", "mid_voice", "mencken_wasichu", "test_tone"]
RESEARCH_FILES = [
    HERE / "probe.cpp",
    HERE / "run.py",
    BROWSER / "spectral.cpp",
    BROWSER / "sources.json",
    BROWSER / "run.mjs",
    BROWSER / "worker.mjs",
    BROWSER / "adapters.mjs",
    BROWSER / "page.mjs",
    ROOT / "assets/js/voice_lab/dsp/adapter.js",
    ROOT / "assets/js/randos/voice/dsp_adapter.js",
    ROOT / "assets/js/randos/voice/dsp_bridge.js",
    ROOT / "assets/vendor/voice_dsp/manifest.json",
    ROOT / "assets/vendor/voice_dsp/spectral.mjs",
    ROOT / "assets/vendor/voice_dsp/spectral.wasm",
]


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def atomic(path, data):
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(data, indent=2) + "\n")
    temporary.replace(path)


def command(*args):
    return subprocess.check_output(args, cwd=ROOT, text=True).strip()


def probe(source, output, pitch, scale, seconds=0, binary=None):
    # Never communicate(): it closes stdin before the run finishes. The open
    # pipe owns the C++ worker, including when Python is killed with SIGKILL.
    child = subprocess.Popen(
        [
            str(binary or OUT / "probe"),
            str(source),
            str(output),
            str(pitch),
            str(scale),
            str(seconds),
        ],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        cwd=ROOT,
    )
    try:
        child.wait(timeout=seconds + 15)
        stdout, stderr = child.stdout.read(), child.stderr.read()
        if child.returncode:
            raise RuntimeError(
                f"Native probe exited {child.returncode}: {stderr.decode()}"
            )
        return json.loads(stdout)
    finally:
        child.stdin.close()
        try:
            child.wait(timeout=5)
        except subprocess.TimeoutExpired:
            child.kill()
            child.wait()
        child.stdout.close()
        child.stderr.close()


def prepare():
    OUT.mkdir(parents=True, exist_ok=True)
    subprocess.run(
        [sys.executable, str(BROWSER / "check_vendor.py")], cwd=ROOT, check=True
    )
    pins = json.loads((BROWSER / "sources.json").read_text())
    dependencies = {}
    for name, pin in [
        ("signalsmith-stretch", "stretch"),
        ("signalsmith-linear", "linear"),
    ]:
        path = ROOT / "tmp" / name
        if command("git", "-C", str(path), "rev-parse", "HEAD") != pins[pin]:
            raise ValueError(f"Incorrect pinned checkout: {name}")
        if command(
            "git", "-C", str(path), "status", "--porcelain", "--untracked-files=all"
        ):
            raise ValueError(f"Dirty source checkout: {name}")
        dependencies[name] = pins[pin]
    if (
        SHARED / "include/signalsmith-linear"
    ).resolve() != ROOT / "tmp/signalsmith-linear":
        raise ValueError("Compiler include path differs from pinned linear checkout")
    for name in ["spectral.mjs", "spectral.wasm"]:
        if sha(SHARED / name) != sha(ROOT / "assets/vendor/voice_dsp" / name):
            raise ValueError(
                "Research/browser modules differ from checked vendor modules"
            )
    common = [
        "clang++",
        "-std=c++17",
        "-ffp-contract=off",
        "-pthread",
        "-Wall",
        "-Wextra",
        "-Werror",
        f"-I{ROOT / 'tmp/signalsmith-stretch'}",
        f"-I{SHARED / 'include'}",
        str(HERE / "probe.cpp"),
        str(BROWSER / "spectral.cpp"),
    ]
    release_command = [*common, "-O3", "-o", str(OUT / "probe")]
    subprocess.run(release_command, cwd=ROOT, check=True)
    # The queue/finite-tail path also runs under address/undefined sanitizers.
    sanitizer_command = [
        *common,
        "-O1",
        "-g",
        "-fsanitize=address,undefined",
        "-fno-sanitize-recover=all",
        "-fno-omit-frame-pointer",
        "-o",
        str(OUT / "probe-sanitized"),
    ]
    subprocess.run(sanitizer_command, cwd=ROOT, check=True)
    inputs = json.loads((SHARED / "inputs.json").read_text())
    checks = json.loads((SHARED / "checks.json").read_text())
    cases = {}
    (SHARED / "native-cadence-reference").mkdir(exist_ok=True)
    for source, item in {**{key: inputs[key] for key in SOURCES}, **checks}.items():
        path = SHARED / "input" / f"{source}.f32"
        if sha(path) != item["input_sha256"]:
            raise ValueError("Stale exact input bytes")
        if source in SOURCES:
            origin = ROOT / (
                "assets/js/voice_lab/test_tone.js"
                if source == "test_tone"
                else f"dev/voice_lab/clips/{source}.wav"
            )
            if sha(origin) != item["source_id"]:
                raise ValueError("Stale source recording")
        for setting, (pitch, scale) in SETTINGS.items():
            key = f"{source}__{setting}"
            output = SHARED / "native-cadence-reference" / f"{key}-spectral.f32"
            stats = probe(path, output, pitch, scale)
            samples = np.fromfile(output, dtype="<f4")
            if len(samples) != item["samples"] or not np.isfinite(samples).all():
                raise ValueError("Nonfinite/truncated native output")
            # Same complete input and flush through a sanitized native build.
            sanitized = OUT / "sanitized.f32"
            probe(path, sanitized, pitch, scale, binary=OUT / "probe-sanitized")
            if sha(sanitized) != sha(output):
                raise ValueError("Sanitized/native output differs")
            cases[key] = {
                **item,
                "input_key": source,
                "pitch": pitch,
                "scale": scale,
                "native_sha256": {"spectral": sha(output)},
                "native_stats": stats,
            }
    # EOF ownership regression: closing the starter pipe must stop a paced child.
    with subprocess.Popen(
        [str(OUT / "probe"), str(SHARED / "input/mid_voice.f32"), "-", "0", ".8", "60"],
        stdin=subprocess.PIPE,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    ) as child:
        child.stdin.close()
        if child.wait(timeout=5) != 72:
            raise ValueError("EOF did not terminate native probe")
    # Sanitized paced path also exercises bounded enqueue/dequeue at 20 ms.
    probe(SHARED / "input/mid_voice.f32", "-", -1, 0.8, 1, OUT / "probe-sanitized")
    build = {
        "dependencies": dependencies,
        "compiler": command("clang++", "--version"),
        "compile_commands": [
            [arg.replace(str(ROOT) + "/", "") for arg in args]
            for args in [release_command, sanitizer_command]
        ],
        "binary_sha256": sha(OUT / "probe"),
        "binary_bytes": (OUT / "probe").stat().st_size,
        "binary_gzip_bytes": len(gzip.compress((OUT / "probe").read_bytes(), mtime=0)),
        "dynamic_libraries": command(
            *(["otool", "-L"] if platform.system() == "Darwin" else ["ldd"]),
            str(OUT / "probe"),
        ).replace(str(ROOT) + "/", ""),
        "provenance": {
            str(path.relative_to(ROOT)): sha(path) for path in RESEARCH_FILES
        },
        "sanitized_fixtures": len(cases),
        "stdin_eof_exit_pass": True,
    }
    atomic(SHARED / "native-cadence-inputs.json", cases)
    atomic(SHARED / "native-cadence-build.json", build)
    print(
        f"Native 20 ms ingress: {len(cases)} complete fixtures and sanitizer comparisons; EOF teardown passed",
        flush=True,
    )


def measured_pass(stats):
    return (
        stats["mode"] == "paced"
        and stats["seconds"] == 60
        and stats["elapsed_ms"] >= 60000
        and stats["frame_samples"] == 960
        and stats["batch_samples"] == stats["core_delay_samples"] == 3840
        and stats["queue_capacity_samples"] == 15360
        and stats["prefill_samples"] == 7680
        and stats["input_samples"] == 60 * 48000
        # Last delivered frame starts at the final clock boundary. Delivery
        # counts this frame; it is not completed device playback.
        and stats["delivered_samples"] - 960 + stats["buffer_delay_ms"] * 48
        == 60 * 48000
        and stats["max_input_samples"] <= 3840
        and stats["max_output_samples"] <= stats["queue_capacity_samples"]
        and stats["starvations"] == stats["overflows"] == 0
        and stats["missed_release_periods"] == stats["missed_delivery_periods"] == 0
    )


def measure():
    build = json.loads((SHARED / "native-cadence-build.json").read_text())
    browser = json.loads((RESULTS / "native-cadence-browser.json").read_text())
    if (
        not browser.get("complete")
        or len(browser["cases"]) != 20
        or not browser["speech_tone_parity_pass"]
    ):
        raise ValueError("Complete browser/native candidate parity required")
    if browser["native_build"] != build or sha(OUT / "probe") != build["binary_sha256"]:
        raise ValueError("Stale native build")
    for path, expected in build["provenance"].items():
        if sha(ROOT / path) != expected:
            raise ValueError("Source changed after preparation")
    source = SHARED / "input/mid_voice.f32"
    input_hash = browser["inputs"]["mid_voice__lower_resonance_only"]["input_sha256"]
    if sha(source) != input_hash:
        raise ValueError("Paced input differs from compared fixture")
    for name in ["spectral.mjs", "spectral.wasm"]:
        if browser["assets"]["/build/" + name]["sha256"] != sha(
            ROOT / "assets/vendor/voice_dsp" / name
        ):
            raise ValueError("Compared browser module differs from pinned vendor bytes")
    report = {
        "completed": False,
        "generated_at": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "scope": "Native C++ core with TUI-sized frames. Not Rust FFI, devices, AEC, Opus, WebRTC or working TUI integration. One-machine evidence, not phone qualification or privacy proof.",
        "host": {
            "system": platform.system(),
            "machine": platform.machine(),
            "release": platform.release(),
        },
        "build": build,
        "paced_input_sha256": input_hash,
        "delivery_scope": "Frames delivered at 20 ms clock boundaries, including one starting at 60 s. No device playback. Live stop discards the bounded queue; finite comparisons flush the complete tail.",
        "browser_report_sha256": sha(RESULTS / "native-cadence-browser.json"),
        "speech_tone_pairs": len(browser["cases"]),
        "speech_tone_parity_pass": browser["speech_tone_parity_pass"],
        "boundary_checks": browser["checks"],
        "trials": [],
    }
    try:
        for setting, (pitch, scale) in SETTINGS.items():
            print(f"Independent-clock native minute: {setting}", flush=True)
            stats = probe(source, "-", pitch, scale, 60)
            report["trials"].append(
                {
                    "setting": setting,
                    "pitch": pitch,
                    "scale": scale,
                    "stats": stats,
                    "pass": measured_pass(stats),
                }
            )
            print(json.dumps(report["trials"][-1]), flush=True)
        for path, expected in build["provenance"].items():
            if sha(ROOT / path) != expected:
                raise ValueError("Source changed during measurement")
        if sha(source) != input_hash or sha(OUT / "probe") != build["binary_sha256"]:
            raise ValueError("Paced input or executable changed during measurement")
        report["completed"] = True
        report["native_cadence_pass"] = all(row["pass"] for row in report["trials"])
    finally:
        atomic(RESULTS / "native-cadence.json", report)
        write_html(report)
    if not report["native_cadence_pass"]:
        raise RuntimeError("Native cadence gate failed; inspect the retained report")


def write_html(report):
    boundaries = report["boundary_checks"]
    boundary_pass = sum(row["parity"]["pass"] for row in boundaries)
    rows = "".join(
        f"<tr><td>{html.escape(row['setting'].replace('_', ' '))}</td>"
        f"<td>{row['pitch']:+g}</td><td>×{row['scale']:g}</td>"
        f"<td>{row['stats']['buffer_delay_ms']:g} ms</td>"
        f"<td>{row['stats']['compute_p95_ms']:.2f} / {row['stats']['compute_max_ms']:.2f} ms</td>"
        f"<td>{row['stats']['peak_rss_end_bytes'] / 1048576:.1f} MiB</td>"
        f"<td>{'Passed' if row['pass'] else 'Needs investigation'}</td></tr>"
        for row in report["trials"]
    )
    (OUT / "report.html").write_text(
        '<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width">'
        "<title>Native voice processing experiment</title><style>"
        "body{font:16px/1.6 system-ui;background:#fafaf9;color:#292524;max-width:1100px;margin:48px auto;padding:0 24px}"
        "h1{line-height:1.2}table{border-collapse:collapse;width:100%}th,td{text-align:left;padding:12px;border-bottom:1px solid #d6d3d1}"
        ".table{overflow:auto}strong{color:#0f766e}small{color:#57534e}</style>"
        "<h1>Can the same voice engine keep up natively?</h1>"
        f"<p>Run status: {'Completed' if report['completed'] else 'Incomplete — inspect diagnostic JSON'}.</p>"
        f"<p><strong>{report['speech_tone_pairs']}/20 speech and tone comparisons passed</strong> against the browser. "
        "Four strong-resonance settings; unchanged core; 20 ms input/output frames and 80 ms DSP batches.</p>"
        '<div class="table"><table><thead><tr><th>Candidate</th><th>Pitch (semitones)</th><th>Resonance</th>'
        "<th>Buffer delay</th><th>Compute p95 / max per 20 ms frame</th><th>Whole-process peak RSS</th><th>60 s cadence</th>"
        f"</tr></thead><tbody>{rows}</tbody></table></div>"
        "<p>Delay excludes devices, echo cancellation, Opus, network and playback. RSS includes the fixture, "
        "driver, standard libraries and measurement arrays; it is not the engine’s allocation alone. "
        "Baseline and post-initialization high-water readings are in the JSON report.</p>"
        "<h2>What this settles—and what remains</h2>"
        "<p>This tests the native core and a bounded frame adapter. It does not integrate C++ into Rust or a TUI call. "
        f"{boundary_pass}/{len(boundaries)} silence/impulse comparisons meet the strict tolerance. "
        "Boundary differences remain diagnostic evidence; speech success does not erase them.</p>"
        "<p>Next: choose a safe native integration boundary, then verify both clients in actual calls. "
        "The first release must include browser and TUI together.</p>"
        f"<small>{html.escape(report['generated_at'])} · {html.escape(report['scope'])}</small></html>"
    )


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--measure", action="store_true")
    args = parser.parse_args()
    measure() if args.measure else prepare()
