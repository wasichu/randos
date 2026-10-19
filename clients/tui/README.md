# Randos terminal client (text-only)

A terminal client for [Randos](../../README.md): choose languages, get matched,
see the call timer, vote on extensions, hang up or go next. **No audio yet**
(roadmap Phase 4.3), so a browser peer's call ends immediately with
`audio_unsupported`; two terminal clients can hold a call.

```bash
just tui                      # from the repo root: local dev server (just dev)
cd clients/tui && mix tui --url ws://localhost:4000/participant/websocket
```

Keys are shown at the bottom of the screen; `q` quits. Logs go to `tmp/tui.log`.

It speaks the public participant channel protocol,
[`docs/architecture/participant_channel.md`](../../docs/architecture/participant_channel.md),
and is written against that document only.

- `Tui.Model` — pure view model: folds server messages and keys into what's
  shown, returns channel pushes as commands
- `Tui.Connection` — Slipstream client for the channel
- `Tui.App` — the ex_ratatui app

Tests: `mix test` (unit, app under ex_ratatui's test mode, connection against
`Slipstream.SocketTest`); `just tui-smoke` from the repo root for two real
clients against a server.
