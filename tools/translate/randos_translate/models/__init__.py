"""The contestants, behind one interface: `translate(texts, target) -> list`.

Seq2seq models can't follow instructions, so `protect`/`restore` swap
placeholders and glossary terms for tokens they pass through untouched;
the checks then show which models still damage them. Instruction models
(Hy-MT2, TranslateGemma, an LLM) get the same rules in their prompt.
"""

from __future__ import annotations

import re
from typing import Protocol

from ..checks import GLOSSARY, PLACEHOLDER


class Translator(Protocol):
    name: str
    locales: list[str]

    def translate(self, texts: list[str], target: str) -> list[str]: ...

    def back_translate(self, texts: list[str], source: str) -> list[str]: ...


# Our 14 practice languages, by the English names the instruction models'
# prompts use (Chinese: the site is in Simplified).
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


# The MLX instruction models: name -> (repo, prompt style). Sizes chosen to
# fit the owner's 48 GB Mac one at a time (docs/architecture/translation_models.md).
MLX = {
    "hy-mt2": ("mlx-community/Hy-MT2-7B-8bit", "hy-mt2"),
    "translategemma-4b": ("mlx-community/translategemma-4b-it-8bit", "translategemma"),
    "translategemma-12b": ("mlx-community/translategemma-12b-it-8bit", "translategemma"),
    "translategemma-27b": ("mlx-community/translategemma-27b-it-4bit", "translategemma"),
}


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
