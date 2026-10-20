# Translation models for Phase 6 (research, 2026-10-20)

Research for the Phase 6 translation shootout (see `refactor_plan.md`).
Facts come from the Hugging Face model API and model cards as of 2026-10-20
(license, parameter count, gating, the card's language list), except where a
row says otherwise. Re-check before downloading: models and terms change.

**Constraints.** Runs locally on an Apple M5 Pro with 48 GB unified memory
(about 36 GB usable by the GPU). Our 14 target languages: es, zh, hi, ar, pt,
bn, ru, ja, fr, de, ko, it, tr, id. Shipped translations must come from a
model whose license allows use in a product; models used only to *score*
translations never ship, so a non-commercial license is acceptable there
(confirm that reading per model).

Memory rule of thumb: bf16 ≈ 2 bytes per parameter, 8-bit ≈ 1, 4-bit ≈ 0.6.

## Contestants

| Model | License | Size | Our 14 languages | Gated | Runs on the Mac via | Memory |
| --- | --- | --- | --- | --- | --- | --- |
| **Hy-MT2** 1.8B / 7B (Tencent, 2026-05) | Apache-2.0 | 2.0B / 8.0B | all (33 supported) | no | MLX (`mlx-community/Hy-MT2-*`, 4/8-bit, bf16) | 7B bf16 ~16 GB |
| **Hy-MT2-30B-A3B** (Tencent, MoE, 2026-07) | Apache-2.0 | 30B total, 3B active | all | no | GGUF (llama.cpp), or our own `mlx-lm` conversion (none published) | 4-bit ~18 GB |
| **TranslateGemma** 4B / 12B / 27B (Google, 2026-01) | Gemma Terms of Use (commercial use allowed under Google's prohibited-use policy; not OSI) | 4.3B / 12.2B / 27.4B | 55 languages (WMT24++); ours very likely, **confirm on the card** | yes (accept terms) | MLX (`mlx-community/translategemma-*`, 4/6/8-bit, bf16) | 27B 4-bit ~16 GB |
| **MADLAD-400-MT** 3B / 7B / 10B (Google, 2023) | Apache-2.0 | 2.9B / 8.3B / 10.7B | all (400+) | no | `transformers` (T5) on MPS; no MLX conversion | 10B bf16 ~21 GB |
| **M2M100** 418M / 1.2B (Meta, 2020) | MIT | 0.4B / 1.2B | all (100) | no | `transformers` on MPS | small |
| **Opus-MT** (Helsinki-NLP), per pair | per pair: Apache-2.0 or CC-BY-4.0 | ~0.08–0.25B each | direct en→X for es, zh, hi, ar, pt*, ru, fr, de, ko*, it, tr*, id (*`tc-big` only, CC-BY-4.0); **no** direct en→bn or en→ja (only `opus-mt-en-mul`, which lacks ko) | no | `transformers` (Marian) on MPS | tiny |
| **Seed-X-PPO-7B** (ByteDance, 2025-07) | OpenMDW (permissive) | 7.5B | 26 of 28 ours: **no hi, bn** | no | `transformers`; no MLX | bf16 ~15 GB |
| **A general LLM**, e.g. Qwen3.8-27B (2026-08) | Apache-2.0 | 27.8B | not listed (general model) | no | MLX (`mlx-community/Qwen3.8-27B-4bit`) | 4-bit ~17 GB |

Notes:
- **Hy-MT2 is the strongest-looking fit**: Apache-2.0, ungated, every language,
  three sizes, Mac builds, and its card documents prompts for exactly our
  problems: *terminology* (keep "rando" as-is), and *delimiters/structured
  data* (never translate placeholders like `%{count}`).
- **Opus-MT is the classic baseline**: small, fast, but patchy coverage and
  mixed licenses; bn and ja would go through the multilingual model.
- **CC-BY-4.0** (some Opus-MT pairs) allows commercial use with attribution:
  credit them where translations are credited.

## Excluded (license, size, or coverage)

| Model | Why not |
| --- | --- |
| NLLB-200 (all sizes) | CC-BY-NC-4.0: non-commercial |
| Tower-Plus 9B / 72B (Unbabel) | CC-BY-NC-SA-4.0; also lacks ar, bn, tr, id |
| Command A Translate (Cohere) | CC-BY-NC-4.0; 111B (doesn't fit) |
| Aya Expanse 8B / 32B, Tiny Aya (Cohere) | CC-BY-NC-4.0 |
| Anything 70B-class | doesn't fit in ~36 GB at a useful precision |

## Evaluators (score translations; never ship)

| Model / tool | License | Needs a reference? | Notes |
| --- | --- | --- | --- |
| **MetricX-24-Hybrid** Large / XL / XXL (Google) | Apache-2.0 | no (QE mode) or yes | ungated; scores 0–25, lower is better; XL is a good size here |
| COMET-Kiwi (wmt22 / wmt23-XL) (Unbabel) | CC-BY-NC-SA-4.0 | no | gated; fine for evaluation only |
| chrF (`sacrebleu`) | Apache-2.0 | yes | for back-translation: our English source is the reference |
| An LLM judge | per model | no | for tone (calm, informal) and fluency |

**Bias to design around.** TranslateGemma was trained with MetricX-QE as a
reward (its technical report, arXiv 2601.09012), so MetricX will tend to
favour it. Score with at least two independent signals (MetricX and
COMET-Kiwi, plus back-translation chrF) and report them separately; never
rank on MetricX alone. Likewise the LLM judge must come from a family no
contestant belongs to: with Gemma (TranslateGemma), Hunyuan (Hy-MT2) and Qwen
in the race, Mistral Small 3.2 24B (Apache-2.0, ~14 GB at 4-bit) is a
candidate judge, though its quality in bn and hi needs a sanity check.

## Tooling

Python with `uv`, versions pinned in `mise.toml`, in its own directory
(never the app's dependencies): `mlx-lm` for the MLX models; `transformers`
on MPS for MADLAD, M2M100, Opus-MT and Seed-X; `llama.cpp` only if we take
the 30B MoE without converting it. About 1,100 short strings in all, so
memory, not speed, is the limit; the downloads (~50–100 GB for the whole
field) fit easily.
