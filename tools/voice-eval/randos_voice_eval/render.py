"""Audio through randos's real voice processors (the `voice/` crate's
`render` example, the code calls run), at a call's sample rate.

LibriSpeech and both models use 16 kHz; calls run at 48 kHz. Each clip is
resampled up, processed, and resampled back, so the processors see what
they would in a call.
"""

import subprocess
from pathlib import Path

import numpy as np

REPO = Path(__file__).resolve().parents[3]
BINARY = REPO / "target" / "release" / "examples" / "render"
CALL_RATE = 48_000


def build():
    """Builds the render example (release), once per run."""
    subprocess.run(
        ["cargo", "build", "--quiet", "--release", "-p", "randos_voice", "--example", "render"],
        cwd=REPO,
        check=True,
    )


def process(samples_16k, variant, params=None):
    """`samples_16k`: mono float32 at 16 kHz. `params`: {index: value} in
    the variant's parameter order (pitch shift: 0 semitones, 1 window ms)."""
    import torch
    import torchaudio.functional as F

    wave = torch.from_numpy(np.asarray(samples_16k, dtype=np.float32))
    up = F.resample(wave, 16_000, CALL_RATE).numpy().astype("<f4")
    args = [str(BINARY), "--variant", variant, "--rate", str(CALL_RATE)]
    for index, value in (params or {}).items():
        args += ["--param", f"{index}={value}"]
    out = subprocess.run(args, input=up.tobytes(), capture_output=True, check=True).stdout
    processed = torch.from_numpy(np.frombuffer(out, dtype="<f4").copy())
    return F.resample(processed, CALL_RATE, 16_000).numpy()
