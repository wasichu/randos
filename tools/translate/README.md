# The translation shootout (Phase 6)

Machine-translates the website's strings (`priv/gettext/default.pot`) into
the 14 other practice languages, checks and scores every translation, and
fills the `.po` files with each string's best translation. No person chooses
or reviews them (the owner's rule): the models, the evaluators and the
checks decide everything; a visitor's "Suggest a fix" (`/translations`) is
welcome when it comes, and a later run never overwrites it. The plan is in
`docs/architecture/refactor_plan.md` (Phase 6); the field of models, their
licenses, and memory needs are in `docs/architecture/translation_models.md`.

Its own Python project, never part of the app: Python 3.13 and exact
versions in `pyproject.toml` / `uv.lock`, installed by `uv`.

```bash
just translate-test                  # the checks and the fill rule (offline, no models)
cd tools/translate
uv run --group models python -m randos_translate.cli run --model opus-mt --locales es --limit 12
uv run --group models python -m randos_translate.cli score --scorer metricx results/shootout-*.json
uv run python -m randos_translate.cli review                     # picks each string's translation
uv run python -m randos_translate.cli fill --best --locale all --redo
```

`uv run --group X` re-syncs the one shared `.venv` to that group, removing
the others' packages: never run it while a model of another group is
running (add `--group X` to keep a running group's packages, e.g.
`uv run --group models --group dev pytest`).

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
  glossary terms "randos" and "rando" kept exactly, lowercase included
  (it's a name, lowercase even starting a sentence), as words of their
  own: "espe*rando*" and the French "*rando*nnée" (a hike) don't count,
  a Turkish suffix does ("randoyu"); a sane length
  (tighter for buttons, looser for dense CJK); the letters in the locale's
  script (Latin names copied from the English don't count); one
  translation shaped like the source (no list of alternatives, no
  leftover protect token);
- **scores** (`scoring.py`): back-translation chrF against the English.
  The model-based scores come afterwards from `score` (below) and are
  `"pending"` until then;
- a per-locale summary: how many pass every check, failures by check,
  mean chrF.

Every contestant's output goes through `models.brand_case` first, which
lowercases "randos"/"rando" wherever a model capitalized it ("Randos est…",
"Randoslar"); `cli brand-case` applies it to runs made before it existed.

`run` never touches the `.po` files. `run --append <its earlier run>`
translates only what that run lacks: strings the template gained and, for
a model that takes context, strings whose context changed.

## Context

Short strings are ambiguous ("About": a page, or "approximately"?), so the
app gives them a translator comment, `gettext_comment/1` just before the
call (a `<% gettext_comment("…") %>` in HEEx), which `mix gettext.extract`
writes as `#.` in the template. A string's context (`po.Source.context`)
is its comment, else what its msgctxt says ("A button label."). The
instruction models get it in their prompt (Hy-MT2 through its card's
background-information prompt, TranslateGemma as a line before the text),
and so does the judge; the seq2seq models can't take it, and the
per-string pick then prefers whichever contestant got the sense right.

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

The judge runs last, after MetricX and COMET-Kiwi, and over every run at
once (`score --scorer judge results/*.json`: what it must see depends on
all the models' translations of a string). It sees only what can change a
pick (`review.to_judge`): translations passing every check, of strings
still in the template, and of those the finalists, best mean rank over
MetricX and COMET-Kiwi first, a tied group at a time. It stops at the
first group with one rated above the veto (4), unless one rated at or
below it came first and nothing yet rates 7 or more; it goes on in rounds
until no string needs more. A string missing MetricX or COMET-Kiwi has
all its passing translations judged, since the judge then stands in. On
the shootout's runs that is 2,635 judgements instead of 13,270. It can
pick differently from judging everything on a few strings (9 of 1,974):
the mean rank depends on which translations are left, and judging
everything vetoes ones that were never in contention.

Verdicts are cached in `results/judge-cache.json`, keyed by everything the
judge saw (its model, the rubric, the locale, the context, the English, the
translation), so two models with the same output are judged once and a
re-run judges only what changed; a changed comment or rubric is judged
afresh. `--redo` ignores the cache. The prompts go to mlx-lm's
`batch_generate` together (greedy, as before). On the review page a
string's judge column ranks models only when the judge saw them all.

## Which translation ships

Each string on its own (`review.pick`): among the translations passing
every check, the best mean rank over **MetricX and COMET-Kiwi** (ranked
among the passing ones, ties sharing their rank). The judge breaks ties,
or stands in beside MetricX when COMET-Kiwi has no score; MetricX alone
never decides. Further ties go to back-translation chrF, then the shorter
text, then the text itself, never a model's name. A string that no
translation passes stays empty, and the site shows the English.

## Filling the .po files

`fill --best` writes each string's pick (from `results/review.json`, so
run `review` first) and records in `state/<locale>.json` which model wrote
each entry. `fill <run>` writes one run's passing translations instead.
Either **fills only empty entries**; with `--redo` it also replaces
entries that still hold exactly what the machine wrote last time, and
empties those that no longer have a passing translation. Anything a person
wrote is never overwritten. Plural strings are left to people: a model
translates one string, a plural needs a form per plural rule.

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
up once MetricX or COMET-Kiwi runs), the translation that **ships**
(above), and per locale the model **picked most**. The dev-only page
(`RandosDev.TranslationReviewLive`) shows it, with filters for each of
those.

## Contestants

| Name | Model | License | Group | Locales |
| --- | --- | --- | --- | --- |
| `opus-mt` | Helsinki-NLP Marian, one per pair (`models/opus_mt.py`) | Apache-2.0 / CC-BY-4.0 per pair | `models` | 10 (no pt, ko, bn, ja) |
| `m2m100` | facebook/m2m100_418M | MIT | `models` | all 14 |
| `madlad-400` | google/madlad400-7b-mt, bf16, one string at a time (the 10B didn't fit: `models/madlad.py`) | Apache-2.0 | `models` | all 14 |
| `hy-mt2` | Tencent Hy-MT2 7B, 8-bit MLX | Apache-2.0 | `mlx` | all 14 |
| `translategemma-4b`, `-12b` | Google TranslateGemma, 8-bit MLX | Gemma terms | `mlx` | all 14 |
| `translategemma-27b` | Google TranslateGemma 27B, 4-bit MLX | Gemma terms | `mlx` | all 14 |

The seq2seq models (Opus-MT, M2M100, MADLAD) get placeholders and glossary
terms swapped for `[0]`, `[1]`... tokens and restored after
(`protect`/`restore`). The instruction models get the original text, with
the prompt their model card documents (`models/mlx_chat.py`): Hy-MT2's
terminology prompt carries the glossary; TranslateGemma's chat template
takes the text alone. Both get a string's context (above). All decode
greedily or with beam search, so a rerun gives the same text.

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
