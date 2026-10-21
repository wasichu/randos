# randos terminal client

A terminal client for [randos](../../README.md): choose languages, get
matched, and talk, with audio through the Rust media helper
(`native/`, run as a Port): echo cancellation (headphones recommended, not
required), mute (`m`), mic and speaker choice (`i` / `o` on the idle
screen), live audio meters, and STUN/TURN (UDP, or TLS when UDP is
blocked), so it works across networks and with browser users. Without the
helper it's text-only and meets only other text-only clients.

```bash
just tui                      # from the repo root: the local dev server (just dev)
cd clients/tui && mix tui --url wss://randos.slowinput.org/participant/websocket
mix tui --check               # is the audio helper there and working?
```

Keys are shown at the bottom of the screen; `q` quits. On the idle screen,
`s` shows the server's status (the same as the website's `/status` page:
whether the relay works, and today's call counts); `s` or Esc goes back.
`RANDOS_FAKE_AUDIO=1` swaps the mic for a test tone and the speaker for
nothing (for screenshots and demos, `just screenshots`; your rando would
hear a beep). Logs go to
`tmp/tui.log` (an installed copy: `~/.cache/randos/tui.log` on Linux,
`~/Library/Caches/randos/tui.log` on macOS).

On the start screen, ←→ picks the language you'll speak; on the "I'm happy
to hear" row, ←→ moves through the languages and space checks or unchecks
one (pick as many as you like; your speaking language starts checked).

Your choices are kept for next time in a small settings file on your own
computer (nothing about it goes to the server): the languages, that you
confirmed the 18+ notice, and the mic and speaker (`i`/`o`). It's
`tmp/tui-config.json` for `mix tui`, and in an installed copy
`~/.config/randos/config.json` on Linux or
`~/Library/Application Support/randos/config.json` on macOS (the idle
screen shows where). To manage it:

```bash
randos --settings         # where it is, and what's in it
randos --edit-settings    # open it in $VISUAL / $EDITOR (vi if neither is set)
randos --reset-settings   # forget it; the next start begins fresh
```

## Installable builds

`just tui-release` (repo root) builds `dist/randos-VERSION-OS-ARCH.tar.gz`:
a `mix release` directory with ERTS, the app, the media helper (in the
app's `priv/`), and `bin/randos`, the command people run (`Tui.CLI`: `--url`,
`--check`, `--version`, `--help`). Unpacked anywhere it runs as is, and
it defaults to production (`config/config.exs`; `mix tui` defaults to the
local dev server). A release named `randos` would own `bin/randos` itself,
so the release is `randos_tui` and `bin/randos` is a small wrapper that
follows symlinks (Homebrew links it into place). Pushing a `v*` tag builds
the macOS arm64 and Linux x86_64 archives in CI and attaches them to a
GitHub release (`.github/workflows/release.yml`).

It speaks the public participant channel protocol,
[`docs/architecture/participant_channel.md`](../../docs/architecture/participant_channel.md),
and is written against that document only.

- `Tui.Model` — pure view model: folds server messages and keys into what's
  shown, returns channel pushes as commands
- `Tui.Connection` — Slipstream client for the channel
- `Tui.App` — the ex_ratatui app (callbacks and state); `Tui.View` — its
  screens, pure functions of that state
- `Tui.Media` — owns the media helper's Port; `Tui.Media.State` — local
  audio state (mic test, call audio, devices), pure
- `Tui.CLI` — the `randos` command (`mix tui` and `bin/randos`)

Tests: `mix test` (unit, app under ex_ratatui's test mode, connection against
`Slipstream.SocketTest`); `just tui-smoke` from the repo root for two real
clients against a server.
