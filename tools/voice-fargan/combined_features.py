"""Final bounded combined probe; preserve the earlier isolated editor's limits."""

import numpy as np
from features import BANDS, COMPENSATION, edit


def strong_lookup(frequency, scale):
    if scale not in [0.8, 1, 1.25]:
        raise ValueError("Only the reference resonance scales are supported")
    f = np.asarray(frequency, dtype=float)
    return np.where(
        f <= 4000, f / scale, 4000 / scale + (f - 4000) * (8000 - 4000 / scale) / 4000
    )


def strong_envelope(features, basis, scale):
    result = edit(features, basis)  # validation and byte-preserving copy
    if scale == 1:
        return result
    mapped = strong_lookup(BANDS, scale)
    active = result[20:-20]
    cepstrum = active[:, :18].astype(float)
    cepstrum[:, 0] += 4
    compensation = np.log10(COMPENSATION)
    density = cepstrum @ basis.T + compensation
    warped = np.stack([np.interp(mapped, BANDS, row) for row in density])
    cepstrum = (warped - compensation) @ basis
    cepstrum[:, 0] = active[:, 0]
    active[:, :18] = cepstrum
    if not np.isfinite(result).all():
        raise ValueError("Combined features became nonfinite")
    return result


def combined(features, basis, pitch=0, scale=1):
    if (pitch, scale) not in [(0, 1), (-1, 0.8), (1, 1.25)]:
        raise ValueError(
            "Only identity and the two fixed combined presets are supported"
        )
    return strong_envelope(edit(features, basis, pitch=pitch), basis, scale)
