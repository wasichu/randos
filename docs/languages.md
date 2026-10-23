# The languages randos supports

randos has 20 practice languages, which are also the site's interface
languages:

English, Español (Spanish), 中文 (Chinese), हिन्दी (Hindi), العربية (Arabic),
Português (Portuguese), বাংলা (Bengali), Русский (Russian), 日本語 (Japanese),
Français (French), Deutsch (German), 한국어 (Korean), Italiano (Italian),
Türkçe (Turkish), Bahasa Indonesia (Indonesian), Tiếng Việt (Vietnamese),
اردو (Urdu), Kiswahili (Swahili), فارسی (Persian), Filipino.

## Why these

The reasoning wasn't written down when the list was made, so this records
it as it looks now. The list mixes two things:

- **Reach.** Most of the list is among the world's most widely spoken
  languages, counting second-language speakers as well as native ones:
  English, Chinese, Hindi, Spanish, Arabic, French, Bengali, Portuguese,
  Russian, Japanese, Indonesian. More speakers means more people who
  might practise, and more people to practise with.
- **Learners.** German, Korean, Italian and Turkish have fewer speakers
  than some languages that aren't here, but they're among the languages
  people most often set out to learn. randos only works when both sides
  of a call want it: someone speaking a language and someone happy to
  hear it.

- **The next most spoken (added 2026-10-22).** Vietnamese, Urdu,
  Swahili, Persian and Filipino were among the most widely spoken
  languages left, each with tens of millions of speakers or more, many of
  them second-language speakers. Urdu and Hindi
  are one spoken language at the everyday level (Hindustani), written in
  different scripts; they stay two entries, so a learner of one isn't
  matched with the other unless they pick it. Persian covers Dari; Filipino
  is standardized Tagalog; Kenyan and Tanzanian Swahili are one entry.

Rankings differ by source and by year (how second-language speakers are
counted, and whether Chinese or Arabic is one language or several), so
this is a judgement, not a formula.

**Widely spoken, not here yet:** Marathi, Telugu, Tamil, Malay, among
others. Nothing rules them out;
each new language needs people on both sides to be useful, and a
translation of the site.

## Adding one

A language is a stable code (ISO 639-1 like `vi`, or the longer code
browsers send when there's no two-letter one in use, like `fil`) in a
few places:

- `lib/randos/conversation_languages.ex`: the list itself, with its
  name in its own language; matching, the forms and the channel's
  `languages` all read it, and the interface languages
  (`RandosWeb.Locale`) follow it. Right-to-left scripts go in
  `RandosWeb.Locale`'s `@rtl`. An older code browsers still send goes in
  its `@aliases` (`tl` is `fil`).
- `priv/gettext/<code>/LC_MESSAGES/default.po`: the site's text
  (`mix gettext.merge priv/gettext --locale <code>` makes the file).
- the translation shootout, so it fills the file:
  `tools/translate/randos_translate/po.py` (`LOCALES`), `checks.py`
  (the script a translation should be written in), `models/__init__.py`
  (`NAMES`), each contestant's locale list and code map (`models/`), and
  its judges (`scoring.judges_for`: both, or Qwen alone where Mistral's
  card doesn't list the language); then a run with `run --append`
  (`tools/translate/README.md`).

- the TUI's text: `clients/tui/priv/gettext/<code>/LC_MESSAGES/default.po`
  (`cd clients/tui && mix gettext.merge priv/gettext --locale <code>`),
  filled by the same shootout with `--catalog tui`. The TUI offers every
  language it has a file for (`Tui.Language`).

The TUI's conversation languages need no change: it gets the list from
the server when it joins.
