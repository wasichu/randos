"""Automatic checks on one translation, none needing a human or a model.

Each returns (ok, detail). Scores from models (back-translation chrF,
MetricX, COMET-Kiwi, the tone judge) live in scoring.py.
"""

from __future__ import annotations

import re
import unicodedata

PLACEHOLDER = re.compile(r"%\{[a-z_]+\}")
# Kept as is in every language (see priv/gettext/README.md).
GLOSSARY = ["randos", "rando"]

# The scripts a locale's text should be written in (Unicode script names,
# from the character names), besides the Latin of placeholders and the
# glossary.
SCRIPTS = {
    "zh": {"CJK"},
    "ja": {"CJK", "HIRAGANA", "KATAKANA"},
    "ko": {"HANGUL"},
    "ar": {"ARABIC"},
    "hi": {"DEVANAGARI"},
    "bn": {"BENGALI"},
    "ru": {"CYRILLIC"},
}
LATIN_LOCALES = {"es", "pt", "fr", "de", "it", "tr", "id"}


def placeholders(source: str, text: str) -> tuple[bool, str]:
    want, got = sorted(PLACEHOLDER.findall(source)), sorted(PLACEHOLDER.findall(text))
    return (want == got, "" if want == got else f"expected {want}, got {got}")


def glossary(source: str, text: str) -> tuple[bool, str]:
    missing = [term for term in GLOSSARY if term in source.lower() and term not in text.lower()]
    # "randos" contains "rando": count each source term once.
    if "randos" in source.lower() and "randos" in text.lower():
        missing = [t for t in missing if t != "rando"]
    return (not missing, "" if not missing else f"missing {missing}")


def length(source: str, text: str, *, button: bool = False) -> tuple[bool, str]:
    """Sane length: not empty, not wildly longer or shorter than the English.
    Buttons get a tighter limit (they must fit)."""
    if not text.strip():
        return (False, "empty")
    ratio = len(text) / max(len(source), 1)
    high = 2.0 if button else 3.0
    ok = 0.25 <= ratio <= high or len(source) < 8
    return (ok, "" if ok else f"length ratio {ratio:.2f}")


def _script(char: str) -> str | None:
    if not char.isalpha():
        return None
    name = unicodedata.name(char, "")
    for script in ("CJK", "HIRAGANA", "KATAKANA", "HANGUL", "ARABIC", "DEVANAGARI", "BENGALI", "CYRILLIC", "LATIN"):
        if name.startswith(script):
            return script
    return "OTHER"


def _letters(text: str) -> list[str]:
    stripped = PLACEHOLDER.sub("", text)
    for term in GLOSSARY:
        stripped = re.sub(term, "", stripped, flags=re.IGNORECASE)
    return [s for s in map(_script, stripped) if s]


def script(locale: str, text: str, source: str | None = None) -> tuple[bool, str]:
    """The letters are in the locale's script (ignoring placeholders and the
    glossary terms, which stay Latin). A translation with no letters at all
    fails when the source has some (a model that answered "& & &")."""
    letters = _letters(text)
    if not letters:
        ok = source is None or not _letters(source)
        return (ok, "" if ok else "no letters")
    if locale in LATIN_LOCALES:
        share = sum(s == "LATIN" for s in letters) / len(letters)
    else:
        share = sum(s in SCRIPTS[locale] for s in letters) / len(letters)
    ok = share >= 0.8
    return (ok, "" if ok else f"only {share:.0%} of letters in the {locale} script")


def run_all(locale: str, source: str, text: str, *, button: bool = False) -> dict[str, dict]:
    results = {
        "placeholders": placeholders(source, text),
        "glossary": glossary(source, text),
        "length": length(source, text, button=button),
        "script": script(locale, text, source),
    }
    return {name: {"ok": ok, "detail": detail} for name, (ok, detail) in results.items()}
