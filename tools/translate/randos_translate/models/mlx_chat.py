"""Instruction models on Apple's GPU through mlx-lm (`--group mlx`): Hy-MT2
(Tencent, Apache-2.0) and TranslateGemma (Google, Gemma terms), each run with
the prompt its model card documents, greedily (deterministic).

Unlike the seq2seq models they get the original text (no `protect`): Hy-MT2
gets the glossary through its documented terminology prompt; TranslateGemma's
chat template takes the text alone, so whether it keeps "rando" and the
placeholders is exactly what the checks are for.
"""

from __future__ import annotations

from . import NAMES

LOCALES = list(NAMES)

# Hy-MT2's terminology prompt (its model card, verbatim: it was trained on
# these strings), with our glossary.
_HY_TERMS = "Reference the following translations:\nrando translates to rando\nrandos translates to randos\n\n"


class MLXChat:
    """One MLX chat model; `style` picks the prompt (hy-mt2 or translategemma)."""

    locales = LOCALES

    def __init__(self, name: str, repo: str, style: str) -> None:
        from mlx_lm import generate, load

        self.name, self.repo, self._style = name, repo, style
        self._generate = generate
        self._model, self._tokenizer = load(repo)

    def _prompt(self, text: str, source: str, target: str) -> str:
        if self._style == "translategemma":
            content = [{"type": "text", "source_lang_code": source, "target_lang_code": target, "text": text}]
            messages = [{"role": "user", "content": content}]
        else:
            terms = _HY_TERMS if target != "en" else ""
            ask = (
                f"{terms}Translate the following text into {NAMES.get(target, 'English')}. "
                "Note that you should **only output the translated result without any additional explanation**:"
                f"\n\n{text}"
            )
            messages = [{"role": "user", "content": ask}]
        return self._tokenizer.apply_chat_template(messages, add_generation_prompt=True, tokenize=False)

    def _one(self, text: str, source: str, target: str) -> str:
        prompt = self._prompt(text, source, target)
        out = self._generate(self._model, self._tokenizer, prompt=prompt, max_tokens=256, verbose=False)
        return out.strip()

    def translate(self, texts: list[str], target: str) -> list[str]:
        return [self._one(t, "en", target) for t in texts]

    def back_translate(self, texts: list[str], source: str) -> list[str]:
        return [self._one(t, source, "en") for t in texts]
