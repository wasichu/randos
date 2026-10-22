"""The app's gettext files: the English source (default.pot) and one
default.po per locale, plus a record of what the machine wrote.

Rule: the pipeline fills only empty entries. Asked to redo a language, it
replaces only entries that still hold exactly what it wrote last time
(recorded in state/<locale>.json), so a person's fix always survives.
"""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from pathlib import Path

import polib

REPO = Path(__file__).resolve().parents[3]
GETTEXT = REPO / "priv" / "gettext"
STATE = Path(__file__).resolve().parents[1] / "state"

LOCALES = ["es", "zh", "hi", "ar", "pt", "bn", "ru", "ja", "fr", "de", "ko", "it", "tr", "id"]


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


def sources(pot: Path = GETTEXT / "default.pot") -> list[Source]:
    return [
        Source(
            msgid=e.msgid,
            msgctxt=e.msgctxt,
            comment=e.comment or "",
            references=tuple(path for path, _line in e.occurrences),
        )
        for e in polib.pofile(str(pot))
        if e.msgid and not e.obsolete
    ]


def po_path(locale: str, root: Path = GETTEXT) -> Path:
    return root / locale / "LC_MESSAGES" / "default.po"


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
    return state_dir / f"{locale}.json"


def load_state(locale: str, state_dir: Path = STATE) -> dict:
    path = _state_path(locale, state_dir)
    return json.loads(path.read_text()) if path.exists() else {}


def fill(
    locale: str,
    translations: dict[str, str],
    model: str,
    *,
    redo: bool = False,
    root: Path = GETTEXT,
    state_dir: Path = STATE,
) -> dict[str, int]:
    """Write `translations` (Source.key -> text) into the locale's .po.

    Fills empty entries. With `redo`, also replaces entries whose current
    text is still what the machine wrote (a person's edit is never touched).
    Returns counts of what happened.
    """
    path = po_path(locale, root)
    po = polib.pofile(str(path))
    state = load_state(locale, state_dir)
    counts = {"filled": 0, "redone": 0, "kept_human": 0, "kept_existing": 0}

    for entry in po:
        key = Source(entry.msgid, entry.msgctxt).key
        if key not in translations or not entry.msgid:
            continue
        machine_wrote = state.get(key, {}).get("msgstr")
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
        state[key] = {"msgstr": translations[key], "model": model}

    _save(po, path)
    state_dir.mkdir(parents=True, exist_ok=True)
    _state_path(locale, state_dir).write_text(json.dumps(state, ensure_ascii=False, indent=2, sort_keys=True) + "\n")
    return counts
