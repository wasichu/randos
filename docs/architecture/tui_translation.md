# Translating the TUI (plan, 2026-10-23; not built)

The owner's order (2026-10-23): TUI translation next, then invitations.
The TUI's text is all English today; the website's is in 20 languages,
machine-made through the shootout (`tools/translate/`). None of the
TUI's strings is one of the site's msgids word for word, so nothing
carries over: it's a new catalog through the same pipeline.

## What gets translated

- **The screens** (`Tui.View`, `Tui.View.StatusScreen`): titles, the
  form's labels, the call and vote text, key help ("q quit", "e end"),
  the meters' "You" / "Your rando", the status screen.
- **The log panel** (`Tui.Model.log/2`'s lines: "connected to the
  server", "reconnected; back in the call", status lines): people read it.
- **The media state's words** (`Tui.Media.State`: the mic test, device
  errors) and the relay reason words (`StatusScreen.relay_reason/1`).
- **The server's words** in the TUI's language: `error_message` today
  comes in English because the channel has no locale (below).

Left in English: `bin/randos --help`, `--check` and `--version` output
(a command line's flags and help are English by convention; a decision
below), the log file, and anything only developers see.

## How it fits

**Gettext in the TUI.** `{:gettext, "~> 1.0"}`, the server's own
dependency (pure Elixir; the release carries `priv/gettext`), with a
`Tui.Gettext` backend and `clients/tui/priv/gettext/default.pot`. Strings
are wrapped like the site's: `gettext/1` with `%{name}` placeholders,
never concatenation, `pgettext("key", …)` for key hints, and translator
comments where a string is ambiguous (the lesson from the site: the
models translate only what the context pins down). No plural forms (the
shootout leaves them to people): counts stay "label: n".

**Which language.** The TUI's own setting, a new `"language"` key in its
settings file (`Tui.Config`, local only; a file without it still loads,
as today's do), chosen on the idle screen (a key cycles through the
languages the TUI has, named in their own languages); without one, the
environment's (`LC_ALL`, `LC_MESSAGES`, `LANG`: `es_ES.UTF-8` → `es`),
else English. The same resolution the site does with a cookie and
`Accept-Language`.

**The server's words** (part of this, not optional: otherwise a Spanish
TUI shows English errors). The participant channel takes a `locale` join
param: only the code the TUI resolved (`es`, never the environment's
`es_ES.UTF-8`); the channel process sets its
Gettext locale from it (`RandosWeb.Locale`'s list; anything else is
English, silently), so `error_message` and the status reply's words arrive in the
TUI's language. Protocol change, so a mini-pass: `participant_channel.md`,
the channel and its test, the TUI, `docs/privacy.md` (the server sees
the interface language a client asks for, as it does a browser's
`Accept-Language`; it keeps nothing).

**The shootout, a second catalog.** `tools/translate` learns
`--catalog site|tui` for every command: the catalog names the template
(`priv/gettext/default.pot` or `clients/tui/priv/gettext/default.pot`),
where `fill` writes, and its own `results/<catalog>/` runs and
`state/<catalog>/` (the verdict cache stays one: it's keyed by
everything the judge saw). The checks, contestants, judges and pick rule
are the same; the glossary too ("rando"). `just translate-test` covers
both. The review page (`/dev/translations`) gets a catalog switch.

**Fitting the screen.** Translations run longer (German ~30%), CJK is
two cells a character, so: every screen in every language rendered
through the real path (`test_mode: {80, 24}`, and the small-terminal
size), failing on text cut mid-word or a key hint lost; `Tui.View`'s
hand-computed rows (`meter_rows`, `text_rows`) are what it checks. ratatui measures width with unicode-width,
so CJK lays out; what doesn't fit is the layout's to fix (wrapping),
not the translation's.

**Right-to-left.** Terminals don't agree on bidirectional text: ratatui
draws cells left to right, and whether Arabic, Persian or Urdu then
reads right depends on the terminal (iTerm2 and GNOME Terminal do some
bidi, macOS Terminal and many others don't). A decision below.

## Tests

- Unit: the language resolution (setting, env, fallback); the settings
  file round-trip; every view in every locale renders (no crash, no
  missing placeholder).
- The fit test above, per locale.
- Channel: the `locale` param sets `error_message`'s language; an
  unknown one is English.
- tui-smoke: one integration test in a non-English locale (a call
  ending with a reason shows the server's words in it).
- The existing tests stay in English (63 assertions read screen text):
  the test helper pins the locale to `en`, so a machine with
  `LANG=de_DE` runs them the same.

## Decisions (the owner, 2026-10-23)

1. **Right-to-left: test bidi properly and offer all 19.** If some
   terminals still show it wrong after testing, a warning on choosing
   one is fine. So the build starts with a bidi spike (below).
2. **Choosing:** the environment's language by default, a key on the
   idle screen, and the choice saved in the settings file.
3. **The command line's help** (`--help`, `--check`, `--version`) stays
   English.
4. (Not a question: the channel's `locale` param is part of this.)

## The bidi spike (first)

What each terminal does with right-to-left text drawn cell by cell
(ratatui writes cells left to right, in logical order): reorders it
(bidi), shapes Arabic letters (joined forms), both, or neither.
Documented behaviour of macOS Terminal, iTerm2, GNOME Terminal (VTE),
Konsole, kitty, Alacritty, WezTerm and Windows Terminal, then checked on
the ones here. The outcome picks one of: hand terminals logical text
(right where they do bidi), reorder it ourselves (right where they
don't, doubled where they do), or detect and choose, plus the warning
for the rest.
