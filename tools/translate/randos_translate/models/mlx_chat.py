"""Instruction models on Apple's GPU through mlx-lm (`--group mlx`): Hy-MT2
(Tencent, Apache-2.0) and TranslateGemma (Google, Gemma terms), each run with
the prompt its model card documents, greedily (deterministic).

Unlike the seq2seq models they get the original text (no `protect`): Hy-MT2
gets the glossary through its documented terminology prompt; TranslateGemma's
chat template takes the text alone, so whether it keeps "rando" and the
placeholders is exactly what the checks are for.

A string with a context (its translator comment) gets it too: Hy-MT2
through its card's background-information prompt, TranslateGemma as a line
inside its templated prompt, just before the text (its card documents no
context field). Strings without one keep the plain prompt.
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
    takes_context = True

    def __init__(self, name: str, repo: str, style: str) -> None:
        from mlx_lm import generate, load

        self.name, self.repo, self._style = name, repo, style
        self._generate = generate
        self._model, self._tokenizer = load(repo)
        # TranslateGemma's tokenizer lists only <eos> as an end, but its turns
        # end with <end_of_turn>: without it every answer runs to max_tokens.
        if style == "translategemma":
            self._tokenizer.add_eos_token("<end_of_turn>")

    def _prompt(self, text: str, source: str, target: str, context: str = "") -> str:
        messages = prompt_messages(self._style, text, source, target, context)
        rendered = self._tokenizer.apply_chat_template(messages, add_generation_prompt=True, tokenize=False)
        return with_context(rendered, context) if self._style == "translategemma" else rendered

    def _one(self, text: str, source: str, target: str, context: str = "") -> str:
        prompt = self._prompt(text, source, target, context)
        out = self._generate(self._model, self._tokenizer, prompt=prompt, max_tokens=256, verbose=False)
        # A turn marker that slipped through is not part of the translation.
        return out.split("<end_of_turn>")[0].strip()

    def translate(self, texts: list[str], target: str, contexts: list[str] | None = None) -> list[str]:
        contexts = contexts or [""] * len(texts)
        return [self._one(t, "en", target, c) for t, c in zip(texts, contexts)]

    def back_translate(self, texts: list[str], source: str) -> list[str]:
        return [self._one(t, source, "en") for t in texts]


def prompt_messages(style: str, text: str, source: str, target: str, context: str = "") -> list[dict]:
    """The chat messages for one string: each model card's documented prompt."""
    if style == "translategemma":
        content = [{"type": "text", "source_lang_code": source, "target_lang_code": target, "text": text}]
        return [{"role": "user", "content": content}]
    terms = _HY_TERMS if target != "en" else ""
    language = NAMES.get(target, "English")
    only = "Note that you should **only output the translated result without any additional explanation**"
    if context and target != "en":
        # The card's "background information" prompt, with the terms first.
        ask = (
            f"{terms}[Background Information]\n{context}\n\n"
            f"Please translate the following text into {language}, taking the provided background "
            f"information into consideration. {only}.\n\n[Source Text]\n{text}"
        )
    else:
        ask = f"{terms}Translate the following text into {language}. {only}:\n\n{text}"
    return [{"role": "user", "content": ask}]


_GEMMA_ASK = "Please translate the following"


def with_context(rendered: str, context: str) -> str:
    """TranslateGemma's templated prompt with the context just before its
    "Please translate the following ... text" line."""
    if not context or _GEMMA_ASK not in rendered:
        return rendered
    at = rendered.index(_GEMMA_ASK)
    return rendered[:at] + f"Context (for you, not to translate): {context}\n" + rendered[at:]
