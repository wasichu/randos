"""MADLAD-400 (Google, Apache-2.0): a T5 translation model for 400+
languages, the 10B (the largest, ~21 GB), run through transformers on
Apple's GPU (MPS) in bfloat16. The
target language is a `<2xx>` prefix on the input; like the other seq2seq
models it gets placeholders and glossary terms as `protect` tokens."""

from __future__ import annotations

from . import NAMES, protect, restore

LOCALES = list(NAMES)


class MADLAD:
    name = "madlad-400"
    locales = LOCALES

    def __init__(self, repo: str = "google/madlad400-10b-mt") -> None:
        import torch
        from transformers import AutoTokenizer, T5ForConditionalGeneration

        self.repo = repo
        self._torch = torch
        self._device = "mps" if torch.backends.mps.is_available() else "cpu"
        self._tokenizer = AutoTokenizer.from_pretrained(repo)
        self._model = (
            T5ForConditionalGeneration.from_pretrained(repo, dtype=torch.bfloat16).to(self._device).eval()
        )

    def _run(self, texts: list[str], target: str, batch: int = 16) -> list[str]:
        out: list[str] = []
        for i in range(0, len(texts), batch):
            protected = [protect(t) for t in texts[i : i + batch]]
            inputs = self._tokenizer(
                [f"<2{target}> {p}" for p, _ in protected], return_tensors="pt", padding=True
            ).to(self._device)
            with self._torch.no_grad():
                generated = self._model.generate(**inputs, num_beams=4, max_new_tokens=256)
            decoded = self._tokenizer.batch_decode(generated, skip_special_tokens=True)
            out += [restore(d, kept) for d, (_, kept) in zip(decoded, protected)]
        return out

    def translate(self, texts: list[str], target: str) -> list[str]:
        return self._run(texts, target)

    def back_translate(self, texts: list[str], source: str) -> list[str]:
        return self._run(texts, "en")
