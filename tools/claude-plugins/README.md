# Project-local Claude Code plugins

`randos-local` marketplace with one plugin:

- **expert-lsp** — Elixir code intelligence (diagnostics after edits, symbol
  navigation) via [Expert](https://expert-lsp.org), the official Elixir
  language server. The `expert` binary is pinned in the repo's `mise.toml`.

Enable per machine (local scope, so no machine-specific path is committed):

```bash
claude plugin marketplace add ./tools/claude-plugins --scope local
claude plugin install expert-lsp@randos-local --scope local
```

Restart Claude Code, then check `/plugin` (no errors for `expert-lsp`).
The plugin CLI rewrites `.claude/settings.json` and empties graft's
`footerLinksRegexes`; restore it if `git diff` shows that.
