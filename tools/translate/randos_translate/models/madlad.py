"""MADLAD-400 (Google, Apache-2.0): a T5 translation model for 400+
languages, run through transformers on Apple's GPU (MPS) in bfloat16. The
target language is a `<2xx>` prefix on the input; like the other seq2seq
models it gets placeholders and glossary terms as `protect` tokens.

The 7B: the 10B swapped the owner's 48 GB Mac to a standstill (45 GB of
swap, no locale done in 20 minutes). The 7B loads as bf16 (15.5 GB). With
batches of 4, 4 beams and a flat 256-token budget, generation buffers made
swap jump 11.7 GB in 30 seconds halfway through; one string at a time, 2
beams, a budget scaled to the input and MPS's cache emptied after each,
it ran all 14 locales at 5-6 minutes each, peaking at 20.2 GB."""

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

    def _run(self, texts: list[str], target: str) -> list[str]:
        # One string at a time, 2 beams, an output budget scaled to the input,
        # and MPS's cache emptied after each: generation memory, not the
        # weights, is what overflowed (4 beams, batches of 4 and a flat
        # 256-token budget).
        import gc

        torch, out, peak = self._torch, [], 0
        for text in texts:
            protected, kept = protect(text)
            inputs = self._tokenizer(f"<2{target}> {protected}", return_tensors="pt").to(self._device)
            budget = min(256, 3 * inputs["input_ids"].shape[1] + 16)
            with torch.no_grad():
                generated = self._model.generate(**inputs, num_beams=2, max_new_tokens=budget)
            out.append(restore(self._tokenizer.decode(generated[0], skip_special_tokens=True), kept))
            if self._device == "mps":
                peak = max(peak, torch.mps.driver_allocated_memory())
                del inputs, generated
                gc.collect()
                torch.mps.empty_cache()
        if peak:
            print(f"madlad-400: <2{target}>: peak MPS memory {peak / 2**30:.1f} GB", file=sys.stderr, flush=True)
        return out

    def translate(self, texts: list[str], target: str, contexts: list[str] | None = None) -> list[str]:
        # A seq2seq model takes no context: `contexts` is ignored.
        return self._run(texts, target)

    def back_translate(self, texts: list[str], source: str) -> list[str]:
        return self._run(texts, "en")
