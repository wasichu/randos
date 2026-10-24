"""Opus-MT (Helsinki-NLP), one small Marian model per language pair, through
transformers on Apple's GPU. The baseline, and the proof that the pipeline
works end to end. Direct en->X pairs exist for most of our languages, but
not bn or ja (translation_models.md); `PAIRS` lists the ones wired.
Licenses are per pair (Apache-2.0 or CC-BY-4.0: credit those)."""

from __future__ import annotations

from typing import ClassVar

from . import protect, restore

_IIR = "Helsinki-NLP/opus-mt-tc-bible-big-deu_eng_fra_por_spa-iir"

# locale -> (en->X model, X->en model for back-translation)
PAIRS = {
    "es": ("Helsinki-NLP/opus-mt-en-es", "Helsinki-NLP/opus-mt-es-en"),
    "ar": ("Helsinki-NLP/opus-mt-en-ar", "Helsinki-NLP/opus-mt-ar-en"),
    "zh": ("Helsinki-NLP/opus-mt-en-zh", "Helsinki-NLP/opus-mt-zh-en"),
    "hi": ("Helsinki-NLP/opus-mt-en-hi", "Helsinki-NLP/opus-mt-hi-en"),
    "ru": ("Helsinki-NLP/opus-mt-en-ru", "Helsinki-NLP/opus-mt-ru-en"),
    "fr": ("Helsinki-NLP/opus-mt-en-fr", "Helsinki-NLP/opus-mt-fr-en"),
    "de": ("Helsinki-NLP/opus-mt-en-de", "Helsinki-NLP/opus-mt-de-en"),
    "it": ("Helsinki-NLP/opus-mt-en-it", "Helsinki-NLP/opus-mt-it-en"),
    "id": ("Helsinki-NLP/opus-mt-en-id", "Helsinki-NLP/opus-mt-id-en"),
    # Only a tc-big model goes en->tr (CC-BY-4.0).
    "tr": ("Helsinki-NLP/opus-mt-tc-big-en-tr", "Helsinki-NLP/opus-mt-tr-en"),
    "vi": ("Helsinki-NLP/opus-mt-en-vi", "Helsinki-NLP/opus-mt-vi-en"),
    # Urdu and Persian through a multi-target model of the Indo-Iranian
    # languages (trained on OPUS, the Bible among it): the direct en->ur is
    # weaker (Tatoeba chrF 0.39 against Flores 0.48), and en->fa doesn't
    # exist. Persian back through the Indo-Iranian model too.
    "ur": (_IIR, "Helsinki-NLP/opus-mt-ur-en"),
    "fa": (_IIR, "Helsinki-NLP/opus-mt-tc-bible-big-iir-en"),
    # Filipino is standardized Tagalog: the tl pairs.
    "fil": ("Helsinki-NLP/opus-mt-en-tl", "Helsinki-NLP/opus-mt-tl-en"),
}
# Not wired: pt (an en->pt tc-big model, but no pt->en to translate back
# with), ko (en->ko is multi-target and its card names no valid target
# token), bn and ja (no direct pair), sw (en->sw exists, but the only way
# back is Congo Swahili, `swc`, another variety: the owner's call, left out).

# Multi-target models need the target as a sentence-initial token.
# Urdu and Iranian Persian (`pes`, not `fas`, the macrolanguage, nor
# `prs`, Dari).
TARGET_TOKEN = {"zh": ">>cmn_Hans<< ", "ur": ">>urd<< ", "fa": ">>pes<< "}


class OpusMT:
    name = "opus-mt"
    locales: ClassVar[list[str]] = list(PAIRS)

    def __init__(self) -> None:
        import torch
        from transformers import MarianMTModel, MarianTokenizer

        self._torch = torch
        self._model_cls, self._tokenizer_cls = MarianMTModel, MarianTokenizer
        self._device = "mps" if torch.backends.mps.is_available() else "cpu"
        self._loaded: dict[str, tuple] = {}

    def _load(self, repo: str):
        if repo not in self._loaded:
            tokenizer = self._tokenizer_cls.from_pretrained(repo)
            model = self._model_cls.from_pretrained(repo).to(self._device).eval()
            self._loaded[repo] = (tokenizer, model)
        return self._loaded[repo]

    # Batches of 4: with 16, the 4 beams of a batch of long strings still
    # reached 36 GB of GPU memory within the budget below.
    def _run(self, repo: str, texts: list[str], prefix: str = "", batch: int = 4) -> list[str]:
        tokenizer, model = self._load(repo)
        out: list[str] = []
        for i in range(0, len(texts), batch):
            protected = [protect(t) for t in texts[i : i + batch]]
            inputs = tokenizer([prefix + p for p, _ in protected], return_tensors="pt", padding=True).to(self._device)
            # An output budget scaled to the input, as for MADLAD: en->vi
            # repeats itself to any limit, and 4 beams of 16 strings run to
            # 256 tokens took 45 GB of GPU memory in its first batch.
            budget = min(256, 3 * inputs["input_ids"].shape[1] + 16)
            with self._torch.no_grad():
                generated = model.generate(**inputs, num_beams=4, max_new_tokens=budget)
            decoded = tokenizer.batch_decode(generated, skip_special_tokens=True)
            out += [restore(d, kept) for d, (_, kept) in zip(decoded, protected)]
            if self._device == "mps":
                del inputs, generated
                self._torch.mps.empty_cache()
        return out

    def translate(self, texts: list[str], target: str, contexts: list[str] | None = None) -> list[str]:
        # A seq2seq model takes no context: `contexts` is ignored.
        return self._run(PAIRS[target][0], texts, TARGET_TOKEN.get(target, ""))

    def back_translate(self, texts: list[str], source: str) -> list[str]:
        return self._run(PAIRS[source][1], texts)
