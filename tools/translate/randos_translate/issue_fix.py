"""A translation fix from a GitHub issue (.github/ISSUE_TEMPLATE/translation.yml),
checked before anything is written.

    python -m randos_translate.issue_fix EVENT.json OUT_DIR

reads the issue event the Action gets ($GITHUB_EVENT_PATH) and writes, to
OUT_DIR, either `fix.json` (what `mix randos.translation_fix` applies) with
the pull request's `title.txt` and `pr.md`, and exits 0, or `comment.md` (why
the fix can't be applied, for the issue) and exits 2. Nothing from the issue passes
through a shell: the workflow only hands over the event file.

The fix is checked like a machine translation (checks.py). A broken
placeholder or a translated "rando" stops it; length and script only warn,
for the reviewer. It writes no state, so the fix counts as a person's and
a later machine run keeps it (po.fill's rule).
"""

from __future__ import annotations

import json
import sys
from dataclasses import dataclass, field
from pathlib import Path

import polib

from randos_translate import checks, po

# The form's labels, as they head each answer in the issue body.
LABELS = {
    "Language": "locale",
    "English": "english",
    "Context": "context",
    "Current translation": "current",
    "Your fix": "fix",
}
NO_RESPONSE = "_No response_"
MAX_FIX = 1_000
# A fix that fails these would break the page or the name; the others are
# the reviewer's call.
BLOCKING = {"placeholders", "glossary"}


@dataclass
class Fix:
    locale: str
    msgid: str
    msgctxt: str | None
    msgstr: str
    current: str = ""
    warnings: list[str] = field(default_factory=list)


class Rejected(Exception):
    """The fix can't be applied; the message says why, for the issue."""


def parse_body(body: str) -> dict[str, str]:
    """An issue form's answers by field id ("### Label" then the answer)."""
    answers: dict[str, list[str]] = {}
    current = None
    for line in body.replace("\r\n", "\n").split("\n"):
        if line.startswith("### "):
            current = LABELS.get(line[4:].strip())
            if current:
                answers[current] = []
        elif current:
            answers[current].append(line)
    parsed = {key: "\n".join(lines).strip() for key, lines in answers.items()}
    return {key: ("" if value == NO_RESPONSE else value) for key, value in parsed.items()}


def check(answers: dict[str, str], pot: Path = po.GETTEXT / "default.pot") -> Fix:
    locale = answers.get("locale", "").strip().lower()
    english = answers.get("english", "")
    context = answers.get("context", "").strip() or None
    text = answers.get("fix", "")

    if locale not in po.LOCALES:
        # Echo only something that can't be markup or a mention.
        shown = f"`{locale}`" if locale.isalpha() and len(locale) <= 8 else "The language"
        raise Rejected(f"{shown} isn't one of the site's language codes ({', '.join(po.LOCALES)}).")
    if not text:
        raise Rejected("The fix is empty.")
    if len(text) > MAX_FIX:
        raise Rejected(f"The fix is longer than {MAX_FIX} characters.")

    entry = next(
        (e for e in polib.pofile(str(pot)) if e.msgid == english and e.msgctxt == context and not e.obsolete),
        None,
    )
    if entry is None:
        raise Rejected(
            "The English text (with its context) isn't one of the site's strings any more, or it was changed. "
            "Please start again from the translations page."
        )
    if entry.msgid_plural:
        raise Rejected("This text has plural forms, which this form can't edit yet; a maintainer will apply it by hand.")

    current = next((e.msgstr for e in polib.pofile(str(po.po_path(locale, pot.parent))) if e.msgid == english and e.msgctxt == context), "")
    if text == current:
        raise Rejected("The fix is the same as the current translation.")

    results = checks.run_all(locale, english, text, button=context == "button")
    blocking = [f"{name}: {r['detail']}" for name, r in results.items() if name in BLOCKING and not r["ok"]]
    if blocking:
        raise Rejected("The fix doesn't pass the checks every translation must:\n\n" + "\n".join(f"- {b}" for b in blocking))

    warnings = [f"{name}: {r['detail']}" for name, r in results.items() if name not in BLOCKING and not r["ok"]]
    return Fix(locale=locale, msgid=english, msgctxt=context, msgstr=text, current=current, warnings=warnings)


def fenced(text: str) -> str:
    """`text` in a code block nothing inside can close: anyone's text shows
    as text, never as markup, a mention, or a "Fixes #n"."""
    longest = max((len(run) for run in text.split("\n") for run in _backtick_runs(run)), default=0)
    fence = "`" * max(3, longest + 1)
    return f"{fence}\n{text}\n{fence}"


def _backtick_runs(line: str) -> list[str]:
    runs, run = [], ""
    for char in line:
        if char == "`":
            run += char
        elif run:
            runs.append(run)
            run = ""
    return runs + ([run] if run else [])


def title(fix: Fix) -> str:
    # Only checked values: a site language and one of the site's own strings.
    english = fix.msgid if len(fix.msgid) <= 50 else fix.msgid[:49] + "…"
    return f"Translation fix ({fix.locale}): {english}"


def pr_body(fix: Fix, issue: int) -> str:
    context = f" (context `{fix.msgctxt}`)" if fix.msgctxt else ""
    warnings = (
        "\n\n**For the reviewer:** the checks flagged\n\n" + "\n".join(f"- {w}" for w in fix.warnings)
        if fix.warnings
        else ""
    )
    return (
        f"Fixes #{issue}.\n\nLanguage: `{fix.locale}`{context}\n\n"
        f"English:\n\n{fenced(fix.msgid)}\n\nNow:\n\n{fenced(fix.current) if fix.current else '(not translated yet)'}\n\n"
        f"Suggested:\n\n{fenced(fix.msgstr)}{warnings}\n\n"
        "Checked by the workflow (placeholders, glossary, and the .po compiling). "
        "CI doesn't run on pull requests the workflow opens; it runs on main after merging.\n"
    )


def main(argv: list[str]) -> int:
    event_path, out_dir = Path(argv[0]), Path(argv[1])
    out_dir.mkdir(parents=True, exist_ok=True)
    issue = json.loads(event_path.read_text()).get("issue") or {}
    body = issue.get("body") or ""

    try:
        fix = check(parse_body(body))
    except Rejected as why:
        (out_dir / "comment.md").write_text(
            f"Thanks! This couldn't be turned into a pull request automatically:\n\n{why}\n\n"
            "Edit the issue to try again, or a maintainer will take a look.\n"
        )
        return 2

    (out_dir / "fix.json").write_text(json.dumps(fix.__dict__, ensure_ascii=False, indent=2) + "\n")
    (out_dir / "title.txt").write_text(title(fix))
    (out_dir / "pr.md").write_text(pr_body(fix, int(issue.get("number", 0))))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
