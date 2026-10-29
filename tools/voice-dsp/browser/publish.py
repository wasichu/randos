"""Publish only a complete parity-checked browser experiment; preserve old cases."""

import hashlib
import html
import json
import os
import shutil
import sys
import tempfile
from pathlib import Path

import numpy as np

HERE = Path(__file__).resolve().parent
ROOT = HERE.parents[2]
sys.path.insert(0, str(ROOT / "tools/voice-browser"))
from sound_quality import match_levels

sys.path.insert(0, str(ROOT / "tools/voice-eval"))
from randos_voice_eval.reconstruction import save_audio

LABELS = {
    "world": "Browser DSP · WORLD pitch + resonance",
    "spectral": "Browser DSP · Signalsmith pitch + resonance",
    "time": "Browser DSP · McAdams + delay-line pitch",
}
DESCRIPTIONS = {
    "world": "WORLD synthesis resets in bounded windows: 80 ms output, 80 ms past, 20 ms overlap, 40 ms future.",
    "spectral": "Stateful Signalsmith phase vocoder: 80 ms analysis window, 20 ms interval, independent resonance scaling.",
    "time": "Stateful McAdams α 0.9, followed by delay-line pitch with a 40 ms window. This is our existing lightweight reference.",
}


def atomic_json(path, value):
    with tempfile.NamedTemporaryFile(
        mode="w", dir=path.parent, delete=False
    ) as pending:
        json.dump(value, pending, indent=2)
        pending.write("\n")
    os.replace(pending.name, path)


def main():
    folder = ROOT / "tmp/voice-dsp/browser"
    report_path = HERE.parent / "results/browser-probe.json"
    report = json.loads(report_path.read_text())
    if (
        not report.get("complete")
        or len(report["cases"]) != 15
        or len(report["checks"]) != 9
        or len(report["paced"]) != 3
        or not all(case["parity"]["pass"] for case in report["cases"])
    ):
        raise ValueError("A complete successful browser screen is required")
    failures = [row for row in report["checks"] if not row["parity"]["pass"]]
    diagnostic_rows = []
    for row in failures:
        clip, name = row["clip"], row["name"]
        actual = np.fromfile(folder / f"{clip}-{name}.f32", dtype="<f4").astype(
            "float64"
        )
        reference = np.fromfile(
            folder / "native" / f"{clip}-{name}.f32", dtype="<f4"
        ).astype("float64")
        absolute_rms = float(np.sqrt(np.mean((actual - reference) ** 2)))
        diagnostic_rows.append(
            f"Signalsmith {clip.removeprefix('check_')} impulse: relative RMS {row['parity']['relative_rms']:.4g}, absolute RMS {absolute_rms:.4g}, max absolute {row['parity']['max_abs']:.4g}."
        )
    diagnostics = " ".join(diagnostic_rows)
    build = hashlib.sha256(report_path.read_bytes()).hexdigest()
    candidates = {"browser_" + name: {} for name in LABELS}
    for clip, case in report["inputs"].items():
        source = ROOT / (
            "assets/js/voice_lab/test_tone.js"
            if clip == "test_tone"
            else f"dev/voice_lab/clips/{clip}.wav"
        )
        if hashlib.sha256(source.read_bytes()).hexdigest() != case["source_id"]:
            raise ValueError("Source changed since probe")
        if (
            hashlib.sha256((folder / "input" / f"{clip}.f32").read_bytes()).hexdigest()
            != case["input_sha256"]
        ):
            raise ValueError("Input bytes changed since probe")
        for name in LABELS:
            expected = next(
                row["output_sha256"]
                for row in report["cases"]
                if row["clip"] == clip and row["name"] == name
            )
            if (
                hashlib.sha256((folder / f"{clip}-{name}.f32").read_bytes()).hexdigest()
                != expected
            ):
                raise ValueError("Browser output changed since probe")
        waves = {"original": np.fromfile(folder / "input" / f"{clip}.f32", dtype="<f4")}
        waves.update(
            {
                name: np.fromfile(folder / f"{clip}-{name}.f32", dtype="<f4")
                for name in LABELS
            }
        )
        if any(len(y) != case["samples"] for y in waves.values()):
            raise ValueError("Incomplete output")
        waves, gains = match_levels(waves)
        files = {
            name: save_audio(clip, "browser_dsp_" + name, y, ROOT / "tmp/voice-model")
            for name, y in waves.items()
        }
        for name in LABELS:
            candidates["browser_" + name][
                clip if clip == "test_tone" else clip + ".wav"
            ] = {
                "audio": {"original": files["original"], "converted": files[name]},
                "description": DESCRIPTIONS[name],
                "note": f"Actual browser Worker output. Pitch {case['pitch']:+d} semitones; "
                + (
                    f"resonance scale ×{case['scale']:.1f}. "
                    if name != "time"
                    else "McAdams α 0.9. "
                )
                + "No trained weights. RMS matched with shared headroom; original recording on the left. A one-minute paced CPU test is a feasibility screen, not call integration or a privacy guarantee.",
                "level_matched": True,
                "gains": gains,
                "context": {
                    "view": "model",
                    "mode": "browser_dsp",
                    "processor": "browser_" + name,
                    "build_id": build,
                    "source_id": case["source_id"],
                    "sample": clip,
                    "case_id": clip,
                    "run_id": report["generated_at"],
                },
            }
    for name in {row["name"] for row in failures}:
        for item in candidates["browser_" + name].values():
            item["note"] += (
                " Boundary diagnostic: strict native/browser waveform parity failed for a synthetic impulse. Speech/tone checks passed; this candidate remains an experimental audition, not qualified for arbitrary inputs. See the DSP report."
            )
    atomic_json(
        HERE.parent / "results/browser-listening.json",
        {"candidates": candidates, "experiment_sha256": build},
    )
    rows = []
    for item in report["paced"]:
        name, s = item["name"], item["stats"]
        assets = (
            ["/rust.wasm"]
            if name == "time"
            else [f"/build/{name}.wasm", f"/build/{name}.mjs"]
        )
        size = sum(report["assets"][x]["bytes"] for x in assets)
        compressed = sum(report["assets"][x]["brotli_bytes"] for x in assets)
        compute = np.array(s["compute_ms"])
        rows.append(
            f"<tr><th>{html.escape(LABELS[name])}</th><td>{size / 1024:.0f} / {compressed / 1024:.0f} KiB</td><td>{s['setup_ms']:.0f} ms</td><td>{s['required_playout_ms']:.0f} ms</td><td>{np.percentile(compute, 95):.1f} / {compute.max():.1f} ms</td><td>{s['max_queue_samples'] / 48:.0f} ms</td><td>{s['memory_start'] / 1048576:.0f} → {s['memory_end'] / 1048576:.0f} MiB</td><td>{s['chrome_tree_peak_delta_mib']:.0f} MiB</td></tr>"
        )
    browser = html.escape(report["browser"]["product"])
    document = f"""<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><title>Browser DSP experiment</title><link rel="stylesheet" href="/dev/voice-lab/browser-probe/report.css"><main><h1>Three DSP approaches in the browser</h1><p><a href="/dev/voice-lab">Back to Listen &amp; compare</a> · choose Browser DSP to listen and leave feedback.</p><p>Four public voices and a test tone; all 15 speech/tone browser/native waveform checks passed. These use no trained model weights.</p><p><strong>Boundary diagnostics:</strong> {html.escape(diagnostics or "All nine boundary waveform checks passed.")} These use the unchanged .001 relative / .01 absolute thresholds. Failed checks are retained, not waived as passing. The affected candidate is offered for listening only; the numerical cause is unresolved.</p><div class="scroll"><table><thead><tr><th>Approach</th><th>Assets raw / Brotli</th><th>Local setup</th><th>Required output playout</th><th>Compute p95 / max</th><th>Max pending Worker input</th><th>WASM memory capacity</th><th>Peak Chrome RSS increase</th></tr></thead><tbody>{"".join(rows)}</tbody></table></div><h2>What these numbers mean</h2><p>Each approach receives independently paced 80 ms blocks for one minute, repeating the mid-voice clip. A block becomes available only when its final sample would arrive. Required output playout is the worst output arrival time minus its input sample position; it includes buffering, scheduling and computation. Pending Worker input includes the currently active block, so one 80 ms block is expected even without growing backlog. McAdams has its known fixed delay aligned; the pitch shifter also has variable acoustic delay, which this emission metric does not measure.</p><p>WASM memory is allocated linear memory capacity, not total browser RAM. Chrome RSS is an approximate process-tree sum sampled every 500 ms, with shared pages potentially counted more than once. Its increase is relative to the preceding page state, after other experiments; allocator retention makes it unsuitable for precise per-algorithm memory comparisons. No full minute of output is retained.</p><p>Assets include the algorithm module and its generated loader (the Rust reference reuses one module twice). Brotli sizes are offline compression estimates, not measured network transfers; harness and app JavaScript are excluded. Local setup includes worker creation, localhost fetch, compilation and DSP initialization, not an internet download.</p><p>This tests a dedicated Worker on this machine ({browser}), not AudioWorklet deadlines, microphone capture, speaker output, network delay, mobile performance or long calls. Whole-clip RMS matching is used only for listening. There is no claim of resistance to recognition or recovery.</p><h2>Listen before choosing an implementation</h2><p>WORLD rebuilds the voice in overlapping short windows. Signalsmith continuously transforms its spectrum. McAdams plus delay-line pitch uses our existing lightweight processors. Compare clarity, nasal or metallic color, warbling and resemblance to the raw original. The owner’s listening feedback determines the next experiment.</p><p>Generated {html.escape(report["generated_at"])}. Full provenance and measurements: tools/voice-dsp/results/browser-probe.json.</p></main></html>"""
    destination = ROOT / "tmp/voice-browser/dsp.html"
    destination.parent.mkdir(parents=True, exist_ok=True)
    destination.write_text(document)
    shutil.copyfile(
        ROOT / "tools/voice-browser/report.css", destination.parent / "report.css"
    )
    print("Published 15 browser listening pairs and DSP report")


if __name__ == "__main__":
    main()
