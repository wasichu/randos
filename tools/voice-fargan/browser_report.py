"""Local listening artifact for actual browser outputs; never changes owner reviews."""

import html
import json

import numpy as np
import soundfile as sf
from bootstrap import HERE, digest
from browser_build import BROWSER


def main():
    report = json.loads((HERE / "results/browser.json").read_text())
    if not report["complete"]:
        raise ValueError("Browser screen is incomplete")
    prepared = BROWSER / "inputs.json"
    if digest(prepared) != report["inputs_sha256"]:
        raise ValueError("Stale listening inputs")
    inputs = json.loads(prepared.read_text())["inputs"]
    rows = []
    assets = []
    for name in ["fargan-core", "spectral"]:
        parts = [report["assets"][f"/{name}.{ext}"] for ext in ["mjs", "wasm"]]
        assets.append(
            f"<tr><th>{name}</th><td>{sum(x['bytes'] for x in parts) / 1024:.1f}</td><td>{sum(x['gzip_bytes'] for x in parts) / 1024:.1f}</td><td>{sum(x['brotli_bytes'] for x in parts) / 1024:.1f}</td></tr>"
        )
    for item in report["paced"]:
        s = item["stats"]
        c = s["compute_summary"]
        rows.append(
            f"<tr><th>{item['name']} · {item['profile']}</th><td>{c['mean']:.2f} / {c['p95']:.2f} / {c['max']:.2f}</td><td>{s['memory_end'] / 1048576:.1f}</td><td>{s['required_playout_ms']:.1f}</td><td>{s['starved_samples']}</td></tr>"
        )
    sections = []
    for clip, label in [
        ("high_voice", "High voice"),
        ("mid_voice", "Mid voice"),
        ("low_voice", "Low voice"),
        ("mencken_wasichu", "Wasichu"),
        ("test_tone", "Diagnostic tone"),
    ]:
        profile = (
            "fuller" if clip in ["high_voice", "mid_voice", "test_tone"] else "brighter"
        )
        key = clip + "__" + profile
        c = inputs[key]
        arrays = {"original": np.fromfile(BROWSER / c["input"], dtype="<f4")}
        for name in ["fargan", "spectral"]:
            p = BROWSER / f"{key}-{name}-browser.f32"
            wanted = next(
                x["output_sha256"]
                for x in report["cases"]
                if x["key"] == key and x["name"] == name
            )
            if digest(p) != wanted:
                raise ValueError("Browser audio changed")
            arrays[name] = np.fromfile(p, dtype="<f4")
        native = BROWSER / f"{key}-fargan.f32"
        if digest(native) != c["native"]["fargan"]:
            raise ValueError("Portable native audio changed")
        arrays["native"] = np.fromfile(native, dtype="<f4")
        # Remove only fixed fixture padding. Equalize RMS with shared peak headroom.
        cropped = {name: x[9600:-9600] for name, x in arrays.items()}
        leveled = {
            name: x * (0.05 / max(float(np.sqrt(np.mean(x.astype(float) ** 2))), 1e-12))
            for name, x in cropped.items()
        }
        peak = max(float(np.max(np.abs(x))) for x in leveled.values())
        gain = min(1, 0.85 / max(peak, 1e-12))
        cards = []
        for name, title in [
            ("original", "Original · 48 kHz"),
            ("fargan", "Browser FARGAN"),
            ("spectral", "Browser Signalsmith"),
            ("native", "Portable native FARGAN"),
        ]:
            filename = f"audition-{key}-{name}.wav"
            sf.write(BROWSER / filename, leveled[name] * gain, 48000, subtype="PCM_16")
            cards.append(
                f'<article><h3>{title}</h3><audio controls preload="none" src="{filename}"></audio></article>'
            )
        sections.append(
            f'<section><h2>{label} · {profile}</h2><div class="clips">'
            + "".join(cards)
            + "</div></section>"
        )
    payload = (
        """<!doctype html><html lang="en"><meta charset="utf-8"><meta name="viewport" content="width=device-width"><title>FARGAN browser feasibility</title><link rel="stylesheet" href="report.css"><main><h1>FARGAN in the browser</h1><p>A first Worker feasibility screen, not a live-call qualification. No microphone, upload or remote inference.</p><h2>Measured on this Mac</h2><div class="table"><table><thead><tr><th>Engine / preset</th><th>20 ms packet compute: mean / p95 / max (ms)</th><th>WASM memory (MiB)</th><th>Required availability (ms)</th><th>Starved samples at simulated 200 ms prefill</th></tr></thead><tbody>"""
        + "".join(rows)
        + """</tbody></table></div><p>Independent browser timers simulate input and playout. Delays exclude devices, WebRTC and AudioWorklet scheduling. Signalsmith stays at 48 kHz; FARGAN includes causal 48→16→48 kHz conversion and cannot restore frequencies lost above 8 kHz.</p><h2>Listen to the actual browser output</h2><p>Browser FARGAN differs numerically from portable native FARGAN. These new recordings need listening approval; earlier native ratings do not qualify them. The native control below uses the same new causal resamplers, not the earlier offline experiment. Volume is matched within each voice, with shared peak headroom. Play one clip at a time.</p>"""
        + "".join(sections)
        + "<h2>Engine assets</h2><table><thead><tr><th>Engine</th><th>Raw (KiB)</th><th>gzip (KiB)</th><th>Brotli (KiB)</th></tr></thead><tbody>"
        + "".join(assets)
        + '</tbody></table><p>Module plus WASM only, excluding Worker/page code and browser overhead. Compression is measured offline, not a download-time test. <a href="licenses.txt">Upstream licenses</a>.</p>'
        + f'<p class="fine">Generated {html.escape(report["generated_at"])} · inputs {report["inputs_sha256"]}</p></main></html>'
    )
    (BROWSER / "report.html").write_text(payload)
    (BROWSER / "report.css").write_text(
        "body{margin:0;background:#fafaf9;color:#292524;font:16px system-ui}main{max-width:1100px;margin:auto;padding:28px}h1{letter-spacing:-.04em}h2{font-size:1.1rem}h3{font-size:.85rem}p{line-height:1.55;max-width:85ch}.table{overflow:auto}table{border-collapse:collapse;font-size:.85rem}th,td{padding:12px;text-align:left;border-bottom:1px solid #d6d3d1}.clips{display:grid;grid-template-columns:repeat(4,minmax(0,1fr));gap:12px}article{background:white;border:1px solid #d6d3d1;border-radius:12px;padding:12px}audio{width:100%}section{margin-top:28px}.fine{font:11px monospace;overflow-wrap:anywhere;color:#78716c}@media(max-width:850px){.clips{grid-template-columns:repeat(2,minmax(0,1fr))}}@media(max-width:480px){.clips{grid-template-columns:1fr}}"
    )
    print(BROWSER / "report.html")


if __name__ == "__main__":
    main()
