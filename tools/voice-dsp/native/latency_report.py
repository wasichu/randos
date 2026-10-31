"""Local engineering artifact: separate software timing from device unknowns."""

import html
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parents[3]


def main():
    folder = ROOT / "tools/voice-dsp/results"
    native = json.loads((folder / "latency-native.json").read_text())
    browser = json.loads((folder / "latency-browser.json").read_text())
    if not native["complete"] or not browser["complete"]:
        raise ValueError("Measurements incomplete")
    rows = []
    for trial in native["paced"]:
        s = trial["stats"]
        rows.append(
            f"<tr><th>{trial['variant']} · style {trial['style']} · {trial['jitter']}</th><td>{s['additional_frame_offset_ms']}</td><td>{s['compute_mean_ms']:.3f} / {s['compute_p95_ms']:.3f}</td><td>{s['send_equivalent_age_p95_ms']:.1f} / {s['send_equivalent_age_max_ms']:.1f}</td><td>{s['late_completions']}</td></tr>"
        )
    stress = []
    for trial in browser["finite"]:
        if not trial.get("stress"):
            continue
        result = trial["result"]
        status = (
            html.escape(result["fault"]["message"])
            if "fault" in result
            else "Survived this trial"
        )
        stress.append(
            f"<tr><th>{trial['jitter_ms']} ms stall</th><td>{trial['prefillSamples'] / 48:g} ms prefill</td><td>{status}</td></tr>"
        )
    callbacks = []
    for trial in browser["paced"]:
        r = trial["result"]
        items = r["rows"]
        delay = (
            next(s["delaySamples"] for s in items if s["delaySamples"] is not None) / 48
        )
        callbacks.append(
            f"<tr><th>{trial['prefillSamples'] / 48:g} ms prefill</th><td>{delay:g} ms</td><td>{min(s['minBufferedSamples'] for s in items) / 48:g} ms</td><td>{max(s['computeMaxMs'] for s in items):.2f} ms</td><td>{'Closed' if r['closed'] else 'NOT CLOSED'}</td></tr>"
        )
    output = ROOT / "tmp/voice-latency"
    output.mkdir(exist_ok=True)
    page = (
        """<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>Signalsmith latency experiment</title><link rel="stylesheet" href="report.css"><main><h1>Where voice-masking delay goes</h1><p>The DSP algorithm and presets stay fixed. This experiment changes only output prefill: 160 → 80 ms. All audio comes from public/generated fixtures; no microphone, speaker or remote relay is used.</p><section class="cards"><article><h2>Native: 80 ms less software buffering</h2><p>Measured frame offset: <strong>220 → 140 ms</strong>.</p><meter min="0" max="300" value="220">220 ms</meter><meter min="0" max="300" value="140">140 ms</meter><p>All four styles × five sources have byte-identical aligned PCM against the shipping baseline, including tails. Invalid input stays fail-closed and reset erases queued speech.</p></article><article><h2>Browser: keep its current buffer</h2><p>Callback offset: <strong>240 → 160 ms</strong>, but the shorter buffer starved under a 12 ms Worker stall. The current buffer survived 45 ms; both failed at 100 ms.</p><p>The AudioWorklet consumes independently of its Worker. The native capture → process → send loop is synchronous: extra native DSP prefill cannot absorb an OS stall in that same sender.</p></article></section><h2>Separate the clocks</h2><ul><li>The unchanged core reports 80 ms sample delay (analysis/output latency). Core delay, batching and prefill overlap; do not add these labels as serial delays.</li><li>Native complete input frames arrive every 20 ms. Nominal first frame delivery is 240 → 160 ms from the start; subtracting the first capture frame gives 220 → 140 ms additional offset. Real capture-timestamp-to-send-equivalent age is measured below.</li><li>Browser callback offsets use the AudioContext sample clock, not the native returned-frame array clock. They exclude hardware and network.</li><li>Processing is sub-millisecond on average here. It is not the main source of the hundreds of milliseconds of buffering.</li></ul><h2>Native independent capture pacing</h2><p>Fresh processes, two opposing pitch/resonance styles, 60 s ordinary runs and 6 s controlled stalls. Producer timestamps remain attached to the original captures; late catch-up frames are counted, not relabeled on-time. Phase stress injects 12 ms pauses; bursts inject two 35 ms pauses. Small count differences do not establish that either buffer fixes OS scheduling.</p><div class="table"><table><thead><tr><th>Trial</th><th>Offset (ms)</th><th>20 ms call compute mean / p95 (ms)</th><th>Capture → send age p95 / max (ms)</th><th>Late completions</th></tr></thead><tbody>"""
        + "".join(rows)
        + """</tbody></table></div><h2>Browser real callbacks</h2><p>Both prefill settings use the same shared production bridge class through its capture-enabled lab subclass, with the same core/configuration. Fixture callback output matches the offline Worker reference. The minute runs retain statistics, not a minute of audio.</p><div class="table"><table><thead><tr><th>Setting</th><th>Callback offset</th><th>Minimum queue after callback</th><th>Maximum 80 ms block compute</th><th>Teardown</th></tr></thead><tbody>"""
        + "".join(callbacks)
        + """</tbody></table></div><h2>Browser falsification: one Worker stall after startup</h2><div class="table"><table><thead><tr><th>Injected delay</th><th>Buffer</th><th>Observed result</th></tr></thead><tbody>"""
        + "".join(stress)
        + """</tbody></table></div><h2>What this does not measure</h2><p>Physical capture/playback buffers, AEC, sample-rate conversion on actual devices, Opus/network/remote playout and acoustic mouth-to-ear delay are not measured here. The pre-change helper's sine → Opus → null baseline reports internal estimates of 26.5 ms unmasked and 246.5 ms masked (220 ms configured offset). Its device fields are zero because no devices are open; those numbers are not acoustic measurements.</p><p>The local native change uses one batch of prefill and the derived alignment constant; the browser default remains unchanged. Real muted/fake-RTP call checks and a manual device check are release gates. Browser defaults stay unchanged. No new API, style, algorithm, model or buffering system is proposed.</p></main></html>"""
    )
    (output / "report.html").write_text(page)
    (output / "report.css").write_text(
        "body{margin:0;background:#fafaf9;color:#292524;font:16px system-ui}main{max-width:1120px;margin:auto;padding:28px}h1{letter-spacing:-.04em}h2{font-size:1.15rem}p,li{line-height:1.55;max-width:95ch}li{margin:10px 0}.cards{display:grid;grid-template-columns:1fr 1fr;gap:16px}article{padding:18px;background:white;border:1px solid #d6d3d1;border-radius:12px}meter{display:block;width:100%;height:22px}.table{overflow:auto}table{border-collapse:collapse;font-size:.85rem;width:100%}th,td{text-align:left;border-bottom:1px solid #d6d3d1;padding:10px}h2{margin-top:26px}@media(max-width:650px){.cards{grid-template-columns:1fr}main{padding:18px}}"
    )
    print(output / "report.html")


if __name__ == "__main__":
    main()
