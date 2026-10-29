"""Small public-clip recovery probe: no speaker model or reference audio
is given to the inverse. Listening, not identification, is the next gate.
"""

import io
import json
import os
import tempfile
from datetime import UTC, datetime
from hashlib import sha256

import numpy as np
import soundfile

from randos_voice_eval import render

CLIPS = ["high_voice", "low_voice", "mid_voice", "mencken_wasichu"]
HEADROOM = 0.25  # fixed for every clip/pass, chosen before running the probe
REPORT = render.REPO / "tools/voice-eval/results/reconstruction.json"
AUDIO = render.REPO / "tmp/voice-recovery"


def save_audio(clip, name, wave, directory=AUDIO):
    """Immutable content-addressed WAVs keep old review pages truthful when
    another run is generated. Publish a complete new file atomically."""
    buffer = io.BytesIO()
    soundfile.write(buffer, wave, render.CALL_RATE, format="WAV", subtype="PCM_16")
    content = buffer.getvalue()
    filename = f"{clip}__{name}__{sha256(content).hexdigest()}.wav"
    target = directory / filename
    if not target.exists():
        with tempfile.NamedTemporaryFile(dir=directory, delete=False) as pending:
            temporary = pending.name
            try:
                pending.write(content)
                pending.flush()
                os.replace(temporary, target)
            finally:
                if os.path.exists(temporary):
                    os.unlink(temporary)
    return filename


def spectral_distance(original, other, rate=48_000):
    """Mean short-time log-spectrum distance in dB; a waveform diagnostic,
    not a naturalness score or proof of recovered speaker identity."""
    window = np.hanning(960)
    bins = np.fft.rfftfreq(len(window), 1 / rate)
    band = (bins >= 80) & (bins <= 6000)

    def spectra(wave):
        frames = np.lib.stride_tricks.sliding_window_view(wave, len(window))[::480]
        return np.abs(np.fft.rfft(frames * window, axis=1))[:, band]

    a, b = spectra(np.asarray(original)), spectra(np.asarray(other))
    active = np.max(a, axis=1) > 1e-4
    if not active.any():
        return 0.0
    difference = 20 * np.log10(np.maximum(a[active], 1e-6) / np.maximum(b[active], 1e-6))
    return float(np.mean(np.sqrt(np.mean(difference**2, axis=1))))


def main():
    import torch
    from torchaudio import functional

    render.build()
    AUDIO.mkdir(parents=True, exist_ok=True)
    rows = []
    for clip in CLIPS:
        source, rate = soundfile.read(render.REPO / f"dev/voice_lab/clips/{clip}.wav", dtype="float32")
        original = functional.resample(torch.from_numpy(source), rate, render.CALL_RATE).numpy() * HEADROOM

        def save(name, wave, clip=clip):
            return save_audio(clip, name, wave)

        original_file = save("original", original)
        once, once_diagnostics = render.process_48k(original, params={0: 1})
        twice, twice_diagnostics = render.process_48k(once, params={0: 1})
        control_file = save("control_twice", twice)
        for alpha in [0.9, 0.7]:
            key = str(alpha).replace(".", "_")
            disguised, forward = render.process_48k(original, params={0: alpha})
            sham, sham_diagnostics = render.process_48k(disguised, params={0: 1})
            recovered, inverse = render.process_48k(disguised, inverse_alpha=alpha)
            rows.append({
                "id": f"{clip}_{key}", "clip": clip, "alpha": alpha,
                "source_sha256": sha256((render.REPO / f"dev/voice_lab/clips/{clip}.wav").read_bytes()).hexdigest(),
                "audio": {"original": original_file, "disguised": save(f"{key}_disguised", disguised),
                          "recovered": save(f"{key}_recovered", recovered),
                          "sham": save(f"{key}_sham", sham), "control": control_file},
                "processing": {"forward": forward, "inverse": inverse, "sham": sham_diagnostics,
                               "control_first": once_diagnostics, "control_second": twice_diagnostics},
                "spectral_distance_db": {
                    name: round(spectral_distance(original, wave), 3)
                    for name, wave in [("disguised", disguised), ("recovered", recovered), ("sham", sham), ("control", twice)]
                },
                "assessment": "Awaiting listening; a broken inverse does not establish resistance.",
            })
    report = {
        "renderer_sha256": sha256(render.BINARY.read_bytes()).hexdigest(),
        "generated_at": datetime.now(UTC).isoformat(timespec="seconds"), "headroom": HEADROOM,
        "attack": "Known setting, no reference waveform supplied to inversion. Reestimated LPC; inverse pole-angle exponent 1/alpha; angles above pi capped at pi-1e-6 and counted.",
        "alignment": "Each pass flushes 1022 zeros and removes that known leading delay, preserving original duration.",
        "scope": "Four bundled public-domain LibriVox clips, not recorded conversations. No model training, alpha search, reference-guided tuning, or claim of reconstruction resistance.",
        "results": rows,
    }
    REPORT.write_text(json.dumps(report, indent=2) + "\n")
    print(f"Wrote {len(rows)} comparisons to {REPORT}; audio in {AUDIO}")


if __name__ == "__main__":
    main()
