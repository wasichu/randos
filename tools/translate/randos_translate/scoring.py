"""Scores that need a model or a reference.

- Back-translation chrF: translate back to English and compare with the
  source (sacrebleu). Runs with any contestant that can translate back.
- Reference-free quality estimation with two independent models, MetricX-24
  (ungated) and COMET-Kiwi (gated): never rank on MetricX alone, since
  TranslateGemma was trained against it.
- A tone judge (calm, informal) from a model family no contestant belongs to.

The QE models and the judge are wired as named scorers but not run yet:
they need multi-GB downloads (and COMET-Kiwi an accepted license), which
wait for the owner. They report `None` with a reason meanwhile.
"""

from __future__ import annotations

from sacrebleu.metrics import CHRF

_chrf = CHRF()


def back_translation_chrf(source: str, back: str) -> float:
    return round(_chrf.sentence_score(back, [source]).score, 1)


PENDING = {
    "metricx": "MetricX-24-Hybrid (google/metricx-24-hybrid-xl-v2p6): ~15 GB, ungated",
    "comet_kiwi": "COMET-Kiwi (Unbabel/wmt22-cometkiwi-da): ~2 GB, gated (accept CC-BY-NC-SA terms)",
    "judge": "LLM tone judge (Mistral Small 3.2 24B, 4-bit MLX): ~14 GB, ungated",
}


def pending_scores() -> dict[str, dict]:
    return {name: {"score": None, "pending": why} for name, why in PENDING.items()}
