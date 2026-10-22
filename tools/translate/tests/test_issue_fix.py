"""A translation fix from an issue: parsed, checked, and refused when it
would break something."""

import json
from pathlib import Path

import pytest

from randos_translate import issue_fix, po
from randos_translate.issue_fix import Rejected

POT = '''msgid ""
msgstr ""

msgid "Looking for a rando who speaks %{language}."
msgstr ""

msgctxt "button"
msgid "End"
msgstr ""

msgid "One call"
msgid_plural "%{count} calls"
msgstr[0] ""
msgstr[1] ""
'''

PO = '''msgid ""
msgstr ""
"Language: es\\n"

msgid "Looking for a rando who speaks %{language}."
msgstr "Buscando un rando que hable %{language}."

msgctxt "button"
msgid "End"
msgstr "Terminar"
'''


@pytest.fixture
def pot(tmp_path: Path) -> Path:
    (tmp_path / "default.pot").write_text(POT)
    path = po.po_path("es", tmp_path)
    path.parent.mkdir(parents=True)
    path.write_text(PO)
    return tmp_path / "default.pot"


def body(locale="es", english="End", context="button", current="Terminar", fix="Colgar"):
    return (
        f"### Language\n\n{locale}\n\n### English\n\n{english}\n\n### Context\n\n{context}\n\n"
        f"### Current translation\n\n{current}\n\n### Your fix\n\n{fix}\n"
    )


def test_the_form_body_is_read_by_label_and_no_response_is_empty():
    answers = issue_fix.parse_body(body(context="_No response_").replace("\n", "\r\n"))
    assert answers == {"locale": "es", "english": "End", "context": "", "current": "Terminar", "fix": "Colgar"}


def test_a_good_fix_names_its_entry(pot):
    fix = issue_fix.check(issue_fix.parse_body(body()), pot)
    assert (fix.locale, fix.msgctxt, fix.msgid, fix.msgstr) == ("es", "button", "End", "Colgar")
    assert fix.warnings == []


def test_a_capitalized_rando_goes_through_lowercased(pot):
    english = "Looking for a rando who speaks %{language}."
    fix = issue_fix.check(
        issue_fix.parse_body(body(english=english, context="", fix="Buscamos a un Rando que hable %{language}.")), pot
    )
    assert fix.msgstr == "Buscamos a un rando que hable %{language}."


def test_a_broken_placeholder_or_a_translated_rando_is_refused(pot):
    english = "Looking for a rando who speaks %{language}."
    with pytest.raises(Rejected, match="placeholders"):
        issue_fix.check(issue_fix.parse_body(body(english=english, context="", fix="Buscando un rando que hable %{idioma}.")), pot)
    with pytest.raises(Rejected, match="glossary"):
        issue_fix.check(issue_fix.parse_body(body(english=english, context="", fix="Buscando a alguien que hable %{language}.")), pot)


def test_length_and_script_only_warn(pot):
    english = "Looking for a rando who speaks %{language}."
    long = "Buscando " + "muy, " * 40 + "un rando que hable %{language}."
    fix = issue_fix.check(issue_fix.parse_body(body(english=english, context="", fix=long)), pot)
    assert any(w.startswith("length") for w in fix.warnings)


@pytest.mark.parametrize(
    ("answers", "why"),
    [
        ({"locale": "xx"}, "language code"),
        ({"locale": "@everyone"}, "The language isn't"),
        ({"english": "Gone"}, "isn't one of the site's strings"),
        ({"context": ""}, "isn't one of the site's strings"),
        ({"english": "One call", "context": ""}, "plural"),
        ({"fix": "Terminar"}, "same as the current"),
        ({"fix": ""}, "empty"),
        ({"fix": "x" * 1_001}, "longer than"),
    ],
)
def test_what_is_refused(pot, answers, why):
    with pytest.raises(Rejected, match=why):
        issue_fix.check(issue_fix.parse_body(body(**answers)), pot)


def test_main_writes_the_fix_or_the_comment(tmp_path, pot, monkeypatch):
    monkeypatch.setattr(po, "GETTEXT", pot.parent)
    monkeypatch.setattr(issue_fix.check, "__defaults__", (pot,))
    event = tmp_path / "event.json"

    event.write_text(json.dumps({"issue": {"number": 7, "body": body()}}))
    assert issue_fix.main([str(event), str(tmp_path / "ok")]) == 0
    assert json.loads((tmp_path / "ok" / "fix.json").read_text())["msgstr"] == "Colgar"
    assert (tmp_path / "ok" / "title.txt").read_text() == "Translation fix (es): End"
    pr = (tmp_path / "ok" / "pr.md").read_text()
    assert pr.startswith("Fixes #7.") and "```\nTerminar\n```" in pr and "```\nColgar\n```" in pr

    event.write_text(json.dumps({"issue": {"body": body(fix="Terminar")}}))
    assert issue_fix.main([str(event), str(tmp_path / "no")]) == 2
    assert "same as the current" in (tmp_path / "no" / "comment.md").read_text()


def test_anyones_text_stays_inside_its_code_block():
    sneaky = "a ```\nFixes #1 @everyone\n````` b"
    block = issue_fix.fenced(sneaky)
    fence = block.split("\n")[0]
    assert set(fence) == {"`"} and len(fence) == 6
    assert block == f"{fence}\n{sneaky}\n{fence}"
