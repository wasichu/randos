"""The app's gettext files: the English source (default.pot) and one
default.po per locale, plus a record of what the machine wrote.

Rule: the pipeline fills only empty entries. Asked to redo a language, it
replaces only entries that still hold exactly what it wrote last time
(recorded in state/<locale>.json), so a person's fix always survives.
"""

from __future__ import annotations

import json
import unicodedata
from dataclasses import dataclass, field
from pathlib import Path

import polib

from .models import NAMES

REPO = Path(__file__).resolve().parents[3]
# The catalogs the shootout fills: the website's strings and the terminal
# client's, each with its template, .po files and fill state.
CATALOGS = {"site": REPO / "priv" / "gettext", "tui": REPO / "clients" / "tui" / "priv" / "gettext"}
STATES = Path(__file__).resolve().parents[1] / "state"
GETTEXT = CATALOGS["site"]
STATE = STATES


def use(catalog: str) -> None:
    """Points sources, fill and the state at `catalog` (`CATALOGS`; the site
    by default): the CLI's `--catalog`."""
    global GETTEXT, STATE
    GETTEXT = CATALOGS[catalog]
    STATE = STATES if catalog == "site" else STATES / catalog

# The interface languages besides English: one list, `models.NAMES`
# (tests/test_po.py checks it against priv/gettext and checks' scripts).
LOCALES = list(NAMES)


@dataclass(frozen=True)
class Source:
    """One English string to translate."""

    msgid: str
    msgctxt: str | None = None
    comment: str = ""
    references: tuple[str, ...] = field(default_factory=tuple)

    @property
    def key(self) -> str:
        return f"{self.msgctxt}\x04{self.msgid}" if self.msgctxt else self.msgid

    @property
    def context(self) -> str:
        """What a translator (or a model that takes context) should know: the
        template's comment ("#."), else what the msgctxt says."""
        if self.comment:
            return self.comment
        if self.msgctxt == "button":
            return "A button label."
        return f"A {self.msgctxt} label." if self.msgctxt else ""


def sources(pot: Path | None = None) -> list[Source]:
    pot = pot or GETTEXT / "default.pot"
    return [
        Source(
            msgid=e.msgid,
            msgctxt=e.msgctxt,
            comment=e.comment or "",
            references=tuple(path for path, _line in e.occurrences),
        )
        for e in polib.pofile(str(pot))
        # Plurals are left to people: a model translates one string, but a
        # plural needs a form per plural rule of the language (msgstr[n]).
        if e.msgid and not e.obsolete and not e.msgid_plural
    ]


def po_path(locale: str, root: Path | None = None) -> Path:
    return (root or GETTEXT) / locale / "LC_MESSAGES" / "default.po"


def _save(po: polib.POFile, path: Path) -> None:
    """Saves in the layout Elixir's Gettext writes, so a fill's diff is only
    the new msgstrs: no line wrapping, one reference per "#:" line, and the
    "##" header comment as it was (polib would rewrite it as "# #")."""
    header = _leading_comments(path.read_text())
    po.wrapwidth = 0
    po.save(str(path))
    body = path.read_text().splitlines(keepends=True)
    body = body[len(_leading_comments("".join(body))) :]
    path.write_text("".join(header + [ref for line in body for ref in _one_reference_per_line(line)]))


def _one_reference_per_line(line: str) -> list[str]:
    if not line.startswith("#: "):
        return [line]
    return [f"#: {ref}\n" for ref in line[3:].split()]


def _leading_comments(text: str) -> list[str]:
    lines = text.splitlines(keepends=True)
    end = next((i for i, line in enumerate(lines) if not line.startswith("#")), len(lines))
    return lines[:end]


def _state_path(locale: str, state_dir: Path) -> Path:
    state_dir.mkdir(parents=True, exist_ok=True)
    return state_dir / f"{locale}.json"


def load_state(locale: str, state_dir: Path | None = None) -> dict:
    path = _state_path(locale, state_dir or STATE)
    return json.loads(path.read_text()) if path.exists() else {}


def fill(
    locale: str,
    translations: dict[str, str],
    model: str | dict[str, str],
    *,
    redo: bool = False,
    root: Path | None = None,
    state_dir: Path | None = None,
) -> dict[str, int]:
    """Write `translations` (Source.key -> text) into the locale's .po.

    Fills empty entries. With `redo`, also replaces entries whose current
    text is still what the machine wrote (a person's edit is never touched),
    and empties those of them that now have no translation to write (none
    passes the checks any more), so the English shows instead.
    `model` names who wrote them: one model, or one per key (per-string
    selection). Returns counts of what happened.
    """
    # One form for every letter (Vietnamese can come decomposed): the same
    # text is the same bytes, in the .po and its diffs.
    translations = {key: unicodedata.normalize("NFC", text) for key, text in translations.items()}
    path = po_path(locale, root)
    po = polib.pofile(str(path))
    state = load_state(locale, state_dir)
    counts = {"filled": 0, "redone": 0, "cleared": 0, "kept_human": 0, "kept_existing": 0}

    for entry in po:
        key = Source(entry.msgid, entry.msgctxt).key
        if not entry.msgid or entry.msgid_plural:
            continue
        machine_wrote = state.get(key, {}).get("msgstr")
        if key not in translations:
            if redo and entry.msgstr and entry.msgstr == machine_wrote:
                entry.msgstr = ""
                del state[key]
                counts["cleared"] += 1
            continue
        if not entry.msgstr:
            counts["filled"] += 1
        elif redo and entry.msgstr == machine_wrote:
            counts["redone"] += 1
        elif machine_wrote is not None and entry.msgstr != machine_wrote:
            counts["kept_human"] += 1
            continue
        else:
            counts["kept_existing"] += 1
            continue
        entry.msgstr = translations[key]
        # A fresh translation of this very msgid: a "fuzzy" left by a merge
        # (the English was reworded) no longer applies. (Gettext doesn't
        # skip fuzzy entries: a merge's guess would show as it is.)
        if "fuzzy" in entry.flags:
            entry.flags.remove("fuzzy")
        state[key] = {"msgstr": translations[key], "model": model if isinstance(model, str) else model[key]}

    _save(po, path)
    _state_path(locale, state_dir or STATE).write_text(json.dumps(state, ensure_ascii=False, indent=2, sort_keys=True) + "\n")
    return counts
