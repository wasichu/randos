"""`run --append`: a run topped up after the template changed translates
only the new strings and drops the ones the template no longer has."""

import json

from randos_translate import cli, po


class Upper:
    name = "upper"
    locales = ["es"]

    def __init__(self):
        self.asked = []
        self.contexts = []

    def translate(self, texts, target, contexts=None):
        self.asked += texts
        self.contexts += contexts or []
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


def test_append_adds_new_locales_to_the_run(tmp_path, monkeypatch):
    model = type("M", (Upper,), {"locales": ["es", "vi"]})()
    monkeypatch.setattr(cli, "RESULTS", tmp_path)
    monkeypatch.setattr(cli.contestants, "get", lambda name: model)
    monkeypatch.setattr(cli.po, "sources", lambda: [po.Source("Ready")])
    first = cli.run("upper", ["es"], None)

    model.asked = []
    cli.run("upper", ["vi"], None, append=first)
    assert model.asked == ["Ready"]
    data = json.loads(first.read_text())
    assert data["run"]["locales"] == ["es", "vi"]
    assert set(data["summary"]) == {"es", "vi"}


def test_a_changed_comment_retranslates_only_for_a_model_that_takes_context(tmp_path, monkeypatch):
    monkeypatch.setattr(cli, "RESULTS", tmp_path)
    monkeypatch.setattr(cli.po, "sources", lambda: [po.Source("About"), po.Source("Cancel")])
    reader = type("Reads", (Upper,), {"takes_context": True})()
    monkeypatch.setattr(cli.contestants, "get", lambda name: reader)
    first = cli.run("upper", ["es"], None)

    about = po.Source("About", comment="The page that explains randos")
    monkeypatch.setattr(cli.po, "sources", lambda: [about, po.Source("Cancel")])
    reader.asked, reader.contexts = [], []
    cli.run("upper", ["es"], None, append=first)
    assert reader.asked == ["About"]
    assert reader.contexts == ["The page that explains randos"]
    entries = json.loads(first.read_text())["entries"]
    assert sorted((e["key"], e["context"]) for e in entries) == [
        ("About", "The page that explains randos"),
        ("Cancel", ""),
    ]

    # A seq2seq model can't use the comment: nothing to redo.
    plain = Upper()
    monkeypatch.setattr(cli.contestants, "get", lambda name: plain)
    monkeypatch.setattr(cli.po, "sources", lambda: [po.Source("About"), po.Source("Cancel")])
    second = cli.run("upper", ["es"], None)
    monkeypatch.setattr(cli.po, "sources", lambda: [about, po.Source("Cancel")])
    cli.run("upper", ["es"], None, append=second)
    assert plain.asked == ["About", "Cancel"]


def test_every_output_goes_through_tidy(tmp_path, monkeypatch):
    class Capitalizes(Upper):
        def translate(self, texts, target, contexts=None):
            return ["Randos est un lieu..." for _ in texts]

    monkeypatch.setattr(cli, "RESULTS", tmp_path)
    monkeypatch.setattr(cli.contestants, "get", lambda name: Capitalizes())
    monkeypatch.setattr(cli.po, "sources", lambda: [po.Source("randos is a place…")])
    out = cli.run("upper", ["es"], None)
    assert json.loads(out.read_text())["entries"][0]["text"] == "randos est un lieu…"


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


def test_fill_best_fills_each_strings_pick_with_its_model(tmp_path, monkeypatch):
    def row(key, best, translations):
        return {"key": key, "best": best, "translations": {m: {"text": t} for m, t in translations.items()}}

    review_json = {
        "locales": {
            "es": {
                "strings": [
                    row("About", "opus-mt", {"opus-mt": "Acerca de", "m2m100": "Sobre"}),
                    row("Mute", None, {"m2m100": "Muerte"}),
                ]
            }
        }
    }
    (tmp_path / "review.json").write_text(json.dumps(review_json))
    calls = []
    monkeypatch.setattr(cli.po, "fill", lambda *args, **kwargs: calls.append((args, kwargs)) or {"filled": 1})

    assert cli.fill_best("es", False, tmp_path) == {"filled": 1}
    # Nothing picked for "Mute" (none passed): it isn't filled, so the English shows.
    assert calls == [(("es", {"About": "Acerca de"}, {"About": "opus-mt"}), {"redo": False})]


def test_tidy_rewrites_old_runs_and_counts_what_changed(tmp_path):
    run = tmp_path / "old.json"
    entries = [{"msgid": "Looking…", "text": "Buscando..."}, {"msgid": "About", "text": "Acerca de"}]
    run.write_text(json.dumps({"entries": entries}))
    assert cli.tidy([run]) == {"old.json": 1}
    assert [e["text"] for e in json.loads(run.read_text())["entries"]] == ["Buscando…", "Acerca de"]
