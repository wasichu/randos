"""Standalone, locally served listening artifact; no third-party assets."""

import base64
import hashlib
import html
import io
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
HERE = Path(__file__).resolve().parent
OUT = ROOT / "tmp/voice-browser"


def main():
    import numpy as np
    import soundfile as sf

    report = json.loads((HERE / "results/browser.json").read_text())
    candidate = next((run for run in report["runs"] if "comparison" in run), None)
    table = []
    for run in report["runs"]:
        paced = run.get("paced", {})
        steps = paced.get("step_ms", {})
        parity = run.get("comparison")
        cells = [
            run["provider"],
            run["status"],
            f"{parity['max_absolute_error']:.6g}" if parity else "—",
            f"{steps['p95']:.1f} ms" if steps else "—",
            f"{steps['max']:.1f} ms" if steps else "—",
            str(paced.get("steps_over_100ms", "—")),
            f"{paced['max_backlog_ms']:.0f} ms" if paced else "—",
        ]
        table.append(
            "<tr>"
            + "".join(f"<td>{html.escape(cell)}</td>" for cell in cells)
            + "</tr>"
        )
    audio = []
    if candidate:
        original, rate = sf.read(
            ROOT / "dev/voice_lab/clips/high_voice.wav", dtype="float32"
        )
        sources = [
            ("Original · Elsie Selwyn", original, rate),
            (
                "Converted · native ONNX",
                np.fromfile(OUT / "native.f32", dtype="<f4"),
                16000,
            ),
            (
                f"Converted · browser {candidate['provider'].upper()}",
                np.fromfile(OUT / f"{candidate['provider']}-parity.f32", dtype="<f4"),
                16000,
            ),
        ]
        for name, wave, sr in sources:
            stream = io.BytesIO()
            sf.write(stream, wave * 0.25, sr, format="WAV", subtype="PCM_16")
            encoded = base64.b64encode(stream.getvalue()).decode()
            audio.append(
                f'<div><h3>{html.escape(name)}</h3><audio controls preload="metadata" src="data:audio/wav;base64,{encoded}"></audio></div>'
            )
        # Publish immutable A/B artifacts for the main lab. Their context refers
        # to this exact browser run, never to mutable raw probe output paths.
        published = {}
        audio_dir = ROOT / "tmp/voice-model"
        audio_dir.mkdir(parents=True, exist_ok=True)
        for key, (_, wave, sr) in zip(["original", "native", "converted"], sources):
            content = io.BytesIO()
            sf.write(content, wave * 0.25, sr, format="WAV", subtype="PCM_16")
            raw = content.getvalue()
            filename = (
                f"tvtsyn_high_voice__{key}__{hashlib.sha256(raw).hexdigest()}.wav"
            )
            path = audio_dir / filename
            if not path.exists():
                pending = path.with_suffix(".pending")
                pending.write_bytes(raw)
                pending.replace(path)
            published[key] = filename
        identity = json.dumps(
            {
                "graph": report["native"]["artifacts_sha256"],
                "speaker": report["native"]["speaker_sha256"],
                "harness": report["harness_sha256"],
                "provider": candidate["provider"],
            },
            sort_keys=True,
        )
        manifest = {
            "build_id": hashlib.sha256(identity.encode()).hexdigest(),
            "generated_at": report["generated_at"],
            "clip": "high_voice",
            "source_sha256": report["native"]["source_sha256"],
            "provider": candidate["provider"],
            "audio": published,
        }
        (HERE / "results/listening.json").write_text(
            json.dumps(manifest, indent=2) + "\n"
        )
    paced = candidate.get("paced") if candidate else None
    outcome = "Browser conversion needs further work."
    if candidate and candidate["status"] == "complete":
        outcome = "The browser completed real speech conversion and the paced minute."
    metrics = ""
    if paced:
        init = candidate["initialized"]
        memory = candidate["memory"]
        lo = min((p["rss_mib"] for p in memory), default=0)
        hi = max((p["rss_mib"] for p in memory), default=0)
        metrics = f"""<p>First output after capture began: <strong>{paced["first_output_ms"]:.0f} ms</strong>.
        Whole processing step: mean {paced["step_ms"]["mean"]:.1f} ms, p95 {paced["step_ms"]["p95"]:.1f} ms,
        maximum {paced["step_ms"]["max"]:.1f} ms. Input arrives every 100 ms.</p>
        <p>Local asset fetch: {init["asset_fetch_ms"]:.0f} ms; model session setup: {init["setup_ms"]:.0f} ms.
        This was a localhost transfer of a <strong>{init["model_bytes"] / 1e6:.0f} MB</strong> model, not an internet download measurement.</p>
        <p>Approximate Chrome process-tree RSS range: {lo:.0f}–{hi:.0f} MiB. Shared pages can be counted twice;
        this is not isolated model/GPU memory. Fixed model state: {init["state_bytes"] / 1e6:.2f} MB.
        The research probe also retains the minute's generated waveform (~3.84 MB).</p>"""
        if len(memory) > 1:
            begin = memory[0]["time"]
            span = max(1, memory[-1]["time"] - begin)
            points = " ".join(
                f"{20 + 580 * (p['time'] - begin) / span:.1f},{130 - 110 * (p['rss_mib'] - lo) / max(1, hi - lo):.1f}"
                for p in memory
            )
            metrics += f'<figure><svg viewBox="0 0 620 160" role="img" aria-label="Approximate browser process memory over the run"><path d="M20 20V130H600" fill="none" stroke="#a8a29e"/><polyline points="{points}" fill="none" stroke="#0f766e" stroke-width="2"/><text x="20" y="152">Run start</text><text x="530" y="152">Run end</text></svg><figcaption>Approximate process memory; vertical range {lo:.0f}–{hi:.0f} MiB.</figcaption></figure>'
    errors = "".join(
        f"<li><strong>{html.escape(run['provider'])}:</strong> {html.escape(run['error'].splitlines()[0])}</li>"
        for run in report["runs"]
        if run.get("error")
    )
    resources = []
    for path in sorted((HERE / "results").glob("resource-*.json")):
        experiment = json.loads(path.read_text())
        run = experiment["runs"][0]
        stages = {stage["name"]: stage["rss_mib"] for stage in run["stages"]}
        cells = [path.stem.replace("resource-", ""), run["status"]]
        cells += [
            f"{stages[key]:.0f} MiB" if key in stages else "—"
            for key in ["empty_browser", "runtime_only", "model_ready", "after_stream"]
        ]
        cells += [f"{run['paced']['step_ms']['p95']:.1f} ms" if "paced" in run else "—"]
        resources.append(
            "<tr>"
            + "".join(f"<td>{html.escape(cell)}</td>" for cell in cells)
            + "</tr>"
        )
    resource_section = ""
    if resources:
        resource_section = f"""<h2>Download and memory follow-up</h2>
        <div class="scroll"><table><thead><tr><th>Case</th><th>Result</th><th>Empty browser</th><th>Runtime only</th><th>Model ready</th><th>After minute</th><th>Step p95</th></tr></thead><tbody>{"".join(resources)}</tbody></table></div>
        <p>Full4 runs use four WASM threads with isolation headers; full1 uses one thread without them.
        Repeated full4 runs check measurement noise. Values are median snapshots of summed process RSS,
        not exact model allocations. The streamed minute is discarded rather than retained in memory.</p>
        <p>The first dynamic INT8 attempt reduced weights from 360 MB to 199 MB, but the browser/native
        waveform check failed (relative RMS error ~0.52). Its native audio is available in Listen &amp; compare;
        it is not browser-qualified. No paced INT8 performance claim is made.</p>
        <p>Three fixed DSP presets are also in Listen &amp; compare: McAdams α .9 plus pitch −2/+2 semitones,
        and α .85 plus pitch −1. They use the small existing Rust processors, not neural weights.
        The four-sample TVTSyn native comparison uses the mid voice as a same-target control.</p>"""
    recognition_section = ""
    if (HERE / "results/recognition.json").exists():
        recognition = json.loads((HERE / "results/recognition.json").read_text())
        measures = recognition["results"]
        lines = []
        for key, label in [
            ("original", "Original"),
            ("converted_original_references", "TVTSyn vs original references"),
            (
                "converted_matching_transform",
                "TVTSyn vs matching transformed references",
            ),
        ]:
            item = measures[key]
            lines.append(
                f"<tr><td>{label}</td><td>{100 * item['eer']:.1f}%</td><td>{100 * item['identification']:.1f}%</td></tr>"
            )
        recognition_section = f"""<h2>Known-recording recognition probe</h2><div class="scroll"><table><thead><tr><th>Condition</th><th>Verification EER ↑</th><th>Top-1 recognized ↓</th></tr></thead><tbody>{"".join(lines)}</tbody></table></div>
        <p>20 speakers, two enrollment utterances and three different trial utterances per speaker.
        Fixed pretrained ECAPA, no attacker retraining. Whisper word error: original {100 * measures["original_wer"]:.1f}%,
        TVTSyn {100 * measures["converted_wer"]:.1f}%. This is a small recognition/utility probe, not a full VoicePrivacy evaluation.</p>
        <p>Original-voice reconstruction resistance remains untested. Converting back with an original-speaker
        reference would give the attacker information excluded by our recorded-output-only scenario.
        A meaningful learned recovery attack needs paired data from separate training speakers; an arbitrary failed remapping is weak evidence.</p>"""
    content = f"""<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
    <title>TVTSyn browser feasibility</title><link rel="stylesheet" href="/dev/voice-lab/browser-probe/report.css">
    <main><a href="/dev/voice-lab">← Audio lab</a><h1>TVTSyn: does the browser keep up?</h1>
    <p class="lead">{outcome}</p><p>One six-second public LibriVox excerpt, followed by a minute repeating that excerpt at speaking speed.
    No microphone, network inference, speaker-recognition test or recovery attack.</p>
    <div class="scroll"><table><thead><tr><th>Runtime</th><th>Result</th><th>Max difference to native</th><th>Step p95</th><th>Slowest step</th><th>Steps over 100 ms</th><th>Largest input backlog</th></tr></thead><tbody>{"".join(table)}</tbody></table></div>
    {metrics}{resource_section}{recognition_section}<h2>Listen: original → native → browser</h2>
    <p>The native and browser versions use identical model weights, target embedding, initial states, padding, flush and duration.
    The target is the bundled mid-voice reader, Yoganandh T. These are voice conversions, not anonymity results.</p>
    <div class="controls"><button id="compare" {"disabled" if not audio else ""}>▶ Play original → native → browser</button><label><input id="loop" type="checkbox"> Loop comparison</label></div>
    <p id="playback-status" role="status"></p><div class="players">{"".join(audio)}</div>
    <p>All playback uses fixed 0.25 gain for headroom, without loudness matching. Complete clip endings are retained.
    Source: Elsie Selwyn, public-domain LibriVox excerpt (attribution in the lab).</p>
    <h2>What this establishes</h2><p>Only this model, browser and machine were tested. Inference runs in a worker; a separate input clock releases
    chunks every 100 ms without waiting for inference. Timing includes tensor preparation, state replacement and CPU-readable output.
    The paced run resets every state after the unpaced parity run. No audio rendering/capture-device delay is included.</p>
    <h2>Limits and failures</h2><ul>{errors}</ul><p>The WebGPU request used an explicit headless-browser test flag.
    A software adapter does not demonstrate hardware GPU performance. WASM CPU processing is measured separately.</p>
    <p>The 360 MB download and browser memory costs need further work before production consideration. TVTSyn code and weights are
    CC BY-NC 4.0; this is an isolated research probe, not a selected production dependency.</p>
    <p><a href="https://github.com/PSI-TAMU/TVTSyn">TVTSyn authors and source</a> ·
    <a href="https://huggingface.co/warisqr007/TVTSyn">Model and license</a>.</p>
    <p>Generated {html.escape(report["generated_at"])}. Exact revisions, settings and raw measurements:
    <code>tools/voice-browser/results/browser.json</code>. Reproduce with <code>just voice-browser</code>.</p>
    </main><script src="/dev/voice-lab/browser-probe/review.js" defer></script></html>"""
    (OUT / "report.html").write_text(content)
    print(f"Wrote {OUT / 'report.html'}")


if __name__ == "__main__":
    main()
