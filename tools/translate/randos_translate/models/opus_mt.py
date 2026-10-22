"""Opus-MT (Helsinki-NLP), one small Marian model per language pair, through
transformers on Apple's GPU. The baseline, and the proof that the pipeline
works end to end. Direct en->X pairs exist for most of our languages, but
not bn or ja (translation_models.md); `PAIRS` lists the ones wired.
Licenses are per pair (Apache-2.0 or CC-BY-4.0: credit those)."""

from __future__ import annotations

from . import protect, restore

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
}
# Not wired: pt (an en->pt tc-big model, but no pt->en to translate back
# with), ko (en->ko is multi-target and its card names no valid target
# token), bn and ja (no direct pair).

# Multi-target models need the target as a sentence-initial token.
TARGET_TOKEN = {"zh": ">>cmn_Hans<< "}


class OpusMT:
    name = "opus-mt"
    locales = list(PAIRS)

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

    def _run(self, repo: str, texts: list[str], prefix: str = "", batch: int = 16) -> list[str]:
        tokenizer, model = self._load(repo)
        out: list[str] = []
        for i in range(0, len(texts), batch):
            protected = [protect(t) for t in texts[i : i + batch]]
            inputs = tokenizer([prefix + p for p, _ in protected], return_tensors="pt", padding=True).to(self._device)
            with self._torch.no_grad():
                generated = model.generate(**inputs, num_beams=4, max_new_tokens=256)
            decoded = tokenizer.batch_decode(generated, skip_special_tokens=True)
            out += [restore(d, kept) for d, (_, kept) in zip(decoded, protected)]
        return out

    def translate(self, texts: list[str], target: str) -> list[str]:
        return self._run(PAIRS[target][0], texts, TARGET_TOKEN.get(target, ""))

    def back_translate(self, texts: list[str], source: str) -> list[str]:
        return self._run(PAIRS[source][1], texts)
