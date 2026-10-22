"""The fill rule: empty entries are filled; a person's fix always survives,
even a redo."""

from pathlib import Path

import polib

from randos_translate import po

PO = '''msgid ""
msgstr ""
"Language: es\\n"

msgid "Ready"
msgstr ""

msgctxt "button"
msgid "End"
msgstr ""

msgid "Looking"
msgstr "Buscando (a person wrote this)"
'''


def setup(tmp_path: Path) -> tuple[Path, Path]:
    root, state = tmp_path / "gettext", tmp_path / "state"
    path = po.po_path("es", root)
    path.parent.mkdir(parents=True)
    path.write_text(PO)
    return root, state


def entries(root: Path) -> dict[str, str]:
    return {po.Source(e.msgid, e.msgctxt).key: e.msgstr for e in polib.pofile(str(po.po_path("es", root)))}


def test_fills_only_empty_entries(tmp_path):
    root, state = setup(tmp_path)
    end = po.Source("End", "button").key
    counts = po.fill("es", {"Ready": "Listo", end: "Fin", "Looking": "Buscando"}, "m1", root=root, state_dir=state)

    assert counts == {"filled": 2, "redone": 0, "cleared": 0, "kept_human": 0, "kept_existing": 1}
    assert entries(root) == {"Ready": "Listo", end: "Fin", "Looking": "Buscando (a person wrote this)"}


def test_a_redo_replaces_machine_text_but_never_a_persons_fix(tmp_path):
    root, state = setup(tmp_path)
    po.fill("es", {"Ready": "Listo", "Looking": "x"}, "m1", root=root, state_dir=state)

    # Someone fixes the machine's "Listo".
    path = po.po_path("es", root)
    path.write_text(path.read_text().replace('msgstr "Listo"', 'msgstr "Preparado"'))
    end = po.Source("End", "button").key
    po.fill("es", {end: "Fin"}, "m1", root=root, state_dir=state)

    counts = po.fill("es", {"Ready": "Listo 2", end: "Terminar"}, "m2", redo=True, root=root, state_dir=state)
    assert counts == {"filled": 0, "redone": 1, "cleared": 0, "kept_human": 1, "kept_existing": 0}
    assert entries(root)["Ready"] == "Preparado"
    assert entries(root)[end] == "Terminar"


def test_a_fill_changes_only_the_msgstrs(tmp_path):
    # The layout Elixir's Gettext writes: a "##" header, one reference per
    # line, long strings unwrapped. A fill must leave all of it alone.
    long = "A conversation lasts %{call} minutes. " * 3
    head = '## "msgid"s in this file come from POT (.pot) files.\n###\nmsgid ""\nmsgstr ""\n"Language: es\\n"\n"Plural-Forms: nplurals=2; plural=(n != 1);\\n"\n\n'

    def entry(msgstr: str) -> str:
        return f'#: lib/a.ex\n#: lib/b.ex\n#, elixir-autogen, elixir-format\nmsgid "{long}"\nmsgstr "{msgstr}"\n'

    root, state = tmp_path / "gettext", tmp_path / "state"
    path = po.po_path("es", root)
    path.parent.mkdir(parents=True)
    path.write_text(head + entry(""))

    po.fill("es", {long: "Una conversación"}, "m1", root=root, state_dir=state)
    assert path.read_text() == head + entry("Una conversación")


def test_a_redo_empties_machine_text_that_no_longer_passes(tmp_path):
    root, state = setup(tmp_path)
    end = po.Source("End", "button").key
    po.fill("es", {"Ready": "Listo", end: "Fin"}, {"Ready": "m1", end: "m2"}, root=root, state_dir=state)
    assert po.load_state("es", state)[end] == {"msgstr": "Fin", "model": "m2"}

    # The new pick has nothing for "Ready" (every candidate fails a check now).
    counts = po.fill("es", {end: "Terminar"}, {end: "m3"}, redo=True, root=root, state_dir=state)
    assert counts["cleared"] == 1 and counts["redone"] == 1
    assert entries(root)["Ready"] == ""
    assert entries(root)["Looking"] == "Buscando (a person wrote this)"
    assert "Ready" not in po.load_state("es", state)


def test_a_filled_entry_is_no_longer_fuzzy(tmp_path):
    root, state = tmp_path / "gettext", tmp_path / "state"
    path = po.po_path("es", root)
    path.parent.mkdir(parents=True)
    path.write_text(PO.replace('msgid "Ready"', '#, elixir-format, fuzzy\nmsgid "Ready"'))

    po.fill("es", {"Ready": "Listo"}, "m1", root=root, state_dir=state)
    entry = next(e for e in polib.pofile(str(path)) if e.msgid == "Ready")
    assert entry.msgstr == "Listo"
    assert entry.flags == ["elixir-format"]


def test_the_source_strings_come_from_the_real_template():
    keys = [s.key for s in po.sources()]
    assert "About" in keys
    assert po.Source("End", "button").key in keys
    assert all("randos" != s.msgid for s in po.sources())


def test_plural_strings_are_left_to_people(tmp_path):
    pot = tmp_path / "default.pot"
    pot.write_text(
        'msgid ""\nmsgstr ""\n\nmsgid "Ready"\nmsgstr ""\n\n'
        'msgid "one language"\nmsgid_plural "%{count} languages"\nmsgstr[0] ""\nmsgstr[1] ""\n'
    )
    assert [s.msgid for s in po.sources(pot)] == ["Ready"]

    # ...and fill leaves one alone even when a run (an old one) has it.
    root, state = tmp_path / "gettext", tmp_path / "state"
    path = po.po_path("es", root)
    path.parent.mkdir(parents=True)
    path.write_text(pot.read_text())
    counts = po.fill("es", {"Ready": "Listo", "one language": "un idioma"}, "m1", root=root, state_dir=state)
    assert counts["filled"] == 1
    plural = next(e for e in polib.pofile(str(path)) if e.msgid_plural)
    assert plural.msgstr == "" and not any(plural.msgstr_plural.values())
