"""Bounded isolated acoustic-feature edits for the pinned FARGAN audition."""

import numpy as np

BANDS = np.array(
    [
        0,
        200,
        400,
        600,
        800,
        1000,
        1200,
        1400,
        1600,
        2000,
        2400,
        2800,
        3200,
        4000,
        4800,
        5600,
        6800,
        8000,
    ]
)
COMPENSATION = np.array(
    [
        0.8,
        1,
        1,
        1,
        1,
        1,
        1,
        1,
        0.666667,
        0.5,
        0.5,
        0.5,
        0.333333,
        0.25,
        0.25,
        0.2,
        0.166667,
        0.173913,
    ]
)


def lookup(frequency, scale):
    """Smooth inverse-frequency map, fixed at DC/Nyquist, not uniform VTLN."""
    f = np.asarray(frequency, dtype=float)
    return f + (1 / scale - 1) * f * (1 - f / 8000) ** 2


def periods(features):
    return np.floor(0.5 + 256 / np.exp2(features[:, 18].astype(float) + 1.5))


def edit(features, basis, pitch=0, scale=1, padding=20):
    x = np.asarray(features)
    if x.ndim != 2 or x.shape[1] != 20 or len(x) <= 2 * padding or padding < 0:
        raise ValueError("Expected complete feature frames with fixed padding")
    if (
        not np.isfinite(x).all()
        or not np.isfinite(basis).all()
        or basis.shape != (18, 18)
    ):
        raise ValueError("Nonfinite features or invalid DCT basis")
    if abs(pitch) > 1 or not 0.9 <= scale <= 1.1 or not np.isfinite(pitch):
        raise ValueError("Only bounded first-round edits are supported")
    if pitch and scale != 1:
        raise ValueError("This audition isolates pitch and envelope edits")
    result = x.copy()
    if pitch == 0 and scale == 1:
        return result
    end = len(x) - padding if padding else len(x)
    active = result[padding:end]
    if pitch:
        proposed = active.copy()
        proposed[:, 18] += pitch / 12
        period = periods(proposed)
        valid = (period >= 32) & (period <= 256)
        # Keep out-of-range frames unchanged; do not use decoder clamps as edits.
        active[valid, 18] = proposed[valid, 18]
    else:
        cepstrum = active[:, :18].astype(float)
        cepstrum[:, 0] += 4
        log_energy = cepstrum @ basis.T
        compensation = np.log10(COMPENSATION)
        density = log_energy + compensation
        mapped = lookup(BANDS, scale)
        warped = np.stack([np.interp(mapped, BANDS, row) for row in density])
        new_cepstrum = (warped - compensation) @ basis
        new_cepstrum[:, 0] -= 4
        # Preserve mean log-band level, NOT a claim of equal waveform loudness.
        new_cepstrum[:, 0] = active[:, 0]
        active[:, :18] = new_cepstrum
    if not np.isfinite(result).all():
        raise ValueError("Feature edit produced nonfinite values")
    return result
