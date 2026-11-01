"""Prepared full-band source/filter auditions, not a shipping streaming engine.

Excitation is an LPC residual estimate, NOT measured glottal flow. Nonlinear
signed-power shaping changes pulse peaks without synthesizing a new pitch track.
"""

import numpy as np
from scipy.linalg import solve_toeplitz
from scipy.signal import correlate, lfilter, sosfilt, zpk2sos

RATE = 48000
FRAME = 1920
HOP = 960
ORDER = 48
PRE = 0.97


def poles_with_bandwidth(a, factor):
    roots = np.roots(a)
    radius = np.abs(roots)
    if np.any(radius >= 1) or not np.isfinite(roots).all():
        raise ValueError("Unstable analysis poles")
    frequency = np.abs(np.angle(roots)) * RATE / (2 * np.pi)
    bandwidth = -RATE / np.pi * np.log(np.maximum(radius, 1e-30))
    eligible = (
        (frequency >= 150)
        & (frequency <= 4000)
        & (bandwidth >= 40)
        & (bandwidth <= 1000)
        & (bandwidth * factor >= 40)
        & (bandwidth * factor <= 1500)
    )
    changed = roots.copy()
    changed[eligible] *= np.exp(-np.pi * bandwidth[eligible] * (factor - 1) / RATE)
    result = np.poly(changed)
    if np.max(np.abs(result.imag)) > 1e-7 or np.any(np.abs(changed) >= 1):
        raise ValueError("Invalid transformed poles")
    return zpk2sos([], changed, 1), {
        "changed_poles": int(eligible.sum()),
        "ineligible_poles": int((~eligible).sum()),
        "max_angle_error": float(np.max(np.abs(np.angle(changed) - np.angle(roots)))),
        "min_eligible_bandwidth_hz": float(np.min(bandwidth[eligible]))
        if np.any(eligible)
        else None,
        "max_eligible_bandwidth_hz": float(np.max(bandwidth[eligible]))
        if np.any(eligible)
        else None,
    }


def shape_residual(e, gamma):
    if gamma == 1:
        return e.copy()
    mean = float(np.mean(e))
    centered = e - mean
    rms = float(np.sqrt(np.mean(centered**2)))
    if rms < 1e-12:
        return e.copy()
    changed = np.sign(centered) * np.abs(centered / rms) ** gamma
    changed -= np.mean(changed)
    level = float(np.sqrt(np.mean(changed**2)))
    gain = 1 / max(level, 1e-12)
    if not 0.25 <= gain <= 4:
        raise ValueError("Residual gain outside research bounds")
    shaped = changed * gain * rms
    # A fixed partial blend avoids replacing the estimated source wholesale.
    blended = 0.65 * centered + 0.35 * shaped
    blended *= rms / max(float(np.sqrt(np.mean(blended**2))), 1e-12)
    return blended + mean


def transform(x, *, bandwidth=1.0, gamma=1.0, sos_control=False):
    if (
        bandwidth not in [0.75, 1.0, 1.35]
        or gamma not in [0.8, 1.0, 1.25]
        or (bandwidth != 1 and gamma != 1)
    ):
        raise ValueError("Only isolated, fixed audition presets are allowed")
    x = np.asarray(x, dtype=float)
    if x.ndim != 1 or not len(x) or not np.isfinite(x).all():
        raise ValueError("Finite nonempty mono input required")
    padded = np.pad(x, (FRAME, FRAME))
    output = np.zeros(len(padded))
    weight = np.zeros(len(padded))
    window = np.hanning(FRAME)
    stats = {
        "frames": 0,
        "voiced_frames": 0,
        "bypassed_frames": 0,
        "changed_poles": 0,
        "ineligible_poles": 0,
        "max_angle_error": 0.0,
        "max_reconstruction_error": 0.0,
        "max_sos_identity_error": 0.0,
    }
    for start in range(0, len(padded) - FRAME + 1, HOP):
        frame = padded[start : start + FRAME]
        stats["frames"] += 1
        y = frame.copy()
        centered = frame - np.sum(frame * window) / np.sum(window)
        # Voice gate from the original frame, not the whitened residual.
        ac = correlate(centered * window, centered * window, mode="full", method="fft")[
            FRAME - 1 :
        ]
        peak = float(np.max(ac[80:801]) / max(ac[0], 1e-30))
        voiced = (
            np.sqrt(np.mean((centered * window) ** 2)) > 1e-5
            and ac[0] > 1e-12
            and peak > 0.55
        )
        if voiced:
            pre = lfilter([1, -PRE], [1], frame)
            analysis = pre * np.sqrt(window)
            r = correlate(analysis, analysis, mode="full", method="fft")[
                FRAME - 1 : FRAME + ORDER
            ]
            r[0] *= 1.0001
            a = np.r_[
                1.0, solve_toeplitz(r[:ORDER], -r[1 : ORDER + 1], check_finite=True)
            ]
            e = lfilter(a, [1], pre)
            control = lfilter([1], [1, -PRE], lfilter([1], a, e))
            error = float(np.max(np.abs(control - frame)))
            stats["max_reconstruction_error"] = max(
                stats["max_reconstruction_error"], error
            )
            if error > 1e-5 or not np.isfinite(control).all():
                raise ValueError("Matched LPC reconstruction lost identity")
            roots = np.roots(a)
            if not np.isfinite(roots).all() or np.any(np.abs(roots) >= 1):
                raise ValueError("Unstable LPC estimate; no pole reflection/fallback")
            new_sos = None
            if bandwidth != 1 or sos_control:
                unchanged_sos, _ = poles_with_bandwidth(a, 1.0)
                unchanged = lfilter([1], [1, -PRE], sosfilt(unchanged_sos, e))
                sos_error = float(np.max(np.abs(unchanged - frame)))
                relative = float(
                    np.sqrt(np.mean((unchanged - frame) ** 2))
                    / max(np.sqrt(np.mean(frame**2)), 1e-12)
                )
                stats["max_sos_identity_error"] = max(
                    stats["max_sos_identity_error"], sos_error
                )
                if sos_error > 0.001 or relative > 0.01:
                    raise ValueError(
                        "Roots/SOS identity exceeds declared reconstruction bounds"
                    )
                if sos_control:
                    new_sos = unchanged_sos
            if bandwidth != 1:
                new_sos, pole_stats = poles_with_bandwidth(a, bandwidth)
                for name in ["changed_poles", "ineligible_poles"]:
                    stats[name] += pole_stats[name]
                stats["max_angle_error"] = max(
                    stats["max_angle_error"], pole_stats["max_angle_error"]
                )
            new_e = shape_residual(e, gamma)
            filtered = (
                lfilter([1], a, new_e) if new_sos is None else sosfilt(new_sos, new_e)
            )
            candidate = lfilter([1], [1, -PRE], filtered)
            if not np.isfinite(candidate).all() or np.max(np.abs(candidate)) > max(
                1.0, 20 * np.max(np.abs(frame))
            ):
                raise ValueError(
                    f"Unstable or excessive synthesis: peak {np.max(np.abs(candidate)):.5g}, input {np.max(np.abs(frame)):.5g}"
                )
            # Smooth strength across voiced/unvoiced transitions, no hard cuts.
            mix = min(1.0, (peak - 0.55) / 0.2)
            y = frame + mix * (candidate - frame)
            stats["voiced_frames"] += 1
        else:
            stats["bypassed_frames"] += 1
        output[start : start + FRAME] += y * window
        weight[start : start + FRAME] += window
    region = slice(FRAME, FRAME + len(x))
    if np.any(weight[region] <= 0):
        raise ValueError("Uncovered overlap-add sample")
    result = output[region] / weight[region]
    if len(result) != len(x) or not np.isfinite(result).all():
        raise ValueError("Incomplete/nonfinite result")
    return result, stats
