# The translation shootout (Phase 6)

Machine-translates the website's strings (`priv/gettext/default.pot`) into
the 14 other practice languages, checks and scores every translation, and
fills the `.po` files with the winners. The plan is in
`docs/architecture/refactor_plan.md` (Phase 6); the field of models, their
licenses, and memory needs are in `docs/architecture/translation_models.md`.

Its own Python project, never part of the app: Python 3.13 and exact
versions in `pyproject.toml` / `uv.lock`, installed by `uv`.

```bash
just translate-test                  # the checks and the fill rule (offline, no models)
cd tools/translate
uv run --group models python -m randos_translate.cli run --model opus-mt --locales es --limit 12
uv run --group models python -m randos_translate.cli score --scorer metricx results/shootout-*.json
uv run python -m randos_translate.cli fill results/<run>.json --locale es
```

Each kind of model has its own dependency group, and one `uv run` uses one
group (mlx-lm needs transformers 5, the rest stay on 4.x, so `pyproject.toml`
declares the groups as conflicting):

| Group | For | Brings |
| --- | --- | --- |
| `models` | Opus-MT, M2M100, MADLAD-400; the MetricX scorer | torch, transformers 4 |
| `mlx` | Hy-MT2, TranslateGemma; the tone judge | mlx-lm (transformers 5) |
| `comet` | the COMET-Kiwi scorer | unbabel-comet (PyTorch Lightning) |

Downloads go to the Hugging Face cache (`~/.cache/huggingface`). Two
models are gated: accept their terms on Hugging Face, then
`uv run --group models hf auth login` (TranslateGemma, the Gemma terms;
COMET-Kiwi, CC-BY-NC-SA, used only to score, never shipped).

## What a run does

`run` translates each source string, translates it back to English, and
records for each one (in `results/<model>-<time>.json`, which the results
page is built from):

- **checks** (`checks.py`): placeholders such as `%{time}` intact; the
  glossary terms "randos" and "rando" kept; a sane length (tighter for
  buttons); the letters in the locale's script;
- **scores** (`scoring.py`): back-translation chrF against the English.
  The model-based scores come afterwards from `score` (below) and are
  `"pending"` until then;
- a per-locale summary: how many pass every check, failures by check,
  mean chrF.

`run` never touches the `.po` files.

## Scoring

`score --scorer <name> <results files>` runs one model-based scorer over
runs already made and fills its scores in place. One scorer per process,
so it never shares memory with a contestant; run each over every run, or
a model scored by fewer scorers gets a skewed mean rank in `review`.

- **MetricX-24** (`metricx`; google/metricx-24-hybrid-xl-v2p6-bfloat16,
  Apache-2.0, ~7 GB): reference-free mode, an error score from 0 to 25,
  lower is better. Its checkpoints are mT5 read through a regression head
  that is the seq2seq model's own layers, so they load into transformers'
  `MT5ForConditionalGeneration` with no custom code (`scoring.MetricX`
  explains the reading, from google-research/metricx).
- **COMET-Kiwi** (`comet_kiwi`; Unbabel/wmt22-cometkiwi-da, ~2 GB, gated,
  non-commercial, so it only scores): 0 to 1, higher is better. Runs on the
  CPU (COMET's Lightning setup doesn't take MPS).
- **The tone judge** (`judge`; Mistral Small 3.2 24B Instruct, 4-bit MLX,
  Apache-2.0, ~14 GB): a 1–10 rating for meaning kept and the site's calm,
  informal register, with a one-line reason (`scoring.JUDGE_RUBRIC`).
  Mistral, because no contestant is from that family. Its reply must be the
  JSON asked for; anything else is a missing score, never a guess.

Never rank on MetricX alone: TranslateGemma was trained with MetricX as its
reward, so it's the one scorer that knows how to flatter it.

## Filling the .po files

`fill` writes one run's translations for a locale, and only those that pass
every check. It **fills only empty entries**. With `--redo` it also replaces
entries that still hold exactly what the machine wrote last time (recorded
in `state/<locale>.json`); anything a person changed is never overwritten.

## The review page

```bash
uv run python -m randos_translate.cli review   # results/*.json -> results/review.json
just dev                                         # then http://localhost:4000/dev/translations
```

`review` (`review.py`) combines every run (the latest per model, locale,
and string) and re-runs the checks, so an improved check applies to old
runs. For each locale and string it puts the models' translations side by
side and works out how much they **disagree** (1 − mean pairwise chrF,
strings sorted by it), whether the **evaluators disagree** (a model ranked
first by one scorer and last by another; needs two scorers, so it lights
up once MetricX or COMET-Kiwi runs), the **best** translation (passes
every check, best mean rank), and each locale's **winner** (passes every
check most often, then mean rank). The dev-only page
(`RandosDev.TranslationReviewLive`) shows it, with filters for each of
those.

## Contestants

| Name | Model | License | Group | Locales |
| --- | --- | --- | --- | --- |
| `opus-mt` | Helsinki-NLP Marian, one per pair (`models/opus_mt.py`) | Apache-2.0 / CC-BY-4.0 per pair | `models` | 10 (no pt, ko, bn, ja) |
| `m2m100` | facebook/m2m100_418M | MIT | `models` | all 14 |
| `madlad-400` | google/madlad400-10b-mt, bf16 | Apache-2.0 | `models` | all 14 |
| `hy-mt2` | Tencent Hy-MT2 7B, 8-bit MLX | Apache-2.0 | `mlx` | all 14 |
| `translategemma-4b`, `-12b` | Google TranslateGemma, 8-bit MLX | Gemma terms | `mlx` | all 14 |
| `translategemma-27b` | Google TranslateGemma 27B, 4-bit MLX | Gemma terms | `mlx` | all 14 |

The seq2seq models (Opus-MT, M2M100, MADLAD) get placeholders and glossary
terms swapped for `[0]`, `[1]`... tokens and restored after
(`protect`/`restore`). The instruction models get the original text, with
the prompt their model card documents (`models/mlx_chat.py`): Hy-MT2's
terminology prompt carries the glossary; TranslateGemma's chat template
takes the text alone. All decode greedily or with beam search, so a rerun
gives the same text.

## Status (2026-10-21)

Proved end to end on Opus-MT en→es and es→en (about 600 MB each in the
Hugging Face cache) on the first 12 strings: 12/12 pass the checks, mean
chrF 82.6; chrF singles out the one bad translation ("About randos" →
"Alrededor de randos", "around randos", 43.9). The proof's output is
`results/proof-opus-mt-es.json`. No `.po` file has been filled.

Then, for the review page: both small models on all 85 strings for `es`,
and the first 20 for `ar` (both) and `ja` (M2M100 only; no direct Opus-MT
pair). Opus-MT wins `es` (85/85 pass, mean chrF 78.3, vs 82/85 and 65.5);
M2M100 wins `ar` (19/20 vs 10/20: Opus-MT's en→ar returns nothing, "& &
&", or a loop of "hey" for short strings). Useful catches: M2M100 turned
"Mute" into "Muerte" (death), and "& & &" passing the script check exposed
a hole, now closed (no letters at all fails when the source has some).
