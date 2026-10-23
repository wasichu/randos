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

**Right-to-left.** Researched 2026-10-23 (the spike below has the table):
terminals split. macOS Terminal, iTerm2 3.7+, GNOME Terminal (VTE),
Konsole, mintty and mlterm run the bidi algorithm on what an app writes
and join Arabic letters; Ghostty, Alacritty, Windows Terminal, WezTerm
(by default), VS Code's terminal and VHS (our screenshots) do neither;
kitty joins letters but keeps words in logical order. Reordering in the
app would reverse twice in Terminal.app and Konsole, which can't be told
not to. So the TUI writes logical order (as ratatui does), and:

- **keeps right-to-left text from spilling across a row**: a reordering
  terminal treats the whole row as one paragraph, so Arabic in two
  side-by-side panels could swap them (Helix has this bug). In a
  right-to-left interface the You and Devices panels stack (as on a
  narrow terminal), so every row is one panel between its own borders,
  which the bidi algorithm keeps in place. (A left-to-right mark would
  have done it too, but ratatui drops zero-width characters, so it never
  reaches the terminal.)
- **warns where it can't read right**: choosing Arabic, Persian or Urdu
  in a terminal known not to reorder (`TERM_PROGRAM` ghostty, vscode,
  WezTerm; `ALACRITTY_*`, `WT_SESSION`) says so on screen, and inside
  tmux (which hides the terminal) the note names the terminals that work.

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

## The bidi spike (done 2026-10-23)

| Terminal | Reorders (bidi) | Joins Arabic letters | Can be told "already reordered" |
| --- | --- | --- | --- |
| macOS Terminal | yes, by default | yes | unknown |
| iTerm2 | since 3.7.0 by default (3.6 opt-in) | yes | 3.7.5+ (`CSI 8 l`) |
| GNOME Terminal (VTE ≥ 0.58) | yes, by default | yes (even when told) | yes |
| Konsole | yes, by default | yes | no |
| kitty | no (letters within a word only) | yes | no |
| Ghostty | no | no | no |
| Alacritty | no | no | no |
| Windows Terminal | no | no | no |
| WezTerm | off by default | unknown | yes |
| xterm.js (VS Code, VHS) | no (its DOM renderer by accident) | no | no |

Sources: the terminal-wg BiDi pages, each terminal's changelog, source
and issues (iTerm2 #13102, VTE `src/bidi.cc`, Konsole `TerminalDisplay`,
kitty #2109, Ghostty `harfbuzz.zig`, Alacritty #663, Windows Terminal
#538, WezTerm #784, xterm.js #701), and Claude Code's own issue #34134
(it reordered itself and came out reversed in Terminal.app). Still to
check by eye, with Arabic in the TUI: Terminal.app (a reordering one)
and Ghostty (a plain one).

Checked by eye 2026-10-23 (window screenshots, the TUI in Arabic):
both read right to left. Terminal.app reorders the logical text itself;
Ghostty gets it reordered by `Tui.Bidi` and joins the letters (the
research said it didn't). One fix came of it: the `←→` key is only
arrows, neutral in bidi, so between two Arabic words Terminal.app paired
it with the wrong action; in a right-to-left interface that hint now
comes first, held by the line's start. Left as the terminals draw it:
the cell grid spaces Arabic letters out, and a lam-alef ligature (لا)
leaves a gap where its second cell was.
