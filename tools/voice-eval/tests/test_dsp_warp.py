"""Frequency-envelope warping must move resonances without changing frame count."""

import importlib.util
from pathlib import Path

import numpy as np

SPEC = importlib.util.spec_from_file_location(
    "voice_dsp_probe", Path(__file__).resolve().parents[2] / "voice-dsp/probe.py"
)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def test_warp_moves_a_resonance_in_the_declared_direction():
    bins = np.arange(301)
    envelope = (1e-4 + np.exp(-((bins - 100) / 8) ** 2))[None, :]
    for scale, peak in [(0.9, 90), (1.1, 110)]:
        changed = MODULE.warp_envelope(envelope, scale)
        assert changed.shape == envelope.shape
        assert np.argmax(changed[0]) == peak
        assert np.isfinite(changed).all() and (changed > 0).all()


def test_neutral_warp_preserves_envelope_and_frequency_edges_are_bounded():
    envelope = np.array([[1e-4, 0.5, 2.0, 0.1], [1, 1, 1, 1]])
    np.testing.assert_allclose(MODULE.warp_envelope(envelope, 1), envelope)
    changed = MODULE.warp_envelope(envelope, 0.9)
    np.testing.assert_allclose(changed[0, -1], envelope[0, -1])
    np.testing.assert_allclose(changed[1], 1)
