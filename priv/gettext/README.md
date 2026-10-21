# Translating randos

Each language is one file: `<code>/LC_MESSAGES/default.po` (`es` Spanish,
`zh` Chinese, `hi` Hindi, `ar` Arabic, `pt` Portuguese, `bn` Bengali, `ru`
Russian, `ja` Japanese, `fr` French, `de` German, `ko` Korean, `it`
Italian, `tr` Turkish, `id` Indonesian). The translations were made by
machine and nobody has reviewed them yet, so fixes are very welcome: edit
the file on GitHub and open a pull request, or open an issue saying what
reads wrong.

An entry looks like this; change only the `msgstr`:

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
person has changed.
