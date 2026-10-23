# Translating randos

Each language is one file: `<code>/LC_MESSAGES/default.po` (`es` Spanish,
`zh` Chinese, `hi` Hindi, `ar` Arabic, `pt` Portuguese, `bn` Bengali, `ru`
Russian, `ja` Japanese, `fr` French, `de` German, `ko` Korean, `it`
Italian, `tr` Turkish, `id` Indonesian, `vi` Vietnamese, `ur` Urdu, `sw`
Swahili, `fa` Persian, `fil` Filipino). The translations were made by
machine and nobody has reviewed them yet, so fixes are very welcome.

**The easy way:** [randos.slowinput.org/translations](https://randos.slowinput.org/translations)
lists every string in your language next to the English. Press "Suggest
a fix": a GitHub issue opens with everything filled in but your fix
(`.github/ISSUE_TEMPLATE/translation.yml`). Submit it, and the
translation-fix workflow (`.github/workflows/translation-fix.yml`) checks
it (the rules below) and opens a pull request changing that one entry, or
comments on the issue saying why it can't. A maintainer reviews and
merges; the next deploy ships it. The workflow records nothing in
`tools/translate/state`, so the shootout treats your text as a person's
and never overwrites it.

**Or edit the file** on GitHub and open a pull request. An entry looks
like this; change only the `msgstr`:

```po
msgctxt "button"
msgid "Next rando"
msgstr "Siguiente rando"
```

- **Keep "randos" and "rando" as they are.** randos is the name (always
  lowercase); a rando is the stranger you're matched with, and the word
  stays.
- **Keep every `%{...}` placeholder** exactly as written, in whatever
  position reads naturally; the app fills it in (`%{time}` becomes "9:57").
- **Tone:** calm, plain, and informal. randos is low-pressure on purpose.
- **Keep it short** where it's a button (`msgctxt "button"`).
- `msgctxt` and the `#.` comments above an entry say where it appears.
- An empty `msgstr` shows the English text, so a partial file is fine.

Don't change a `msgid`: it's the English source, and it comes from the
code (`mix gettext.extract --merge` regenerates these files). Your fixes
are kept when the machine translations are re-run: the pipeline
(`tools/translate/`) fills only empty entries, and never overwrites one a
person has changed. (After changing strings in the code, `just
translate-update` translates just those; `just translate-update tui` for
the terminal client's.)
