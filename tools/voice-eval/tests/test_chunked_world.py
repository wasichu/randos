"""Chunk joining must preserve endpoints and obey its declared input horizon."""

import importlib.util
import sys
from pathlib import Path

import numpy as np
import pytest

SCREEN = Path(__file__).resolve().parents[2] / "voice-dsp"
sys.path.insert(0, str(SCREEN))
SPEC = importlib.util.spec_from_file_location("chunked_world", SCREEN / "chunked.py")
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


@pytest.mark.parametrize("length", [1, 48001, 49200])
@pytest.mark.parametrize("hop", [1920, 3840, 7680])
def test_overlap_preserves_identity_and_complete_first_last_samples(length, hop):
    source = np.random.default_rng(42).normal(size=length)
    rendered, report = MODULE.chunk_render(source, hop, lambda window: window)
    np.testing.assert_allclose(rendered, source, rtol=0, atol=1e-12)
    assert sum(row["emitted_samples"] for row in report["rows"]) == length


def test_future_changes_cannot_change_already_released_hops():
    source = np.random.default_rng(13).normal(size=48000)
    changed = source.copy()
    changed[24000:] += 1

    def transform(window):
        return np.convolve(window, np.ones(240) / 240, mode="same")

    original, report = MODULE.chunk_render(source, 1920, transform)
    later, _ = MODULE.chunk_render(changed, 1920, transform)
    for row in report["rows"]:
        if row["required_input_end"] <= 24000:
            start = row["output_start"]
            np.testing.assert_array_equal(original[start:start + 1920], later[start:start + 1920])
    assert not np.allclose(original[24000:], later[24000:])


def test_scheduling_reports_context_wait_and_sequential_compute_without_hidden_hop():
    hop = 1920
    _, report = MODULE.chunk_render(np.ones(48001), hop, lambda window: window)
    first = report["rows"][0]
    assert first["required_input_end"] == hop + MODULE.OVERLAP + MODULE.FUTURE
    assert report["input_buffering_ms"] == 100
    previous = 0
    for row in report["rows"]:
        assert row["finish_ms"] == pytest.approx(max(row["release_ms"], previous) + row["compute_ms"])
        assert row["playout_delay_ms"] == pytest.approx(row["finish_ms"] - row["output_start"] * 1000 / MODULE.RATE)
        previous = row["finish_ms"]
    assert report["rows"][-1]["eos_padding"]


def test_invalid_chunk_results_cannot_be_published():
    with pytest.raises(ValueError, match="Incomplete or nonfinite"):
        MODULE.chunk_render(np.ones(4800), 1920, lambda _window: np.zeros(1))
