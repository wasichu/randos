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
}


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

    def _run(self, repo: str, texts: list[str]) -> list[str]:
        tokenizer, model = self._load(repo)
        protected = [protect(t) for t in texts]
        batch = tokenizer([p for p, _ in protected], return_tensors="pt", padding=True).to(self._device)
        with self._torch.no_grad():
            out = model.generate(**batch, num_beams=4, max_new_tokens=256)
        decoded = tokenizer.batch_decode(out, skip_special_tokens=True)
        return [restore(d, kept) for d, (_, kept) in zip(decoded, protected)]

    def translate(self, texts: list[str], target: str) -> list[str]:
        return self._run(PAIRS[target][0], texts)

    def back_translate(self, texts: list[str], source: str) -> list[str]:
        return self._run(PAIRS[source][1], texts)
