"""The contestants, behind one interface:
`translate(texts, target, contexts) -> list`.

Seq2seq models can't follow instructions, so `protect`/`restore` swap
placeholders and glossary terms for tokens they pass through untouched;
the checks then show which models still damage them. Instruction models
(Hy-MT2, TranslateGemma) get the same rules in their prompt, and each
string's context (its translator comment, `po.Source.context`), which the
seq2seq models can't take: per-string selection then prefers whichever
contestant got the sense right.

Every contestant's output then goes through `brand_case`.
"""

from __future__ import annotations

import re
import unicodedata
from typing import Protocol

from ..checks import GLOSSARY, PLACEHOLDER


class Translator(Protocol):
    name: str
    locales: list[str]

    def translate(self, texts: list[str], target: str, contexts: list[str] | None = None) -> list[str]: ...

    def back_translate(self, texts: list[str], source: str) -> list[str]: ...


# Our 19 practice languages besides English, by the English names the
# instruction models' prompts use (Chinese: the site is in Simplified).
NAMES = {
    "es": "Spanish",
    "zh": "Simplified Chinese",
    "hi": "Hindi",
    "ar": "Arabic",
    "pt": "Portuguese",
    "bn": "Bengali",
    "ru": "Russian",
    "ja": "Japanese",
    "fr": "French",
    "de": "German",
    "ko": "Korean",
    "it": "Italian",
    "tr": "Turkish",
    "id": "Indonesian",
    "vi": "Vietnamese",
    "ur": "Urdu",
    "sw": "Swahili",
    "fa": "Persian",
    "fil": "Filipino",
}

_TOKEN = re.compile(r"\[(\d+)\]")


def protect(text: str) -> tuple[str, list[str]]:
    """Replaces placeholders and glossary terms with [0], [1], ..."""
    kept: list[str] = []

    def keep(match: re.Match) -> str:
        kept.append(match.group(0))
        return f"[{len(kept) - 1}]"

    pattern = re.compile("|".join([PLACEHOLDER.pattern] + [rf"\b{t}\b" for t in GLOSSARY]), re.IGNORECASE)
    return pattern.sub(keep, text), kept


def restore(text: str, kept: list[str]) -> str:
    return _TOKEN.sub(lambda m: kept[int(m.group(1))] if int(m.group(1)) < len(kept) else m.group(0), text)


# "rando"/"randos" at the start of a word, in any case, but not "random".
_BRAND = re.compile(r"\brando(?!m)s?", re.IGNORECASE)


def brand_case(text: str) -> str:
    """randos is a name and always lowercase, even starting a sentence
    ("Randos est..." -> "randos est..."), with a suffix ("Randoslar") or a
    particle ("Randosは") attached: what `restore` guarantees the seq2seq
    models, for every contestant."""
    return _BRAND.sub(lambda m: m.group(0).lower(), text)


# The name written in Arabic letters ("راندو", "الراندوس"): back to the
# name, which the glossary keeps in Latin letters.
# The name as models spell it in other scripts (counted in the stored runs,
# 2026-10-24), each a whole word: the plural ending (group 1) makes it
# "randos"; a word that goes on (Bengali's possessive "র্যান্ডোর", Hindi's
# "रैंडम", random) is left alone. Arabic with its article, Urdu's two
# spellings, Hindi, and Bengali with or without the zero-width joiner.
_SCRIPT_BRANDS = [
    re.compile(r"(?:ال)?راندو(س)?(?![\u0600-\u06FF])"),
    re.compile(r"(?:رانڈو|رینڈو)(س|ز)?(?![\u0600-\u06FF])"),
    re.compile(r"रैंडो(स)?(?![\u0900-\u097F])"),
    re.compile(r"(?:র\u200d?্যান্ডো|রান্ডো)(স)?(?![\u0980-\u09FF])"),
]


def script_brand(text: str) -> str:
    """randos/rando transliterated into Arabic, Urdu, Hindi or Bengali
    script, written back as the name (models do it although the glossary
    says not to)."""
    for pattern in _SCRIPT_BRANDS:
        text = pattern.sub(lambda m: "randos" if m.group(1) else "rando", text)
    return text


def ellipsis(source: str, text: str) -> str:
    """The source's "…" stays one character: models often write "...",
    which the checks can't tell from a typo and the .po shouldn't mix."""
    return text.replace("...", "…") if "…" in source else text


# Percent signs a model may write in a placeholder: Arabic's and the
# full-width one (Chinese, Japanese).
_PERCENTS = ("\u066a", "\uff05")


def placeholders(source: str, text: str) -> str:
    """The source's placeholders with a look-alike percent sign
    ("٪{minutes}") written back as they are: the name is right, only the
    typography slipped."""
    for name in set(PLACEHOLDER.findall(source)):
        for percent in _PERCENTS:
            text = text.replace(percent + name[1:], name)
    return text


def tidy(source: str, text: str) -> str:
    """What every machine translation goes through before the checks:
    `script_brand`, `brand_case`, `ellipsis`, `placeholders`, and NFC (one form for every
    letter, so the checks and the .po see the same text)."""
    return unicodedata.normalize("NFC", placeholders(source, ellipsis(source, brand_case(script_brand(text)))))


# The MLX instruction models: name -> (repo, prompt style). Sizes chosen to
# fit the owner's 48 GB Mac one at a time (docs/architecture/translation_models.md).
MLX = {
    "hy-mt2": ("mlx-community/Hy-MT2-7B-8bit", "hy-mt2"),
    "translategemma-4b": ("mlx-community/translategemma-4b-it-8bit", "translategemma"),
    "translategemma-12b": ("mlx-community/translategemma-12b-it-8bit", "translategemma"),
    "translategemma-27b": ("mlx-community/translategemma-27b-it-4bit", "translategemma"),
}


# Contestants no longer run for new strings (`cli plan` skips them): their
# translations already made still compete. TranslateGemma 27B: 7% of the
# site's picks for a third of the shootout's time (the owner, 2026-10-24;
# its picks' replacements rated 0.5 lower by the judges on average).
RETIRED = {"translategemma-27b"}


def takes_context(name: str) -> bool:
    """Whether the model reads a string's context (`MLXChat.takes_context`),
    known without loading it."""
    return name in MLX


def uv_group(name: str) -> str:
    """The uv dependency group the model runs in (`uv run --group …`)."""
    return "mlx" if name in MLX else "models"


def get(name: str) -> Translator:
    if name == "opus-mt":
        from .opus_mt import OpusMT

        return OpusMT()
    if name == "m2m100":
        from .m2m100 import M2M100

        return M2M100()
    if name == "madlad-400":
        from .madlad import MADLAD

        return MADLAD()
    if name in MLX:
        from .mlx_chat import MLXChat

        repo, style = MLX[name]
        return MLXChat(name, repo, style)
    known = ["opus-mt", "m2m100", "madlad-400", *MLX]
    raise SystemExit(f"unknown model {name!r}; known: {', '.join(known)}")
