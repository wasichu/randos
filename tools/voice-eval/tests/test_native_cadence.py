"""Reject incomplete or late native trials; no compiler, devices or models."""

import importlib.util
from pathlib import Path

import pytest

SCRIPT = Path(__file__).resolve().parents[2] / "voice-dsp/native/run.py"
SPEC = importlib.util.spec_from_file_location("native_cadence", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def complete_trial():
    return {
        "mode": "paced", "seconds": 60, "elapsed_ms": 60000.2,
        "input_samples": 2880000, "delivered_samples": 2869440,
        "buffer_delay_ms": 240, "max_input_samples": 3840,
        "max_output_samples": 7680, "queue_capacity_samples": 15360,
        "starvations": 0, "overflows": 0,
        "missed_release_periods": 0, "missed_delivery_periods": 0,
        "frame_samples": 960, "batch_samples": 3840,
        "core_delay_samples": 3840, "prefill_samples": 7680,
    }


def test_delivery_counts_the_frame_starting_at_the_last_boundary():
    assert MODULE.measured_pass(complete_trial())
    incomplete = complete_trial()
    incomplete["delivered_samples"] -= 960
    assert not MODULE.measured_pass(incomplete)


@pytest.mark.parametrize("field,value", [
    ("seconds", 1), ("elapsed_ms", 59999), ("input_samples", 2879040),
    ("max_input_samples", 4800), ("max_output_samples", 16320),
    ("queue_capacity_samples", 30720), ("prefill_samples", 3840),
    ("frame_samples", 3840), ("core_delay_samples", 7680),
    ("starvations", 1), ("overflows", 1),
    ("missed_release_periods", 1), ("missed_delivery_periods", 1),
])
def test_a_fast_average_cannot_hide_incomplete_late_or_unbounded_delivery(field, value):
    stats = complete_trial()
    stats[field] = value
    assert not MODULE.measured_pass(stats)
