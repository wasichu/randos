"""Level control must not confuse clipping with a change in sound quality."""

import importlib.util
from pathlib import Path

import numpy as np
import pytest

SPEC = importlib.util.spec_from_file_location(
    "sound_quality", Path(__file__).resolve().parents[2] / "voice-browser/sound_quality.py"
)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def test_level_match_keeps_relative_waveform_and_common_headroom():
    original = np.full(1000, 0.2, dtype=np.float32)
    peaky = np.zeros(1000, dtype=np.float32)
    peaky[500] = 1
    waves = {"original": original, "quiet": original / 10, "peaky": peaky}
    matched, gains = MODULE.match_levels(waves)
    levels = [np.sqrt(np.mean(wave.astype(np.float64) ** 2)) for wave in matched.values()]
    assert max(levels) - min(levels) < 1e-8
    assert max(np.max(np.abs(wave)) for wave in matched.values()) <= 0.900001
    assert gains["original"] < 1  # attenuate the whole set for the peaky member
    for name, wave in waves.items():
        np.testing.assert_allclose(matched[name], wave * gains[name])


@pytest.mark.parametrize("bad", [np.zeros(10), np.full(10, np.nan), np.full(10, np.inf)])
def test_invalid_audio_cannot_publish_a_level_matched_comparison(bad):
    with pytest.raises(ValueError):
        MODULE.match_levels({"original": np.ones(10), "bad": bad})
