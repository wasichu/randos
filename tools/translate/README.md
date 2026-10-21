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
uv sync --group models               # torch + transformers, for the seq2seq models
uv run --group models python -m randos_translate.cli run --model opus-mt --locales es --limit 12
uv run python -m randos_translate.cli fill results/<run>.json --locale es
```

## What a run does

`run` translates each source string, translates it back to English, and
records for each one (in `results/<model>-<time>.json`, which the results
page is built from):

- **checks** (`checks.py`): placeholders such as `%{time}` intact; the
  glossary terms "randos" and "rando" kept; a sane length (tighter for
  buttons); the letters in the locale's script;
- **scores** (`scoring.py`): back-translation chrF against the English;
  MetricX-24 and COMET-Kiwi (reference-free quality estimation, two
  independent models, since TranslateGemma was trained on MetricX); and a
  tone judge from a family no contestant belongs to. The last three are
  wired but not run yet (`"pending"` in the results);
- a per-locale summary: how many pass every check, failures by check,
  mean chrF.

`run` never touches the `.po` files.

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

Wired: **opus-mt** (Helsinki-NLP Marian models, one per language pair;
`models/opus_mt.py` lists the pairs: `es`, `ar`) and **m2m100**
(facebook/m2m100_418M, MIT, ~2 GB, one model for all 14 locales and the
back-translation). Planned (`models/__init__.py`): Hy-MT2, TranslateGemma,
MADLAD-400. Seq2seq models get placeholders
and glossary terms swapped for `[0]`, `[1]`... tokens and restored after
(`protect`/`restore`); instruction models get the same rules in the prompt.

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
