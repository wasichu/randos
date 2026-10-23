"""The judge sees only what can change a pick: translations passing every
check, and of those the finalists (`review.to_judge`), with verdicts it has
given before reused (`scoring.JudgeCache`)."""

import json

from randos_translate import cli, po, review, scoring
from test_pick import FAIL, entry


def settled(e):
    return e["scores"]["judge"]["score"] is not None


def test_the_best_ranked_is_judged_first_and_alone_when_it_cannot_be_vetoed():
    entries = {
        "a": entry("A", metricx=1.0, comet=0.9),
        "b": entry("B", metricx=2.0, comet=0.8),
        "c": entry("C", metricx=3.0, comet=0.7),
    }
    assert review.to_judge(entries, settled) == ["a"]
    entries["a"]["scores"]["judge"]["score"] = 5
    assert review.to_judge(entries, settled) == []


def test_a_low_rated_leader_brings_in_the_next_until_one_could_veto_it():
    entries = {
        "a": entry("A", metricx=1.0, comet=0.9, judge=3),
        "b": entry("B", metricx=2.0, comet=0.8),
        "c": entry("C", metricx=3.0, comet=0.7),
    }
    assert review.to_judge(entries, settled) == ["b"]
    # b can't be vetoed, but a is vetoed only if something rates 7 or more.
    entries["b"]["scores"]["judge"]["score"] = 6
    assert review.to_judge(entries, settled) == ["c"]
    entries["c"]["scores"]["judge"]["score"] = 8
    assert review.to_judge(entries, settled) == []
    assert review.pick(entries)["model"] == "b"


def test_a_tied_group_is_judged_together():
    entries = {
        "a": entry("A", metricx=1.0, comet=0.9),
        "b": entry("B", metricx=1.0, comet=0.9),
        "c": entry("C", metricx=3.0, comet=0.7),
    }
    assert review.to_judge(entries, settled) == ["a", "b"]


def test_failing_translations_and_lone_ones_are_never_judged():
    entries = {"a": entry("A", metricx=1.0, comet=0.9, checks=FAIL), "b": entry("B", metricx=2.0, comet=0.8)}
    assert review.to_judge(entries, settled) == []


def test_without_both_quality_scores_every_passing_one_is_judged():
    entries = {"a": entry("A", metricx=1.0), "b": entry("B", metricx=2.0), "c": entry("C", metricx=3.0, checks=FAIL)}
    assert review.to_judge(entries, settled) == ["a", "b"]


def test_the_judge_breaks_ties_among_the_judged_while_others_are_unjudged():
    entries = {
        "a": entry("A", metricx=1.0, comet=0.9, judge=5, chrf=90.0),
        "b": entry("B", metricx=1.0, comet=0.9, judge=9, chrf=10.0),
        "c": entry("C", metricx=3.0, comet=0.7),
    }
    assert review.pick(entries)["model"] == "b"


class FakeJudge:
    asked: list[tuple[str, str]] = []
    loaded: list[str] = []

    def __init__(self, judge="mistral"):
        self.judge = judge
        FakeJudge.loaded.append(judge)

    def score(self, locale, entries):
        FakeJudge.asked += [(locale, e["text"]) for e in entries]
        return [
            {"score": 3 if e["text"].startswith("bad") else 8, "reason": "", "context": "", "by": self.judge}
            for e in entries
        ]


def write_run(path, model, texts, at, locale="es"):
    entries = [
        {
            "key": key,
            "msgid": key,
            "msgctxt": None,
            "locale": locale,
            "text": text,
            "back_translation": key,
            "checks": {},
            "scores": {"chrf": 50.0, "metricx": {"score": metricx}, "comet_kiwi": {"score": comet}}
            | {"judge": scoring.pending_scores()["judge"], "judge_qwen": scoring.pending_scores()["judge_qwen"]},
        }
        for key, (text, metricx, comet) in texts.items()
    ]
    path.write_text(json.dumps({"run": {"model": model, "at": at}, "entries": entries}))
    return path


def test_the_judge_command_judges_finalists_and_reuses_its_verdicts(tmp_path, monkeypatch):
    # One judge, to follow its finalists and its cache.
    monkeypatch.setattr(cli.scoring, "judges_for", lambda locale: ["mistral"])
    monkeypatch.setattr(cli, "JUDGE_CACHE", tmp_path / "judge-cache.json")
    monkeypatch.setitem(cli.scoring.SCORERS, "judge", FakeJudge)
    monkeypatch.setattr(cli.po, "sources", lambda: [po.Source("Ready"), po.Source("Close %{time}")])
    monkeypatch.setattr(cli.scoring, "current_contexts", lambda: {})
    one = write_run(tmp_path / "one.json", "one", {"Ready": ("bad listo", 1.0, 0.9), "Close %{time}": ("Cerrar", 1.0, 0.9)}, "1")
    two = write_run(tmp_path / "two.json", "two", {"Ready": ("Listo", 2.0, 0.8), "Close %{time}": ("Cerrar %{time}", 2.0, 0.8)}, "2")
    three = write_run(tmp_path / "three.json", "three", {"Ready": ("Listo", 2.0, 0.8)}, "3")

    FakeJudge.asked = []
    cli.score("judge", [one, two, three], redo=False)
    # "Cerrar" drops the placeholder and "Cerrar %{time}" passes alone: no judging.
    # "bad listo" leads and rates low, so the next (tied) group is judged: "Listo" twice, judged once.
    assert FakeJudge.asked == [("es", "bad listo"), ("es", "Listo")]
    scores = {
        (p.stem, e["key"]): e["scores"]["judge"]["score"] for p in (one, two, three) for e in json.loads(p.read_text())["entries"]
    }
    assert scores == {
        ("one", "Ready"): 3,
        ("one", "Close %{time}"): None,
        ("two", "Ready"): 8,
        ("two", "Close %{time}"): None,
        ("three", "Ready"): 8,
    }

    FakeJudge.asked = []
    cli.score("judge", [one, two, three], redo=False)
    assert FakeJudge.asked == []
    four = write_run(tmp_path / "four.json", "four", {"Ready": ("bad listo", 0.5, 0.95)}, "4")
    cli.score("judge", [one, two, three, four], redo=False)
    assert FakeJudge.asked == []

    cli.score("judge", [one, two, three, four], redo=True)
    assert FakeJudge.asked == [("es", "bad listo"), ("es", "Listo")]


def test_each_locale_has_its_judge_and_each_loads_only_when_needed(tmp_path, monkeypatch):
    monkeypatch.setattr(cli, "JUDGE_CACHE", tmp_path / "judge-cache.json")
    monkeypatch.setitem(cli.scoring.SCORERS, "judge", FakeJudge)
    monkeypatch.setattr(cli.scoring, "current_contexts", lambda: {})
    monkeypatch.setattr(cli.po, "sources", lambda: [po.Source("Ready")])
    runs = [
        write_run(tmp_path / f"{m}-{loc}.json", m, {"Ready": (text, mx, 0.5)}, f"{m}{loc}", loc)
        for loc, text in (("es", "Listo"), ("sw", "Tayari"))
        for m, mx in (("one", 1.0), ("two", 2.0))
    ]

    FakeJudge.asked, FakeJudge.loaded = [], []
    cli.score("judge", runs, redo=False)
    assert FakeJudge.loaded == ["mistral", "qwen"]
    # Both judge Spanish, each in its own score; Qwen alone judges Swahili.
    scores = {(p.stem): json.loads(p.read_text())["entries"][0]["scores"] for p in runs}
    assert scores["one-es"]["judge"]["by"] == "mistral"
    assert scores["one-es"]["judge_qwen"]["by"] == "qwen"
    assert scores["one-sw"]["judge_qwen"]["by"] == "qwen"
    assert scores["one-sw"]["judge"]["score"] is None
    # Each judge's leader rated 8: nobody else needed judging.
    assert scores["two-es"]["judge"]["score"] is None and scores["two-sw"]["judge_qwen"]["score"] is None

    # Nothing new: neither judge loads.
    FakeJudge.loaded = []
    cli.score("judge", runs, redo=False)
    assert FakeJudge.loaded == []


def test_either_judge_can_veto_and_their_mean_breaks_ties():
    # a leads on quality; Mistral likes it but Qwen rates it 3 while rating b 8.
    entries = {
        "a": entry("A", metricx=1.0, comet=0.9, judge=8),
        "b": entry("B", metricx=2.0, comet=0.8, judge=7),
    }
    entries["a"]["scores"]["judge_qwen"] = {"score": 3}
    entries["b"]["scores"]["judge_qwen"] = {"score": 8}
    assert review.pick(entries)["model"] == "b"

    tied = {"a": entry("A", metricx=1.0, comet=0.9, judge=9), "b": entry("B", metricx=1.0, comet=0.9, judge=6)}
    tied["a"]["scores"]["judge_qwen"] = {"score": 5}
    tied["b"]["scores"]["judge_qwen"] = {"score": 9}
    # Means 7 and 7.5: b.
    assert review.pick(tied)["model"] == "b"
