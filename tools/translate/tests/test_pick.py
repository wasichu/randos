"""Per-string selection (`review.pick`): of the translations passing every
check, MetricX and COMET-Kiwi decide together, the judge breaks ties, and a
model's name never does."""

from randos_translate import review

OK = {"placeholders": {"ok": True, "detail": ""}}
FAIL = {"placeholders": {"ok": False, "detail": "expected ['%{time}']"}}


def entry(text, *, metricx=None, comet=None, judge=None, chrf=50.0, checks=OK):
    return {
        "msgid": "x",
        "msgctxt": None,
        "locale": "es",
        "text": text,
        "checks": checks,
        "scores": {
            "chrf": chrf,
            "metricx": {"score": metricx},
            "comet_kiwi": {"score": comet},
            "judge": {"score": judge},
        },
    }


def test_the_two_quality_estimators_decide_together():
    # a is best by MetricX, b by COMET-Kiwi and second by MetricX: b's mean rank wins.
    entries = {
        "a": entry("A", metricx=1.0, comet=0.60),
        "b": entry("B", metricx=1.5, comet=0.90),
        "c": entry("C", metricx=3.0, comet=0.80),
    }
    assert review.pick(entries)["model"] == "b"


def test_a_translation_failing_a_check_never_ships():
    entries = {"a": entry("A", metricx=0.1, comet=0.99, checks=FAIL), "b": entry("B", metricx=5.0, comet=0.5)}
    assert review.pick(entries) == {"model": "b", "why": "the only translation passing every check"}
    assert review.pick({"a": entry("A", checks=FAIL)}) is None


def test_metricx_alone_never_decides():
    # No COMET-Kiwi scores: MetricX prefers a, the judge prefers b, so they tie
    # on mean rank and the judge's rank breaks it.
    entries = {"a": entry("A", metricx=1.0, judge=4), "b": entry("B", metricx=2.0, judge=10)}
    assert review.pick(entries)["model"] == "b"


def test_ties_never_go_by_the_models_name():
    # Equal on everything but chrF: the higher chrF wins, though "z" sorts last.
    same = {"metricx": 1.0, "comet": 0.8, "judge": 7}
    entries = {"a": entry("A", chrf=40.0, **same), "z": entry("Z", chrf=60.0, **same)}
    assert review.pick(entries)["model"] == "z"
    # Equal there too: the shorter text.
    entries = {"a": entry("Longer", **same), "z": entry("Short", **same)}
    assert review.pick(entries)["model"] == "z"


def test_the_judge_vetoes_a_wrong_sense_the_estimators_miss():
    # "Language" (the interface language): MetricX and COMET-Kiwi slightly
    # prefer "Lenguaje", which the judge, seeing the context, rates 4.
    entries = {
        "m2m100": entry("Lenguaje", metricx=0.30, comet=0.87, judge=4),
        "hy-mt2": entry("Idioma", metricx=1.69, comet=0.86, judge=10),
    }
    chosen = review.pick(entries)
    assert chosen["model"] == "hy-mt2"
    assert "veto of m2m100" in chosen["why"]


def test_no_veto_without_a_judged_alternative_rated_well():
    # The alternative has no judgement: a missing one never vetoes.
    entries = {
        "a": entry("Lenguaje", metricx=0.30, comet=0.87, judge=4),
        "b": entry("Idioma", metricx=1.69, comet=0.86, judge=None),
    }
    # (Rated well by the other judge, so not every judge rates it low.)
    entries["a"]["scores"]["judge_qwen"] = {"score": 8}
    assert review.pick(entries)["model"] == "a"
    # Nor does a middling one (5 or 6).
    entries["b"] = entry("Idioma", metricx=1.69, comet=0.86, judge=6)
    assert review.pick(entries)["model"] == "a"


def test_tied_scores_share_their_rank():
    assert review.average_ranks({"a": 1.0, "b": 1.0, "c": 2.0}, higher_is_better=False) == {
        "a": 1.5,
        "b": 1.5,
        "c": 3.0,
    }


def test_the_only_one_left_after_a_veto_ships_and_says_so():
    entries = {"a": entry("A", metricx=1.0, comet=0.9, judge=3), "b": entry("B", metricx=2.0, comet=0.8, judge=8)}
    picked = review.pick(entries)
    assert picked == {"model": "b", "why": "the only one left after the judge's veto of a"}


def test_without_quality_scores_the_tie_breaks_decide_alone():
    # Neither MetricX nor COMET-Kiwi has scored: the judge's rank, then chrF.
    entries = {"a": entry("A", judge=6, chrf=90.0), "b": entry("B", judge=8, chrf=40.0)}
    picked = review.pick(entries)
    assert picked["model"] == "b" and "the tie-breaks alone" in picked["why"]


def test_comet_kiwi_alone_decides_when_metricx_has_no_score():
    # Unlike MetricX alone (which TranslateGemma was trained to flatter).
    entries = {"a": entry("A", comet=0.70, chrf=90.0), "b": entry("B", comet=0.90, chrf=40.0)}
    picked = review.pick(entries)
    assert picked["model"] == "b" and "COMET-Kiwi" in picked["why"]


def test_metricx_with_some_finalists_unjudged_doesnt_decide():
    # The judge can't stand in beside MetricX without judging all: then the
    # tie-breaks decide, and an unjudged translation ranks last among them.
    entries = {"a": entry("A", metricx=1.0), "b": entry("B", metricx=2.0, judge=9)}
    picked = review.pick(entries)
    assert picked["model"] == "b" and "the tie-breaks alone" in picked["why"]


def test_a_lone_translation_a_judge_rates_low_ships_nothing():
    lone = {"a": entry("A", checks=FAIL), "b": entry("B", metricx=5.0, comet=0.5, judge=3)}
    assert review.pick(lone) is None
    lone["b"]["scores"]["judge"] = {"score": 5}
    assert review.pick(lone)["model"] == "b"


def test_a_pick_every_judge_rates_low_ships_nothing():
    weak = {
        "a": entry("A", metricx=1.0, comet=0.9, judge=3),
        "b": entry("B", metricx=2.0, comet=0.8, judge=4),
    }
    # No rating high enough to veto either, and the best is rated low.
    assert review.pick(weak) is None
    weak["a"]["scores"]["judge"] = {"score": 6}
    assert review.pick(weak)["model"] == "a"
