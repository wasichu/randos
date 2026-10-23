# Five new languages (research, 2026-10-22; built the same day)

**Outcome (2026-10-22).** All five added, as practice and interface
languages, appended to the list. The owner's decisions: all five; `fil`
for Filipino; for Swahili, MADLAD-400 (the 7B, which was already in the
field and runs one string at a time: the line below saying it failed on
the Mac is out of date, so the 3B wasn't needed) with Opus-MT left out of
`sw`; and a second judge, Qwen3 30B-A3B, for ur, sw and fil, where
Mistral's card doesn't list the language (`scoring.JUDGE_FOR`). Taken as
suggested: the system font for Urdu, no Hindi–Urdu hint for now, and no
human read (the owner's rule: models and checks decide). Of the extra
checks: NFC, "unchanged from English" and the Arabic letter forms were
built; language ID wasn't (lingua is a 172 MB dependency of every check
run; the judges catch a wrong language). Later the same day the owner
made Qwen a judge of every locale beside Mistral (Mistral still sits out
ur, sw and fil). Result: 142 of 142 strings in each of the five; MADLAD
7B picked most in ur, sw and fa, Hy-MT2 in vi and fil (the thin Swahili
field was MADLAD's to carry, as expected). The research follows as it
was.

Research for adding **Vietnamese (`vi`), Urdu (`ur`) and Swahili (`sw`)**,
and, if wanted, **Persian (`fa`) and Filipino (`fil` or `tl`)** as practice
and interface languages. Nothing here has been run: no model was
downloaded or tried. Facts come from Hugging Face model cards and API
metadata, the repo's code, and the 2026-10-22 shootout results
(`tools/translate/results/shootout-summary.json`, on the translation
worktree branch). Re-check the cards before downloading anything.

**Where the code lives.** At the time of writing, the shootout code was
on the translation run's branch; it has since merged into `main`.

## 1. Translation contestants

| | TranslateGemma 4B/12B/27B | Hy-MT2 7B | M2M100 418M | Opus-MT en→X / X→en | MADLAD-400 |
| --- | --- | --- | --- | --- | --- |
| **vi** | yes (`vi`) | yes (`vi`) | yes (`vi`) | [`opus-mt-en-vi`][en-vi] / [`opus-mt-vi-en`][vi-en] (Tatoeba chrF 0.54) | yes |
| **ur** | yes (`ur`) | yes (`ur`) | yes (`ur`) | [`opus-mt-en-ur`][en-ur] (Tatoeba chrF 0.39, weak), better: [bible-big `…-iir`][iir] with `>>urd<<` (Flores chrF 0.48) / [`opus-mt-ur-en`][ur-en] | yes |
| **sw** | yes (`sw`) | **no** | yes (`sw`) | [`opus-mt-en-sw`][en-sw] (GlobalVoices chrF 0.53) / **no `sw-en`**; only `opus-mt-swc-en` | yes |
| **fa** | yes (`fa`) | yes (`fa`) | yes (`fa`) | **no direct pair** (`en-fa`, `fa-en`, `tc-big-en-fa` don't exist): [bible-big `…-iir`][iir] with `>>pes<<` (Flores chrF 0.49) / [`opus-mt-tc-bible-big-iir-en`][iir-en] | yes |
| **fil/tl** | yes, but only as `fil-PH` or `tl` | yes (`tl`, "Filipino") | yes (`tl`) | [`opus-mt-en-tl`][en-tl] (Tatoeba chrF 0.58) / [`opus-mt-tl-en`][tl-en] | yes (`fil`) |

Evidence: TranslateGemma's 55 languages are WMT24++'s, whose [dataset
card][wmt24pp] has `en-vi_VN`, `en-ur_PK`, `en-sw_KE`/`sw_TZ`, `en-fa_IR`,
`en-fil_PH`; its chat template (in [`mlx-community/translategemma-12b-it-8bit`][tg-mlx],
`chat_template.jinja`) maps codes to names and has `vi`, `ur`, `sw`, `fa`,
`tl` ("Tagalog") and `fil-PH` ("Filipino"), but **no plain `fil`**, so an
unknown code reaches the template undefined. Hy-MT2's [card][hy] lists 33
languages: vi, ur, fa and Filipino (`tl`); no Swahili. M2M100's codes
(transformers' `FAIRSEQ_LANGUAGE_CODES`) include `vi ur sw fa tl`. MADLAD's
[card metadata][madlad] lists 419 codes, `vi ur sw fa fil` among them. All
Opus-MT repos named here are Apache-2.0 (API metadata).

Code mismatches to handle in the adapters:
- **Filipino**: `tl` for Hy-MT2, M2M100 and Opus-MT; `fil-PH` (or `tl`) for
  TranslateGemma; `<2fil>` for MADLAD. Prompt names: "Filipino".
- **Persian**: Opus-MT's multi-target model needs `>>pes<<` (Iranian
  Persian). `>>fas<<` is the macrolanguage and `>>prs<<` is Dari; the old
  [`opus-mt-en-iir`][en-iir] scores chrF 0.23 for Persian, so don't use it.
- **Urdu**: same multi-target model with `>>urd<<`. `opus_mt.py`'s
  `TARGET_TOKEN` already handles this shape (as for `zh`).
- **Swahili**: there's no `sw-en`. [`swc`][swc] in ISO 639-3 is Congo Swahili, a
  different variety from the standard Swahili of Kenya and Tanzania, so
  `opus-mt-swc-en` is a poor back-translator. The harness pairs each
  locale with `(en→X, X→en)`, so either wire `en-sw` with `swc-en` and
  note it, or leave Opus-MT out of `sw`.
- The "bible-big" models are trained on OPUS with Bible data among it.
  Their register may come out formal or archaic: that's for the checks
  and the judge to show, not a reason to leave them out.

**Thin coverage: Swahili.** Without Hy-MT2 (which won 9 of 14 locales)
the field is three TranslateGemma sizes, M2M100 and a lopsided Opus-MT.
MetricX favours TranslateGemma, and that bias matters most here.
Suggested extra contestant: **MADLAD-400 3B** ([`google/madlad400-3b-mt`][madlad],
Apache-2.0, 2.94B parameters, about 6 GB in bf16). The 7B failed on the
Mac because of MPS generation buffers, not the weights (`models/madlad.py`),
so the 3B may fit with small batches and the memory guard. **Untested.**
If it fits, add it for all five languages: it's the only contestant that
covers every one with no code games. NLLB stays out (CC-BY-NC).

## 2. Evaluators

| | MetricX-24 (mT5) | COMET-Kiwi (XLM-R) | Back-translation | Tone judge (Mistral Small 3.2) |
| --- | --- | --- | --- | --- |
| vi | in mT5 | in XLM-R | all contestants | **listed** on the card |
| ur | in mT5 | in XLM-R | all | not listed |
| sw | in mT5 | in XLM-R | not Hy-MT2; Opus-MT only through `swc-en` | not listed |
| fa | in mT5 | in XLM-R | all (Opus-MT through `iir-en`) | **listed** ("Farsi") |
| fil/tl | in mT5 (`fil`) | in XLM-R (`tl`) | all | not listed |

- **MetricX-24** ([card][metricx]) starts from [mT5][mt5], whose mC4 has
  all five (API metadata: `vi ur sw fa fil`), and was trained on WMT'15–'22 human ratings plus synthetic
  data. None of the five is a WMT language pair, so it works through
  transfer. The card makes no per-language claims.
- **COMET-Kiwi** (`Unbabel/wmt22-cometkiwi-da`) is built on [XLM-R][xlmr]
  (100 languages; the API metadata lists `vi ur sw fa tl` among them).
  Its training pairs, as its [WMT22 paper][kiwi] describes them, don't
  include any of the five (the gated card wasn't read), so it also works
  through transfer. Expect it to be weaker for ur, sw and tl, which have
  far less web text than vi and fa (see the per-language data table in the
  [XLM-R paper][xlmr-paper]).
- **Back-translation chrF** needs each contestant's reverse direction:
  fine everywhere except Opus-MT for sw (above).
- **Tone judge.** [Mistral Small 3.2's card][mistral] lists `fa` and `vi`
  but not `ur`, `sw` or `tl`. Our own run is a warning even for listed
  languages: the best judge mean any model gets in bn (7.0) or hi (7.2) is
  the lowest best of all 14 locales, below even the worst model's mean in
  es, pt or id (7.7–7.9). Meanwhile COMET-Kiwi's best scores for bn and hi
  (0.83, 0.82) are among the highest of any locale.
  So expect it to be **reasonable for vi and fa, unreliable for ur, sw and tl**.

Recommended extra sanity checks (in `checks.py`, offline, no GPU):
- **For ur, sw and tl, take the judge out of `mean_rank`**; show it as its
  own column and as a tiebreaker only.
- **Language ID** with [lingua][lingua] (`lingua-language-detector`,
  Apache-2.0, offline; supports Vietnamese, Urdu, Swahili, Persian and
  Tagalog). It catches what the script check can't: Latin-script output in
  the wrong language (English left as is, Indonesian or Malay for Tagalog),
  and Urdu, Persian and Arabic, which share a script. Apply it to strings
  longer than a few words; short UI strings confuse any detector.
- **Unchanged from English**: fail a translation equal to its source (once
  the glossary terms and placeholders are taken out).
- **Arabic-script letter forms**: Urdu and Persian use FARSI YEH (U+06CC)
  and KEHEH (U+06A9), not Arabic's YEH (U+064A) and KAF (U+0643), a
  common model slip; a warning per string.
- **NFC**: normalize model output to NFC before the checks and on `fill`
  (nothing in the harness normalizes today). Vietnamese can come
  decomposed: "Tiếng Việt" is 10 code points in NFC and 14 in NFD, which
  shifts the length check and splits `.po` diffs.
- **A human look** for the must-haves: a speaker reading the winner's
  ~140 strings once, or the "Suggest a fix" flow
  (`priv/gettext/README.md`) after launch.

## 3. The app

| | Endonym label | Script, direction | Script check (`checks.py`) | Plural-Forms (Expo) |
| --- | --- | --- | --- | --- |
| vi | `Tiếng Việt (VI)` | Latin with stacked diacritics, LTR | `LATIN_LOCALES` | `nplurals=1; plural=0;` |
| ur | `اردو (UR)` | Arabic script (Nastaliq style), **RTL** | `SCRIPTS["ur"] = {"ARABIC"}` | `nplurals=2; plural=(n != 1);` |
| sw | `Kiswahili (SW)` | Latin, LTR | `LATIN_LOCALES` | `nplurals=2; plural=(n != 1);` |
| fa | `فارسی (FA)` | Arabic script, **RTL** | `SCRIPTS["fa"] = {"ARABIC"}` | `nplurals=2; plural=(n > 1);` |
| fil | `Filipino (FIL)` or `Filipino (TL)` | Latin, LTR | `LATIN_LOCALES` | `fil`: `nplurals=2; plural=(n > 1);` (`tl`: not known, see below) |

- **Script check.** `_script` reads the start of each letter's Unicode
  name. Checked: precomposed Vietnamese letters are named `LATIN … WITH …`
  (ệ, đ, ư, ơ); decomposed combining marks fail `isalpha()` and are
  skipped, so **both forms pass**. Every Urdu and Persian letter tried is
  `ARABIC …` (ٹ ڈ ڑ ں ے ھ ی ک پ چ ژ گ); the zero-width non-joiner Persian
  uses is skipped. The check can't tell Urdu from Persian or Arabic (hence
  language ID above), but it does catch Urdu written in Devanagari.
- **Direction.** `RandosWeb.Locale`'s `@rtl ~w(ar)` becomes `~w(ar fa ur)`;
  `<html dir>` follows. Arabic already exercises the RTL layout.
- **Labels.** `Locale` strips the label's code with `~r/ \([A-Z]{2}\)$/`,
  so a three-letter `(FIL)` would show up in the switcher: widen it to
  `{2,3}` if `fil` is chosen.
- **Fonts.** `app.css` sets no `font-family`, so the site uses Tailwind's
  system font stack, and `<html lang>` (set by `Locale`) lets the browser
  pick a font for the language. Urdu therefore renders in whatever the
  device offers for `lang="ur"`: Nastaliq on some systems, the plainer
  Naskh style on others. Both are readable; Nastaliq is what Urdu readers
  expect. Nastaliq is tall, so check buttons, chips and anything with
  tight `leading-*` or fixed heights for clipping; a `:lang(ur)` line-height
  rule in `app.css` may be all it needs. Vietnamese's stacked accents
  (ệ, ở) need the same look. Shipping a font (Noto Nastaliq Urdu, OFL,
  vendored and served from our own origin, so the first-party rule allows
  it) is an owner decision: better Urdu, at the cost of a large file.
- **Plural forms.** `default.pot` has one plural (`any of the %{count}
  language(s) you picked`). `mix gettext.merge priv/gettext --locale <code>`
  takes the header from Expo's list for `vi ur sw fa fil`. Expo doesn't
  know `tl`: creating it without a header raises `UnknownLocaleError`, so
  `tl` needs `--plural-forms-header "nplurals=2; plural=(n > 1);"` once; at
  runtime gettext then reads the header from the file.
- **Browser locales.** `Locale.from_accept_language` and
  `ConversationLanguages.code_from_locale` keep only the primary subtag, so
  `fa-AF`, `sw-KE`, `ur-PK` and `vi-VN` resolve. Filipino browsers send
  `fil` (sometimes `fil-PH`), and only rarely `tl`: whichever code randos
  uses, map the other one to it.

### Filipino: `fil` or `tl`? (owner's decision)

| | `fil` | `tl` |
| --- | --- | --- |
| Browsers, CLDR | match (`fil`) | needs a `fil`→`tl` alias |
| Expo plural rule | known | needs an explicit header once |
| `docs/languages.md` "ISO 639-1" rule | breaks it (639-2/3 code) | fits |
| Label regex in `Locale` | needs `{2,3}` | fine |
| Models | Hy-MT2, M2M100 and Opus-MT need `tl`; TranslateGemma `fil-PH` | TranslateGemma, Hy-MT2, M2M100 and Opus-MT take `tl` as is; MADLAD needs `fil` |

**Suggestion: `fil`**, displayed "Filipino". It's what the language is
officially called, it's what browsers send, and gettext knows it; the
model codes are mapped in the adapters anyway. The cost is a one-line rule
change ("ISO 639-1, or 639-2 where browsers use it") and the regex.

## 4. Matching

**Hindi and Urdu** are one spoken language at the everyday level
(Hindustani). They diverge in formal vocabulary (Sanskrit vs Persian and
Arabic loans) and completely in script, which doesn't matter for audio.
Without changing the matching rule (`Entry.compatible?/2`: each person's
speaking language among the other's hearing languages), randos could:

- **A. Pre-check the kin language.** `HomeLive.default_preferences/1`
  already pre-checks the speaking language among the hearing languages
  the first time the form appears. A small kin map (`ur ↔ hi`), used only
  there, would pre-check Hindi for an Urdu speaker and the reverse. The
  person can uncheck it, and matching is untouched. It only helps when
  both sides have it checked, so both directions need it.
- **B. A hint instead of a default.** A line under the hearing chips ("Hindi
  and Urdu speakers usually understand each other") with the chip one tap
  away. Gentler: someone practising Urdu specifically isn't nudged.

Both are browser-only. The TUI builds its list from the join reply's
`languages`, so doing the same there means a field on it (e.g. `kin`): a
protocol change, so the AGENTS.md mini-pass applies. Suggestion: B in the
browser first; the TUI later if it proves useful. The interface languages
stay separate (`hi` in Devanagari, `ur` in Arabic script).

Among the five:
- **Persian, Dari, Tajik.** Dari (Afghanistan) is Persian under another
  name, and Dari speakers will pick `فارسی`; the UI text will be Iranian
  Persian, which they read without trouble. Tajik is close in speech but
  written in Cyrillic and drifts further; leave it out. One `fa` entry.
- **Filipino and Tagalog** are one entry (Filipino is standardized
  Tagalog). Everyday speech mixes in English (Taglish); a formal UI
  translation may read stiffly, which is a tone question for the judge and
  a reviewer.
- **Swahili**: Kenyan and Tanzanian Standard Swahili are one entry.
  **Malay** isn't proposed, but would sit next to Indonesian the way Urdu
  sits next to Hindi.

## 5. Plan and effort

**Order.** (1) Owner decisions below. (2) App: languages, RTL, labels,
`.po` files, tests; this can ship on its own, since an empty `msgstr`
falls back to English. (3) Shootout code and checks, after the
translation branch merges. (4) Runs with `run --append` (existing locales
aren't rerun) and resumable scoring, then `review`, `fill`, and a look.
(5) Docs.

**Files.** `docs/languages.md`'s "Adding one" is right but incomplete. A
fuller list to replace it with:

| File | Change |
| --- | --- |
| `lib/randos/conversation_languages.ex` | five `{"Tiếng Việt (VI)", "vi"}`-style entries |
| `lib/randos_web/locale.ex` | `@rtl ~w(ar fa ur)`; label regex `{2,3}` if `fil`; the moduledoc ("14 other") and the `dir` docstring ("for Arabic"); a `tl`→`fil` alias in `from_accept_language` |
| `lib/randos/conversation_languages.ex` `code_from_locale` | the same alias |
| `priv/gettext/<code>/LC_MESSAGES/default.po` | `mix gettext.merge priv/gettext --locale <code>` ×5 |
| `assets/css/app.css` | maybe a `:lang(ur)` (and `vi`) line-height rule, after a visual check |
| `test/randos_web/locale_test.exs` | `length(Locale.all()) == 15` → 20; `dir("ur")`, `dir("fa")` |
| `test/randos/conversation_languages_test.exs` | its full list of codes (`codes/0`); a `fil-PH` → `fil` case |
| `tools/translate/randos_translate/po.py` | `LOCALES` (also what the "Suggest a fix" workflow accepts) |
| `tools/translate/randos_translate/checks.py` | `SCRIPTS` for ur, fa; `LATIN_LOCALES` for vi, sw, fil; the new checks (section 2) |
| `tools/translate/randos_translate/models/__init__.py` | `NAMES` (Vietnamese, Urdu, Swahili, Persian, Filipino) |
| `models/mlx_chat.py` | per-model locales (Hy-MT2 without `sw`); TranslateGemma code map (`fil`→`fil-PH`) |
| `models/m2m100.py` | `LOCALES`; `fil`→`tl` |
| `models/opus_mt.py` | `PAIRS` and `TARGET_TOKEN` (vi, ur, fa, fil; sw as decided) |
| `models/madlad.py` | if the 3B is tried: its repo, and `<2fil>` |
| `tools/translate/tests/` | script and new-check cases for the five |
| `README.md` (line 50), `priv/gettext/README.md` (locale list), `docs/languages.md`, `docs/architecture/translation_models.md` ("Our 14"), `tools/translate/README.md` (contestants table), `docs/architecture/refactor_plan.md` (Phase 6) | counts and lists |

The TUI needs no code change; it gets the list from the server (Arabic
script already renders there however the terminal manages it).

**Shootout time on the Mac**, per new locale, from the 2026-10-22 run
(about 142 strings, translation and back-translation; each run's seconds
divided by its locales):

| Model | Per locale | | Scorer | Per locale, per model |
| --- | --- | --- | --- | --- |
| Opus-MT | ~1 min | | MetricX-24 | ~5 s |
| M2M100 418M | ~1 min | | COMET-Kiwi | ~5 s |
| TranslateGemma 4B | ~1.2 min | | Tone judge | **~5 min** |
| Hy-MT2 7B | ~2.5 min | | | |
| TranslateGemma 12B | ~4 min | | | |
| TranslateGemma 27B | ~7.5 min | | | |

So one new locale with the six contestants is about 17 minutes of
translation, about 30 minutes of judging and a couple of minutes of QE:
**roughly 50 minutes per language, 4 hours for all five** (a little less
for Swahili, without Hy-MT2). MADLAD-3B would add an unknown amount (the
7B did about 2.6 minutes per locale before it ran out of memory). New
downloads are small: about six Opus-MT models of 300 MB–1 GB, plus MADLAD-3B
(~6 GB) if tried.

## Open decisions for the owner

1. **`fil` or `tl`** for Filipino (suggestion: `fil`).
2. **Which of the five, and when**: the must-haves only, or all five.
   Ship them as practice languages first, with English interface text
   until translated? (Possible, since an empty `msgstr` falls back to
   English, but the switcher would then list languages whose pages are in
   English.)
3. **Swahili's field**: try MADLAD-400 3B; and whether Opus-MT runs with a
   Congo Swahili back-translator or sits `sw` out.
4. **The judge for ur, sw and tl**: a tiebreaker only, or a second judge
   from a family not in the race (Qwen, if it stays out of the field;
   check its card for these languages first).
5. **Hindi–Urdu**: a hint (B), a pre-check (A), or neither; browser-only or
   with a protocol field for the TUI.
6. **A Nastaliq webfont** for Urdu, or the system font.
7. **Where the five go in the list**: appended, or placed by number of
   speakers.
8. **A human read** of the must-have languages before launch, or after,
   through "Suggest a fix".

[en-vi]: https://huggingface.co/Helsinki-NLP/opus-mt-en-vi
[vi-en]: https://huggingface.co/Helsinki-NLP/opus-mt-vi-en
[en-ur]: https://huggingface.co/Helsinki-NLP/opus-mt-en-ur
[ur-en]: https://huggingface.co/Helsinki-NLP/opus-mt-ur-en
[en-sw]: https://huggingface.co/Helsinki-NLP/opus-mt-en-sw
[en-tl]: https://huggingface.co/Helsinki-NLP/opus-mt-en-tl
[tl-en]: https://huggingface.co/Helsinki-NLP/opus-mt-tl-en
[en-iir]: https://huggingface.co/Helsinki-NLP/opus-mt-en-iir
[iir]: https://huggingface.co/Helsinki-NLP/opus-mt-tc-bible-big-deu_eng_fra_por_spa-iir
[iir-en]: https://huggingface.co/Helsinki-NLP/opus-mt-tc-bible-big-iir-en
[wmt24pp]: https://huggingface.co/datasets/google/wmt24pp
[tg-mlx]: https://huggingface.co/mlx-community/translategemma-12b-it-8bit
[hy]: https://huggingface.co/tencent/Hy-MT2-7B
[madlad]: https://huggingface.co/google/madlad400-3b-mt
[metricx]: https://huggingface.co/google/metricx-24-hybrid-xl-v2p6
[mt5]: https://huggingface.co/google/mt5-xl
[xlmr]: https://huggingface.co/FacebookAI/xlm-roberta-large
[mistral]: https://huggingface.co/mistralai/Mistral-Small-3.2-24B-Instruct-2506
[lingua]: https://github.com/pemistahl/lingua-py
[kiwi]: https://arxiv.org/abs/2209.06243
[xlmr-paper]: https://arxiv.org/abs/1911.02116
[swc]: https://iso639-3.sil.org/code/swc
