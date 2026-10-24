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
    "ur": {"ARABIC"},
    "fa": {"ARABIC"},
}
LATIN_LOCALES = {"es", "pt", "fr", "de", "it", "tr", "id", "vi", "sw", "fil"}


def placeholders(source: str, text: str) -> tuple[bool, str]:
    want, got = sorted(PLACEHOLDER.findall(source)), sorted(PLACEHOLDER.findall(text))
    return (want == got, "" if want == got else f"expected {want}, got {got}")


_LATIN = r"A-Za-z\u00C0-\u024F"

# Turkish adds its suffixes to the word ("randoyu", "randolar"), Filipino
# its linker ("randong kausap"); elsewhere a Latin letter after the term
# makes another word ("randonnée", a hike).
_SUFFIXED = {"tr", "fil"}


def _has_term(term: str, text: str, locale: str | None = None) -> bool:
    """The term as a word of its own, not part of another: no Latin letter
    just before it ("esperando" holds "rando") or after it, but a plural
    "s" ("randos"); in Turkish, any suffix. Other scripts around it are
    fine ("あなたのrandoを", "rando-এর")."""
    after = "" if locale in _SUFFIXED else rf"s?(?![{_LATIN}])"
    return re.search(rf"(?<![{_LATIN}]){term}{after}", text) is not None


def glossary(source: str, text: str, locale: str | None = None) -> tuple[bool, str]:
    """The terms are kept exactly, lowercase included: randos is a name and
    always lowercase, even starting a sentence ("Randos est..." fails)."""
    missing = [term for term in GLOSSARY if term in source.lower() and not _has_term(term, text, locale)]
    # "randos" contains "rando": count each source term once.
    if "randos" in source.lower() and (
        _has_term("randos", text, locale) or "rando" not in source.lower().replace("randos", "")
    ):
        missing = [t for t in missing if t != "rando"]
    if not missing:
        return (True, "")
    capitalized = [t for t in missing if _has_term(t, text.lower(), locale)]
    return (False, f"capitalized {capitalized}" if capitalized == missing else f"missing {missing}")


# Chinese, Japanese and Korean write in far fewer characters than English
# ("connecting" -> "连接", 0.2), so their floor is lower.
DENSE_LOCALES = {"zh", "ja", "ko"}


def length(source: str, text: str, *, button: bool = False, locale: str | None = None) -> tuple[bool, str]:
    """Sane length: not empty, not wildly longer or shorter than the English.
    Buttons get a tighter limit (they must fit)."""
    if not text.strip():
        return (False, "empty")
    ratio = len(text) / max(len(source), 1)
    low = 0.1 if locale in DENSE_LOCALES else 0.25
    high = 2.0 if button else 3.0
    ok = low <= ratio <= high or len(source) < 8
    return (ok, "" if ok else f"length ratio {ratio:.2f}")


def _script(char: str) -> str | None:
    if not char.isalpha():
        return None
    name = unicodedata.name(char, "")
    for script in ("CJK", "HIRAGANA", "KATAKANA", "HANGUL", "ARABIC", "DEVANAGARI", "BENGALI", "CYRILLIC", "LATIN"):
        if name.startswith(script):
            return script
    return "OTHER"


_WORD = re.compile(r"[A-Za-z][A-Za-z0-9.+-]*")


def _letters(text: str, keep: set[str] = frozenset()) -> list[str]:
    """The script of each letter, leaving out placeholders, the glossary,
    and the words in `keep` (names copied from the English, like GitHub)."""
    stripped = PLACEHOLDER.sub("", text)
    for term in GLOSSARY:
        stripped = re.sub(term, "", stripped, flags=re.IGNORECASE)
    stripped = _WORD.sub(lambda m: "" if m.group(0) in keep else m.group(0), stripped)
    return [s for s in map(_script, stripped) if s]


def script(locale: str, text: str, source: str | None = None) -> tuple[bool, str]:
    """The letters are in the locale's script (ignoring placeholders, the
    glossary terms, and Latin words copied as they are from the English,
    such as GitHub or UDP). A translation with no letters at all fails when
    the source has some (a model that answered "& & &")."""
    copied = set(_WORD.findall(source)) if source and locale not in LATIN_LOCALES else set()
    letters = _letters(text, copied)
    if not letters:
        ok = source is None or not _letters(source)
        return (ok, "" if ok else "no letters")
    if locale in LATIN_LOCALES:
        share = sum(s == "LATIN" for s in letters) / len(letters)
    else:
        share = sum(s in SCRIPTS[locale] for s in letters) / len(letters)
    ok = share >= 0.8
    return (ok, "" if ok else f"only {share:.0%} of letters in the {locale} script")


_LEFTOVER_TOKEN = re.compile(r"[\[(]\d+[\])]")
# Full stops and exclamation marks, Latin and CJK/Devanagari/Arabic ones.
_SENTENCE_END = (".", "!", "。", "！", "।", "۔")
_ANY_END = (".", "!", "?", ":", "…", ")", "”", '"')


def shape(source: str, text: str) -> tuple[bool, str]:
    """One translation, shaped like the source: no line breaks the English
    hasn't (a model listing alternatives, "…\\noder\\n…"), and no `protect`
    token left behind ("[0]", or a model's rewrite of it, "(0)")."""
    if text.count("\n") > source.count("\n"):
        return (False, "line breaks the source doesn't have (alternatives?)")
    # A heading or label stays one ("About randos" -> "Über randos", not "Über randos.").
    if text.rstrip().endswith(_SENTENCE_END) and not source.rstrip().endswith(_ANY_END):
        return (False, "ends a sentence the source doesn't")
    leftover = [t for t in _LEFTOVER_TOKEN.findall(text) if t not in source]
    return (not leftover, "" if not leftover else f"leftover tokens {leftover}")


def without_final_stop(source: str, text: str) -> str:
    """`text` without a final full stop `source` doesn't end with (what
    `shape` rejects): for `review.pick`'s fallback, since Japanese and
    Korean end a clause with one where English leaves it bare."""
    if source.rstrip().endswith(_ANY_END):
        return text
    return text.rstrip().rstrip("".join(_SENTENCE_END)).rstrip()


def unchanged(source: str, text: str) -> tuple[bool, str]:
    """Not the English left as it was. Only for a source of three words or
    more: a short label can rightly stay the same ("Status" in German)."""
    if len(PLACEHOLDER.sub("", source).split()) < 3:
        return (True, "")
    same = " ".join(source.split()).casefold() == " ".join(text.split()).casefold()
    return (not same, "the English, untranslated" if same else "")


# Urdu and Persian write YEH and KEHEH (U+06CC, U+06A9), not Arabic's YEH
# and KAF (U+064A, U+0643), which look alike: a common slip, and a sign of
# Arabic text.
_ARABIC_FORMS = {"\u064a": "ARABIC LETTER YEH", "\u0643": "ARABIC LETTER KAF"}


def letter_forms(locale: str, text: str) -> tuple[bool, str]:
    if locale not in ("ur", "fa"):
        return (True, "")
    found = [name for char, name in _ARABIC_FORMS.items() if char in text]
    return (not found, f"Arabic letter forms: {', '.join(found)}" if found else "")


_NUMBER = re.compile(r"\d+")


def _numbers(text: str) -> set[str]:
    """The numbers in a text, outside placeholders, in ASCII digits (so a
    Persian ۱۸ is 18)."""
    return {"".join(str(unicodedata.digit(c)) for c in n) for n in _NUMBER.findall(PLACEHOLDER.sub("", text))}


# English number words count as their numbers: "at least one" may be 1つ.
_WORDS = dict(
    zip("one two three four five six seven eight nine ten eleven twelve".split(), map(str, range(1, 13)), strict=True)
)


def numbers(source: str, text: str) -> tuple[bool, str]:
    """No number the English doesn't have (\"%{minutes}+\" as \"%{minutes} + 1\")."""
    spelled = {_WORDS[w] for w in re.findall(r"[a-z]+", source.lower()) if w in _WORDS}
    extra = sorted(_numbers(text) - _numbers(source) - spelled)
    return (not extra, f"numbers not in the source: {extra}" if extra else "")


def run_all(locale: str, source: str, text: str, *, button: bool = False) -> dict[str, dict]:
    results = {
        "placeholders": placeholders(source, text),
        "glossary": glossary(source, text, locale),
        "length": length(source, text, button=button, locale=locale),
        "script": script(locale, text, source),
        "shape": shape(source, text),
        "unchanged": unchanged(source, text),
        "letter_forms": letter_forms(locale, text),
        "numbers": numbers(source, text),
    }
    return {name: {"ok": ok, "detail": detail} for name, (ok, detail) in results.items()}
