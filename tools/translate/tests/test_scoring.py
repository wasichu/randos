"""The judge's reply parsing: strict, so a rambling reply is a missing
score, not a made-up one."""

from randos_translate.scoring import parse_judgement


def test_reads_the_json_asked_for():
    assert parse_judgement('{"score": 8, "reason": "natural, a bit formal"}') == {
        "score": 8,
        "reason": "natural, a bit formal",
    }


def test_finds_the_json_inside_extra_words():
    assert parse_judgement('Sure! {"score": 3, "reason": "wrong meaning"}')["score"] == 3


def test_anything_else_is_no_score():
    for reply in ["8/10", '{"score": 11}', '{"reason": "x"}', '{"score": "high"}']:
        assert parse_judgement(reply)["score"] is None
