"""Scores that need a model or a reference.

- Back-translation chrF: translate back to English and compare with the
  source (sacrebleu). Runs with any contestant that can translate back, as
  part of `run`.
- Reference-free quality estimation with two independent models, MetricX-24
  (ungated) and COMET-Kiwi (gated): never rank on MetricX alone, since
  TranslateGemma was trained against it.
- A tone judge (meaning kept, calm and informal) from a model family no
  contestant belongs to: Mistral Small 3.2.

The last three run afterwards with `cli score`, one scorer per process (so
a scorer never shares memory with a contestant), over every run in
results/: a model scored by fewer scorers than the rest would get a skewed
mean rank on the review page. Until then a run holds them as `"pending"`.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
from pathlib import Path

from sacrebleu.metrics import CHRF

_chrf = CHRF()


def back_translation_chrf(source: str, back: str) -> float:
    return round(_chrf.sentence_score(back, [source]).score, 1)


PENDING = {
    "metricx": "MetricX-24-Hybrid XL (google/metricx-24-hybrid-xl-v2p6-bfloat16): ~7 GB, ungated",
    "comet_kiwi": "COMET-Kiwi (Unbabel/wmt22-cometkiwi-da): ~2 GB, gated (accept CC-BY-NC-SA terms)",
    "judge": "LLM tone judge (Mistral Small 3.2 24B, or Qwen3 30B-A3B for ur, sw, fil; 4-bit MLX): ~14-17 GB, ungated",
}


def pending_scores() -> dict[str, dict]:
    return {name: {"score": None, "pending": why} for name, why in PENDING.items()}


class MetricX:
    """MetricX-24 in QE mode (no reference): an error score from 0 (perfect)
    to 25. Its checkpoints are mT5 with a regression head that's the
    seq2seq model's own layers, read differently (google-research/metricx,
    metricx24/models.py, Apache-2.0): one decoder step from token 0, the
    logit of <extra_id_10> (id 250089), clipped to 0..25. So the weights
    load into transformers' MT5ForConditionalGeneration and need no custom
    class. Inputs as its predict.py builds them: "source: ... candidate:
    ...", the mt5-xl tokenizer, the trailing EOS dropped."""

    name = "metricx"
    REPO = "google/metricx-24-hybrid-xl-v2p6-bfloat16"
    TOKENIZER = "google/mt5-xl"
    _SCORE_TOKEN = 250089

    def __init__(self) -> None:
        import torch
        from transformers import AutoTokenizer, MT5ForConditionalGeneration

        self._torch = torch
        self._device = "mps" if torch.backends.mps.is_available() else "cpu"
        self._tokenizer = AutoTokenizer.from_pretrained(self.TOKENIZER)
        self._model = (
            MT5ForConditionalGeneration.from_pretrained(self.REPO, dtype=torch.bfloat16).to(self._device).eval()
        )

    def score(self, locale: str, entries: list[dict], batch: int = 16) -> list[dict]:
        torch, out = self._torch, []
        for i in range(0, len(entries), batch):
            inputs = [f"source: {e['msgid']} candidate: {e['text']}" for e in entries[i : i + batch]]
            # No EOS (predict.py strips it), so no special tokens at all.
            enc = self._tokenizer(
                inputs, add_special_tokens=False, max_length=1536, truncation=True, padding=True, return_tensors="pt"
            ).to(self._device)
            start = torch.zeros((len(inputs), 1), dtype=torch.long, device=self._device)
            with torch.no_grad():
                logits = self._model(**enc, decoder_input_ids=start).logits
            values = torch.clamp(logits[:, 0, self._SCORE_TOKEN].float(), 0, 25).tolist()
            out += [{"score": round(v, 2)} for v in values]
        return out


class CometKiwi:
    """COMET-Kiwi (wmt22-cometkiwi-da): reference-free quality, 0 to 1,
    higher is better. Gated: accept its terms on Hugging Face first."""

    name = "comet_kiwi"
    REPO = "Unbabel/wmt22-cometkiwi-da"

    def __init__(self) -> None:
        from comet import download_model, load_from_checkpoint

        self._model = load_from_checkpoint(download_model(self.REPO))

    def score(self, locale: str, entries: list[dict]) -> list[dict]:
        data = [{"src": e["msgid"], "mt": e["text"]} for e in entries]
        # MPS isn't supported by COMET's Lightning setup; the CPU is fast
        # enough for a few thousand short strings.
        result = self._model.predict(data, batch_size=32, gpus=0, num_workers=1, progress_bar=False)
        return [{"score": round(float(v), 4)} for v in result.scores]


JUDGE_RUBRIC = """You review translations of a website's interface text from English into {language}.
The site is randos: anonymous, audio-only language practice with strangers. Its voice is calm,
friendly and informal (like a kind friend, never corporate). "rando" and "randos" stay in English,
and placeholders such as %{{time}} stay exactly as they are.

Rate the translation from 1 to 10:
- 10: the meaning is fully kept, it reads naturally to a native speaker, and the tone is calm and informal;
- 7: right meaning, small awkwardness or a slightly stiff tone;
- 4: meaning partly lost, or clearly unnatural, or the wrong register;
- 1: wrong meaning, not {language}, or broken.
{context}
English: {source}
{language}: {text}

Answer with JSON only, on one line: {{"score": <1-10>, "reason": "<at most 15 words, in English>"}}"""

_JSON = re.compile(r"\{.*\}", re.DOTALL)


def parse_judgement(reply: str) -> dict:
    """The judge's reply -> {"score": int 1..10, "reason": str}, or a None
    score with the reply kept when it isn't the JSON asked for."""
    match = _JSON.search(reply)
    try:
        data = json.loads(match.group(0)) if match else None
        score = int(data["score"])
        if not 1 <= score <= 10:
            raise ValueError(score)
        return {"score": score, "reason": str(data.get("reason", ""))[:200]}
    except (TypeError, KeyError, ValueError):
        return {"score": None, "error": f"unparsed reply: {reply[:200]!r}"}


# The judges, each from a family no contestant belongs to (models favour
# their own output), 4-bit MLX, Apache-2.0. Mistral Small 3.2 judges the
# languages its card lists; Qwen3 30B-A3B (a mixture of experts, 3B active;
# its card lists 119 languages) the ones Mistral's doesn't.
JUDGES = {
    "mistral": "mlx-community/Mistral-Small-3.2-24B-Instruct-2506-4bit",
    "qwen": "mlx-community/Qwen3-30B-A3B-Instruct-2507-4bit",
}
JUDGE_FOR = {"ur": "qwen", "sw": "qwen", "fil": "qwen"}


def judge_for(locale: str) -> str:
    """The judge (a `JUDGES` name) for a locale."""
    return JUDGE_FOR.get(locale, "mistral")


def judged_by(entry: dict) -> str | None:
    """The judge whose verdict an entry holds (verdicts from before there
    were two are Mistral's)."""
    verdict = entry["scores"].get("judge") or {}
    return verdict.get("by", "mistral") if verdict.get("score") is not None else None


class Judge:
    """One tone judge (`JUDGES`), greedy. Prompts go to mlx-lm's
    `batch_generate` together (`BATCH` at a time), which keeps the GPU busy
    between short replies."""

    name = "judge"
    BATCH = 64

    def __init__(self, judge: str = "mistral") -> None:
        from mlx_lm import batch_generate, load

        self.judge, self.repo = judge, JUDGES[judge]
        self._batch_generate = batch_generate
        self._model, self._tokenizer = load(self.repo)
        self._contexts = current_contexts()

    def close(self) -> None:
        """Frees the model's memory, so the next judge can load."""
        import gc

        import mlx.core as mx

        del self._model, self._tokenizer
        gc.collect()
        mx.clear_cache()

    def context(self, entry: dict) -> str:
        """The context the judge sees for an entry now: its string's
        translator comment in the template today."""
        return judge_context(entry["msgctxt"], self._contexts.get(entry["key"], ""))

    def score(self, locale: str, entries: list[dict]) -> list[dict]:
        from .models import NAMES

        language, out = NAMES[locale], []
        for i in range(0, len(entries), self.BATCH):
            chunk = entries[i : i + self.BATCH]
            contexts = [self.context(e) for e in chunk]
            prompts = [
                # The chat template already starts with BOS: no second one.
                self._tokenizer.encode(
                    self._tokenizer.apply_chat_template(
                        [{"role": "user", "content": judge_prompt(language, e, context)}],
                        add_generation_prompt=True,
                        tokenize=False,
                    ),
                    add_special_tokens=False,
                )
                for e, context in zip(chunk, contexts)
            ]
            replies = self._batch_generate(self._model, self._tokenizer, prompts, max_tokens=80).texts
            out += [parse_judgement(r) | {"context": c, "by": self.judge} for r, c in zip(replies, contexts)]
        return out


def judge_prompt(language: str, entry: dict, context: str) -> str:
    return JUDGE_RUBRIC.format(language=language, context=context, source=entry["msgid"], text=entry["text"])


class JudgeCache:
    """Verdicts already given, keyed by everything the judge saw (its
    model, the rubric, the locale, the context, the English, the
    translation): two models with the same output, or a re-run that
    changes nothing the judge sees, are judged once. A changed rubric or
    comment is a different key, so it's judged afresh. Only parsed
    verdicts are kept; a reply that wasn't the JSON asked for is retried."""

    def __init__(self, path: Path) -> None:
        self.path = path
        self._verdicts = json.loads(path.read_text())["verdicts"] if path.exists() else {}
        self._new: set[str] = set()

    @staticmethod
    def key(locale: str, entry: dict, context: str, judge: str = "mistral") -> str:
        seen = [JUDGES[judge], JUDGE_RUBRIC, locale, context, entry["msgid"], entry["text"]]
        return hashlib.sha256(json.dumps(seen, ensure_ascii=False).encode()).hexdigest()

    def get(
        self, locale: str, entry: dict, context: str, judge: str = "mistral", only_new: bool = False
    ) -> dict | None:
        """The verdict given before (`only_new`: only one given since this
        cache was opened, as `--redo` wants)."""
        key = self.key(locale, entry, context, judge)
        verdict = self._verdicts.get(key) if not only_new or key in self._new else None
        return verdict and verdict | {"context": context, "by": judge}

    def put(self, locale: str, entry: dict, verdict: dict) -> None:
        if verdict.get("score") is not None:
            kept = {k: verdict[k] for k in ("score", "reason")}
            key = self.key(locale, entry, verdict["context"], verdict.get("by", "mistral"))
            self._verdicts[key] = kept
            self._new.add(key)

    def save(self) -> None:
        tmp = self.path.with_name(f".{self.path.name}.tmp")
        tmp.write_text(json.dumps({"verdicts": self._verdicts}, ensure_ascii=False, indent=0, sort_keys=True) + "\n")
        os.replace(tmp, self.path)


def current_contexts() -> dict[str, str]:
    from . import po

    return {s.key: s.context for s in po.sources()}


def judge_context(msgctxt: str | None, context: str) -> str:
    """The rubric's context lines: a button's length rule, and the string's
    translator comment ("where it appears")."""
    lines = ["It is a button label: it must be short."] if msgctxt == "button" else []
    if context and context != "A button label.":
        lines.append(f"Where it appears: {context}")
    return "\n" + "\n".join(lines) + "\n" if lines else ""


def judged_context(entry: dict) -> str:
    """The context an entry's judgement saw (judgements from before comments
    existed saw only the button rule)."""
    result = entry["scores"].get("judge") or {}
    return result["context"] if "context" in result else judge_context(entry["msgctxt"], "")


SCORERS = {"metricx": MetricX, "comet_kiwi": CometKiwi, "judge": Judge}
