# The languages randos supports

randos has 15 practice languages, which are also the site's interface
languages:

English, Español (Spanish), 中文 (Chinese), हिन्दी (Hindi), العربية (Arabic),
Português (Portuguese), বাংলা (Bengali), Русский (Russian), 日本語 (Japanese),
Français (French), Deutsch (German), 한국어 (Korean), Italiano (Italian),
Türkçe (Turkish), Bahasa Indonesia (Indonesian).

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

Rankings differ by source and by year (how second-language speakers are
counted, and whether Chinese or Arabic is one language or several), so
this is a judgement, not a formula.

**Widely spoken, not here yet:** Urdu, Vietnamese, Marathi, Telugu,
Tamil, Persian, Swahili, Tagalog, among others. Nothing rules them out;
each new language needs people on both sides to be useful, and a
translation of the site.

## Adding one

A language is a stable code (ISO 639-1, like `vi`) in a few places:

- `lib/randos/conversation_languages.ex`: the list itself, with its
  name in its own language; matching, the forms and the channel's
  `languages` all read it, and the interface languages
  (`RandosWeb.Locale`) follow it. Right-to-left scripts go in
  `RandosWeb.Locale`'s `@rtl`.
- `priv/gettext/<code>/LC_MESSAGES/default.po`: the site's text
  (`mix gettext.merge priv/gettext --locale <code>` makes the file).
- `tools/translate/randos_translate/po.py` (`LOCALES`) and
  `checks.py` (the script a translation should be written in), so the
  translation shootout fills it; then a review, as for the others
  (`priv/gettext/README.md`).

The TUI needs no change: it gets the list from the server when it joins.
