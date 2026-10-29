from itertools import permutations

import numpy as np
import pytest
from randos_voice_eval import metrics, verdict


def test_eer_is_zero_when_targets_always_score_higher():
    assert metrics.eer([0.9, 0.8, 0.2, 0.1], [True, True, False, False]) == 0.0


def test_eer_is_one_when_scores_are_backwards():
    assert metrics.eer([0.1, 0.2, 0.8, 0.9], [True, True, False, False]) == 1.0


def test_eer_is_about_half_for_random_scores():
    rng = np.random.default_rng(0)
    scores = rng.random(20_000)
    labels = rng.random(20_000) < 0.5
    assert metrics.eer(scores, labels) == pytest.approx(0.5, abs=0.02)


def test_eer_for_a_known_overlap():
    # One target below one non-target: 1 of 4 targets missed, 1 of 4
    # non-targets accepted at the crossing.
    scores = [0.9, 0.8, 0.7, 0.4, 0.5, 0.3, 0.2, 0.1]
    labels = [True, True, True, True, False, False, False, False]
    assert metrics.eer(scores, labels) == pytest.approx(0.25)


@pytest.mark.parametrize("labels", [[True, False], [False, True], [True, False, False]])
def test_equal_scores_have_chance_eer(labels):
    assert metrics.eer([0.5] * len(labels), labels) == pytest.approx(0.5)


def test_eer_is_invariant_to_order_with_tied_scores():
    trials = [(0.9, True), (0.9, False), (0.4, True), (0.4, False)]
    for ordering in permutations(trials):
        scores, labels = zip(*ordering)
        assert metrics.eer(scores, labels) == pytest.approx(0.5)


def test_eer_needs_both_kinds_of_trial():
    with pytest.raises(ValueError):
        metrics.eer([0.5], [True])


def test_identification_accuracy():
    scores = [[0.9, 0.1], [0.2, 0.8], [0.6, 0.4]]
    assert metrics.identification_accuracy(scores, [0, 1, 1]) == pytest.approx(2 / 3)


def test_wer_compares_words_only():
    refs = ["HE HOPED THERE WOULD BE STEW FOR DINNER"]
    assert metrics.wer(refs, ["He hoped there would be stew for dinner."]) == 0.0
    assert metrics.wer(refs, ["He hoped there would be soup for dinner."]) == pytest.approx(1 / 8)


def test_verdicts():
    base = {"eer": 0.02, "wer": 0.05}
    hides = {"eer_ignorant": 0.45, "eer_informed": 0.4, "wer": 0.08}
    fools_ignorant = {"eer_ignorant": 0.45, "eer_informed": 0.05, "wer": 0.07}
    keeps = {"eer_ignorant": 0.05, "eer_informed": 0.03, "wer": 0.05}
    garbles = {"eer_ignorant": 0.45, "eer_informed": 0.4, "wer": 0.4}
    assert verdict.of(hides, base)["kind"] == "untested_attack"
    assert verdict.of(fools_ignorant, base)["kind"] == "fools_ignorant_only"
    assert verdict.of(keeps, base)["kind"] == "keeps_identity"
    assert verdict.of(garbles, base)["kind"] == "hurts_intelligibility"
    assert verdict.of(hides | {"eer_undo": 0.4}, base)["kind"] == "needs_review"
    assert verdict.of(hides | {"eer_undo": 0.02}, base)["kind"] == "undone"


def test_parameter_bank_preserves_alternative_reference_voices():
    from randos_voice_eval.attacks import bank_scores

    trials = np.array([[1.0, 0.0], [0.0, 1.0]])
    banks = [np.array([[1.0, 0.0], [-1.0, 0.0]]), np.array([[0.0, 1.0], [0.0, -1.0]])]
    assert np.array_equal(bank_scores(trials, banks), np.eye(2))


def test_call_parameters_do_not_depend_on_iteration_order():
    from randos_voice_eval.attacks import configuration
    from randos_voice_eval.bench import settings

    key, _, how, _ = next(item for item in settings() if item[0] == "pitch_shift_random")
    before = configuration(key, how, "call-1")
    configuration(key, how, "another-call")
    assert configuration(key, how, "call-1") == before


def test_processing_defects_cannot_be_called_promising():
    result = {"eer_ignorant": 0.5, "eer_informed": 0.5, "eer_adaptive": 0.5, "wer": 0.05}
    assert verdict.of(result | {"processing": {"failed_frames": 1}}, {"wer": 0.05})["kind"] == "processing_defect"


def test_reference_defects_cannot_be_called_promising_or_diluted():
    result = {"eer_ignorant": 0.5, "eer_informed": 0.5, "eer_adaptive": 0.5, "wer": 0.05}
    result["reference_processing"] = [{"processing": {"clipped_samples": 20, "samples": 1000}}]
    assert verdict.of(result, {"wer": 0.05})["kind"] == "invalid_attack"
