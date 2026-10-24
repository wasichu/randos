from randos_translate import review

OK = {"ok": True, "detail": ""}


def entry(key, locale, text, chrf, metricx=None, failed=None):
    checks = {name: OK for name in ("placeholders", "glossary", "length", "script")}
    if failed:
        checks[failed] = {"ok": False, "detail": "expected ['%{time}'], got []"}
    return {
        "key": key,
        "msgid": key,
        "msgctxt": None,
        "locale": locale,
        "text": text,
        "back_translation": key,
        "checks": checks,
        "scores": {
            "chrf": chrf,
            "metricx": {"score": metricx, "pending": None if metricx is not None else "not run"},
            "comet_kiwi": {"score": None, "pending": "not run"},
            "judge": {"score": None, "pending": "not run"},
        },
    }


def run(model, at, entries):
    return {"run": {"model": model, "locales": ["es"], "strings": len(entries), "at": at}, "entries": entries}


def test_strings_where_models_disagree_come_first():
    data = review.build(
        [
            run("a", "1", [entry("End", "es", "Terminar", 80), entry("Mute", "es", "Silenciar", 90)]),
            run("b", "2", [entry("End", "es", "Colgar la llamada", 60), entry("Mute", "es", "Silenciar", 85)]),
        ]
    )
    rows = data["locales"]["es"]["strings"]
    assert [r["key"] for r in rows] == ["End", "Mute"]
    assert rows[0]["disagreement"] > 0.5
    assert rows[1]["disagreement"] == 0.0
    assert rows[0]["translations"]["b"]["text"] == "Colgar la llamada"


def test_evaluators_disagreeing_on_the_best_model_is_flagged():
    # chrF prefers a, MetricX (lower is better) prefers b.
    data = review.build(
        [
            run("a", "1", [entry("End", "es", "Terminar", 90, metricx=9.0)]),
            run("b", "2", [entry("End", "es", "Colgar", 60, metricx=1.0)]),
        ]
    )
    row = data["locales"]["es"]["strings"][0]
    assert row["translations"]["a"]["ranks"] == {"chrf": 1, "metricx": 2}
    assert row["conflict"]["first_by"] and row["conflict"]["last_by"]
    # One scorer alone can't conflict.
    single = review.build([run("a", "1", [entry("End", "es", "Terminar", 90)]), run("b", "2", [entry("End", "es", "Colgar", 60)])])
    assert single["locales"]["es"]["strings"][0]["conflict"] is None


def test_failed_checks_are_listed_and_never_win():
    data = review.build(
        [
            run("a", "1", [entry("%{time} left", "es", "quedan", 95, failed="placeholders")]),
            run("b", "2", [entry("%{time} left", "es", "quedan %{time}", 70)]),
        ]
    )
    row = data["locales"]["es"]["strings"][0]
    assert row["translations"]["a"]["failed"][0]["check"] == "placeholders"
    assert row["best"] == "b"
    assert data["locales"]["es"]["winner"]["model"] == "b"


def test_the_latest_run_of_a_model_wins():
    data = review.build(
        [
            run("a", "2", [entry("End", "es", "Terminar", 90)]),
            run("a", "1", [entry("End", "es", "Acabar", 50)]),
            run("b", "3", [entry("End", "es", "Colgar", 60)]),
        ]
    )
    assert data["locales"]["es"]["strings"][0]["translations"]["a"]["text"] == "Terminar"
    assert [r["at"] for r in data["runs"]] == ["1", "2", "3"]


def test_when_only_a_final_full_stop_fails_the_best_ships_without_it():
    msgid = "your rando's connection dropped; waiting for them to come back"

    def ja(text, metricx):
        e = entry(msgid, "ja", text, 50, metricx=metricx)
        e["scores"]["comet_kiwi"] = {"score": 0.8, "pending": None}
        return e

    data = review.build(
        [
            run("a", "1", [ja("あなたのrandoの接続が切れました。再接続を待っています。", 2.0)]),
            # Without "rando" it fails a second check: still never ships.
            run("b", "2", [ja("相手の接続が切断されました。再接続を待っています。", 1.0)]),
        ]
    )
    row = data["locales"]["ja"]["strings"][0]
    assert row["best"] == "a"
    assert row["best_text"] == "あなたのrandoの接続が切れました。再接続を待っています"
    assert "full stop" in row["best_why"]
    # The page still shows what the model wrote.
    assert row["translations"]["a"]["text"].endswith("。")


def test_a_translation_passing_as_it_is_ships_as_it_is():
    data = review.build([run("a", "1", [entry("End", "es", "Terminar", 90)])])
    assert data["locales"]["es"]["strings"][0]["best_text"] == "Terminar"
