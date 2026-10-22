"""`run --append`: a run topped up after the template changed translates
only the new strings and drops the ones the template no longer has."""

import json

from randos_translate import cli, po


class Upper:
    name = "upper"
    locales = ["es"]

    def __init__(self):
        self.asked = []

    def translate(self, texts, target):
        self.asked += texts
        return [t.upper() for t in texts]

    def back_translate(self, texts, source):
        return [t.lower() for t in texts]


def test_append_translates_only_what_the_run_lacks(tmp_path, monkeypatch):
    model = Upper()
    monkeypatch.setattr(cli, "RESULTS", tmp_path)
    monkeypatch.setattr(cli.contestants, "get", lambda name: model)
    monkeypatch.setattr(cli.po, "sources", lambda: [po.Source("Ready"), po.Source("Gone")])
    first = cli.run("upper", ["es"], None)

    monkeypatch.setattr(cli.po, "sources", lambda: [po.Source("Ready"), po.Source("New")])
    model.asked = []
    out = cli.run("upper", ["es"], None, append=first)

    assert out == first
    assert model.asked == ["New"]
    data = json.loads(out.read_text())
    assert sorted(e["key"] for e in data["entries"]) == ["New", "Ready"]
    assert data["summary"]["es"]["strings"] == 2
    assert len(data["run"]["appended"]) == 1


class Stops:
    """A scorer that is stopped (raises) when it reaches `stop_at`."""

    asked: list[str] = []
    stop_at: str | None = None

    def score(self, locale, entries):
        if locale == Stops.stop_at:
            raise KeyboardInterrupt
        Stops.asked.append(locale)
        return [{"score": len(e["text"])} for e in entries]


def test_a_stopped_score_resumes_with_the_locales_left(tmp_path, monkeypatch):
    monkeypatch.setattr(cli, "RESULTS", tmp_path)
    monkeypatch.setattr(cli.contestants, "get", lambda name: type("M", (Upper,), {"locales": ["de", "es"]})())
    monkeypatch.setattr(cli.po, "sources", lambda: [po.Source("Ready")])
    results = cli.run("upper", ["de", "es"], None)
    monkeypatch.setitem(cli.scoring.SCORERS, "metricx", Stops)

    Stops.asked, Stops.stop_at = [], "es"
    try:
        cli.score("metricx", [results], redo=False)
    except KeyboardInterrupt:
        pass
    saved = {e["locale"]: e["scores"]["metricx"]["score"] for e in json.loads(results.read_text())["entries"]}
    assert saved == {"de": 5, "es": None}

    Stops.asked, Stops.stop_at = [], None
    cli.score("metricx", [results], redo=False)
    assert Stops.asked == ["es"]
    assert not list(tmp_path.glob(".*.tmp"))
