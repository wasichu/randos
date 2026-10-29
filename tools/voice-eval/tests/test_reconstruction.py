import numpy as np
import pytest
from randos_voice_eval.reconstruction import save_audio, spectral_distance


def test_spectral_diagnostic_is_zero_for_identity_and_changes_with_resonances():
    time = np.arange(4800) / 48000
    original = np.sin(2 * np.pi * 300 * time) + 0.5 * np.sin(2 * np.pi * 1500 * time)
    changed = np.sin(2 * np.pi * 300 * time) + 0.5 * np.sin(2 * np.pi * 2000 * time)
    assert spectral_distance(original, original) == pytest.approx(0)
    assert spectral_distance(original, changed) > 1
    assert spectral_distance(np.zeros(4800), np.zeros(4800)) == 0


def test_regenerated_audio_cannot_change_what_an_open_review_page_fetches(tmp_path):
    old = save_audio("sample", "recovered", np.full(4800, 0.1), tmp_path)
    original_bytes = (tmp_path / old).read_bytes()
    new = save_audio("sample", "recovered", np.full(4800, 0.2), tmp_path)
    assert new != old
    assert (tmp_path / old).read_bytes() == original_bytes
    assert save_audio("sample", "recovered", np.full(4800, 0.1), tmp_path) == old
    assert len(list(tmp_path.glob("*.wav"))) == 2
