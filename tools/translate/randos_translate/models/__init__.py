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


def get(name: str) -> Translator:
    if name == "opus-mt":
        from .opus_mt import OpusMT

        return OpusMT()
    if name == "m2m100":
        from .m2m100 import M2M100

        return M2M100()
    if name in PLANNED:
        raise SystemExit(f"{name}: planned for the full shootout, not wired yet ({PLANNED[name]})")
    raise SystemExit(f"unknown model {name!r}; known: opus-mt, m2m100, {', '.join(PLANNED)}")


# The rest of the field (docs/architecture/translation_models.md), to add
# as adapters when the full shootout runs.
PLANNED = {
    "hy-mt2": "MLX, mlx-community/Hy-MT2-*; ungated, Apache-2.0",
    "translategemma": "MLX, mlx-community/translategemma-*; gated (accept the Gemma terms on Hugging Face)",
    "madlad-400": "transformers T5 on MPS; ungated, Apache-2.0",
}
