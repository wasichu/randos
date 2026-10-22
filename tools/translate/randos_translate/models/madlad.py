"""MADLAD-400 (Google, Apache-2.0): a T5 translation model for 400+
languages, run through transformers on Apple's GPU (MPS) in bfloat16. The
target language is a `<2xx>` prefix on the input; like the other seq2seq
models it gets placeholders and glossary terms as `protect` tokens.

Not in the 2026-10 shootout: it didn't fit the owner's 48 GB Mac. The 10B
swapped the machine to a standstill (45 GB of swap, no locale done in 20
minutes). The 7B loads as bf16 (15.5 GB) and translated about 2.6 minutes
per locale with batches of 4, but halfway through, swap jumped 11.7 GB in
30 seconds and the memory guard stopped it (MPS's generation buffers, not
the weights). Kept wired for a machine with more memory."""

from __future__ import annotations

import sys

from . import NAMES, protect, restore

LOCALES = list(NAMES)


class MADLAD:
    name = "madlad-400"
    locales = LOCALES

    def __init__(self, repo: str = "google/madlad400-7b-mt") -> None:
        import torch
        from transformers import AutoTokenizer, T5ForConditionalGeneration

        self.repo = repo
        self._torch = torch
        self._device = "mps" if torch.backends.mps.is_available() else "cpu"
        self._tokenizer = AutoTokenizer.from_pretrained(repo)
        self._model = (
            T5ForConditionalGeneration.from_pretrained(repo, dtype=torch.bfloat16, low_cpu_mem_usage=True)
            .to(self._device)
            .eval()
        )
        size = sum(p.numel() * p.element_size() for p in self._model.parameters()) / 2**30
        print(f"madlad-400: {repo} loaded as {self._model.dtype}, {size:.1f} GB", file=sys.stderr, flush=True)

    def _run(self, texts: list[str], target: str, batch: int = 4) -> list[str]:
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
