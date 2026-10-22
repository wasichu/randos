"""M2M100 418M (Facebook, MIT): one multilingual many-to-many model, so every
one of our locales and the back-translation come from the same weights
(about 2 GB). A baseline the dedicated translation models should beat, and
the second contestant that gives the review page real disagreements."""

from __future__ import annotations

from . import protect, restore

REPO = "facebook/m2m100_418M"
# M2M100 covers all 14 (its language codes match ours).
LOCALES = ["es", "zh", "hi", "ar", "pt", "bn", "ru", "ja", "fr", "de", "ko", "it", "tr", "id"]


class M2M100:
    name = "m2m100"
    locales = LOCALES

    def __init__(self) -> None:
        import torch
        from transformers import M2M100ForConditionalGeneration, M2M100Tokenizer

        self._torch = torch
        self._device = "mps" if torch.backends.mps.is_available() else "cpu"
        self._tokenizer = M2M100Tokenizer.from_pretrained(REPO)
        self._model = M2M100ForConditionalGeneration.from_pretrained(REPO).to(self._device).eval()

    def _run(self, texts: list[str], source: str, target: str, batch: int = 16) -> list[str]:
        # Small batches: one batch of every string stalled on MPS for 25
        # minutes (bn), the long strings' padding and beams multiplying.
        self._tokenizer.src_lang = source
        out: list[str] = []
        for i in range(0, len(texts), batch):
            protected = [protect(t) for t in texts[i : i + batch]]
            inputs = self._tokenizer([p for p, _ in protected], return_tensors="pt", padding=True).to(self._device)
            with self._torch.no_grad():
                generated = self._model.generate(
                    **inputs,
                    forced_bos_token_id=self._tokenizer.get_lang_id(target),
                    num_beams=4,
                    max_new_tokens=256,
                )
            decoded = self._tokenizer.batch_decode(generated, skip_special_tokens=True)
            out += [restore(d, kept) for d, (_, kept) in zip(decoded, protected)]
        return out

    def translate(self, texts: list[str], target: str, contexts: list[str] | None = None) -> list[str]:
        # A seq2seq model takes no context: `contexts` is ignored.
        return self._run(texts, "en", target)

    def back_translate(self, texts: list[str], source: str) -> list[str]:
        return self._run(texts, source, "en")
