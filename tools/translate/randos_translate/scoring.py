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

import json
import re

from sacrebleu.metrics import CHRF

_chrf = CHRF()


def back_translation_chrf(source: str, back: str) -> float:
    return round(_chrf.sentence_score(back, [source]).score, 1)


PENDING = {
    "metricx": "MetricX-24-Hybrid XL (google/metricx-24-hybrid-xl-v2p6-bfloat16): ~7 GB, ungated",
    "comet_kiwi": "COMET-Kiwi (Unbabel/wmt22-cometkiwi-da): ~2 GB, gated (accept CC-BY-NC-SA terms)",
    "judge": "LLM tone judge (Mistral Small 3.2 24B, 4-bit MLX): ~14 GB, ungated",
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


class Judge:
    """The tone judge: Mistral Small 3.2 24B (Apache-2.0), 4-bit MLX,
    greedy. Mistral is a family none of the contestants belongs to."""

    name = "judge"
    REPO = "mlx-community/Mistral-Small-3.2-24B-Instruct-2506-4bit"

    def __init__(self) -> None:
        from mlx_lm import generate, load

        self._generate = generate
        self._model, self._tokenizer = load(self.REPO)

    def score(self, locale: str, entries: list[dict]) -> list[dict]:
        from .models import NAMES

        language, out = NAMES[locale], []
        for e in entries:
            context = "\nIt is a button label: it must be short.\n" if e["msgctxt"] == "button" else ""
            ask = JUDGE_RUBRIC.format(language=language, context=context, source=e["msgid"], text=e["text"])
            prompt = self._tokenizer.apply_chat_template(
                [{"role": "user", "content": ask}], add_generation_prompt=True, tokenize=False
            )
            reply = self._generate(self._model, self._tokenizer, prompt=prompt, max_tokens=80, verbose=False)
            out.append(parse_judgement(reply))
        return out


SCORERS = {"metricx": MetricX, "comet_kiwi": CometKiwi, "judge": Judge}
