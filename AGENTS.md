# Randos — agent guide

Randos is an anonymous, audio-only language-practice app (Phoenix LiveView +
browser WebRTC). Read `README.md` for product philosophy; the constraints there
(no accounts, no recording, no server-side audio, no persistent social graph)
are product requirements, not suggestions. Don't add features that violate them.

## Toolchain & commands

- Versions are pinned in `mise.toml` (Erlang/OTP, Elixir, just, node, OpenTofu). Run `mise install`.
- Commands live in the `Justfile`; prefer them over ad-hoc invocations:
  - `just setup` — toolchain + deps + assets
  - `just dev` — `iex -S mix phx.server` (HTTP :4000, HTTPS :4001 if `priv/cert/*.pem` exist; `just certs` makes them)
  - `just tui` — the terminal client against the local dev server (`RANDOS_URL`/`--url`
    to override); `just tui-smoke` — two real TUI clients call each other through a
    throwaway server (run after changing `clients/tui` or the channel)
  - `just top` — dev server plus a terminal dashboard (`RandosDev.Monitor`, in `dev/`):
    queues, live calls, events from telemetry; logs go to `tmp/top.log`; `q` quits
  - `just test [path]`, `just test-failed`
  - `just precommit` — **run before declaring any change done** and fix everything it reports
    (warnings-as-errors compile, unused deps, format, `credo --strict`, tests)
  - `just smoke` — browser end-to-end check (`test/e2e/call_smoke.mjs`): two
    headless Chromes with fake mics place a real WebRTC call, extend it, and
    check mic teardown. **Run it after any change to `assets/js/` or the call
    flow**; `mix test` can't see browser behavior. Needs Chrome (or `CHROME_BIN`).
  - Production check: `BASE_URL=https://randos.slowinput.org SMOKE_SKIP_EXTENSION=1 node test/e2e/call_smoke.mjs`
    (the canonical host; `randos.fly.dev` rejects browser sockets by design)
  - `RANDOS_CALL_SEGMENT_MS=8000 just dev` — dev-only short call segments for
    trying the extension flow by hand
  - `just outdated`, `just update` (also regenerates the usage-rules block below)
  - `just graft` — rebuild the graft graph after large changes
  - `just tofu <cmd>` — OpenTofu for the coturn server (`infra/coturn`). State is
    encrypted and committed; needs `TF_VAR_state_passphrase` (user's password
    manager) and `TF_VAR_do_token`. Never commit plaintext state (`just precommit` checks).
- MCP servers (`.mcp.json`): `graft` (code graph, always on) and `tidewave`
  (runtime: eval in the running app, logs, docs, SQL-free introspection).
  Tidewave only answers while `just dev` is running on :4000 — prefer it over
  `mix run` scripts for poking at live process state (Matchmaker, calls).
- Prefer plain Elixir and OTP (`GenServer`, `:gen_statem`, `Registry`, `:pg`,
  `Task`) over adding dependencies; justify any new dep. Production runs a
  single node today, but don't bake in single-node assumptions casually.
- Elixir code intelligence: the `expert-lsp` Claude Code plugin in
  `tools/claude-plugins` runs Expert (pinned in `mise.toml`). It's enabled per
  machine, not in committed settings. One-time setup from the repo root:
  `claude plugin marketplace add ./tools/claude-plugins --scope local && claude plugin install expert-lsp@randos-local --scope local`,
  then restart Claude Code. (The plugin CLI rewrites `.claude/settings.json`
  and empties graft's `footerLinksRegexes`; check `git diff` afterwards.)
- Use `Req` for HTTP. Don't add `:httpoison`, `:tesla`, or `:httpc`.

## Architecture (layer boundaries)

| Layer | Module(s) | Owns |
| --- | --- | --- |
| Call model | `Randos.Calls.Call` (struct), `Randos.Calls.Lifecycle` (pure) | Public call state; timing constants and valid status transitions |
| Matchmaking | `Randos.Matchmaking.Matchmaker` (singleton GenServer) | Live queue membership, keyed by `{speaks, listens}` |
| Calls | `Randos.Calls.CallCoordinator` (`:gen_statem`, one per call, under `Randos.Calls.CallSupervisor`) | State timeouts, extension votes, participant monitoring, signal relay |
| Signaling | `Randos.Signaling` | WebRTC signaling message shape/validation (server never touches media) |
| Participant core | `Randos.Participant` (pure) | One person's flow: find → queue → call → back. `handle(participant, event) :: {participant, [effect]}` |
| Web | `RandosWeb.HomeLive`, `RandosWeb.HomeComponents` | Shell over `Randos.Participant` (maps browser events/PubSub to participant events, runs effects); components render it |
| Channel API | `RandosWeb.ParticipantSocket`/`ParticipantChannel` (shared `RandosWeb.ParticipantShell`) | Anonymous JSON API for non-browser clients (the TUI). Protocol: `docs/architecture/participant_channel.md`; keep it in sync with the channel |
| Browser | `assets/js/randos/*`, `assets/js/hooks/*` | Mic capture, RTCPeerConnection, audio viz, timers |
| TUI client | `clients/tui` (separate Mix project: `Tui.App`, `Tui.Model`, `Tui.Connection`) | Text-only terminal client over the participant channel. **Written against `participant_channel.md` only, never the channel source**; anything it needs that the doc lacks is a doc bug. Renders server state; no state machine of its own |

- Processes notify LiveViews over `Randos.PubSub`. Topic per participant:
  `"matchmaking:participant:<id>"`.
- **No database.** All state lives in processes and vanishes on restart.
  Don't add Ecto/Postgres without asking.
- Call timing constants live in `Randos.Calls.Lifecycle` (10-min segments,
  max 2 extensions, 30-min cap, 20 s vote timeout). Reuse them; don't hardcode.
- ICE/TURN config: `RandosWeb.IceServers` (env-driven; see README "TURN And STUN").
- A participant hears about its call only from the call's coordinator:
  `{:call_updated, %Randos.Calls.Call{}}` on every status change (starting with
  `:connecting`) and `{:signaling, msg}` from the peer. `Matchmaker.join/1`
  replies `{:matched, match}` to the joiner but broadcasts nothing.
- `docs/architecture/coturn_audit.md`: TURN server findings and proposed hardening.
- `docs/architecture/refactor_plan.md` is the living roadmap (status, how the
  pieces fit, Phase 4 TUI and 5 voice anonymization, open items, decisions).
  Keep it in sync: symbols not line numbers, and update its "Verified" line.
  `docs/architecture/` has design notes (dated ones say so at the top); `docs/prompts/` is the historical
  prompt log of how features were built (context, not spec).

## Testing

- Tests mirror `lib/` under `test/`. LiveView tests use `Phoenix.LiveViewTest`
  + `LazyHTML`; assert on element IDs (`has_element?(view, "#id")`), not raw HTML
  or copy text. Always give key template elements stable DOM IDs.
- GenServer tests start isolated, named instances (see `matchmaker_test.exs`,
  `call_coordinator_test.exs`) rather than using the app-global singletons.
- A logged `matchmaking_call_start_failed ... reason=:supervisor_down` during
  `mix test` is expected (`matchmaker_test.exs` injects that failure on purpose).

## Rust (the TUI media helper, `clients/tui/native`)

- The root `Cargo.toml` is a Cargo workspace whose only member is the helper
  (so rust-analyzer and `cargo` work from the repo root; build output goes to
  `/target`, the lockfile is the root `Cargo.lock`).
- Toolchain pinned in `mise.toml` (Rust + rustfmt/clippy/rust-analyzer,
  cargo-deny). `just native-check` runs fmt, clippy with warnings as errors,
  tests, and `cargo deny check`; it is part of `just precommit`.
- **No panics in the helper.** `unwrap`/`expect`/`panic!`/`todo!` are denied by
  clippy outside tests; return errors and report them over the Port as
  messages. A panic kills the user's call.
- **stdout is the Port.** Never print to it (`print_stdout` is denied); write
  frames via `frame::write_frame`. Diagnostics go to stderr.
- **No `unsafe`** (`forbid(unsafe_code)` in Cargo.toml). If a dependency
  forces FFI, isolate it and document why in the crate README.
- **The Port protocol is a contract**, documented in
  `clients/tui/native/README.md`; change the doc, the Rust side, and the
  Elixir side together, with tests on both sides.
- **Real-time audio threads** (cpal callbacks) must not allocate, lock, or do
  I/O: hand frames off through a lock-free ring buffer.
- **Dependencies:** justify each one in the crate README (purpose, license,
  whether it pulls in C); permissive licenses only (`deny.toml`).
- Rust code intelligence: install the official plugin once per machine,
  `claude plugin install rust-analyzer-lsp@claude-plugins-official --scope local`
  (rust-analyzer comes from `mise.toml`), then restart Claude Code.

## Phoenix / frontend house rules

These are project-specific and are **not** covered by the Phoenix skill:

- LiveView templates start with `<Layouts.app flash={@flash} ...>`. `<.flash_group>`
  is only called inside `layouts.ex`.
- Use `<.icon name="hero-...">` for icons and `<.input>` for form inputs (from
  `core_components.ex`). Overriding `class` on `<.input>` drops all default classes.
- Tailwind v4, no `tailwind.config.js`. Keep the `@import "tailwindcss" source(none);`
  + `@source` lines in `assets/css/app.css`. Never use `@apply`.
- Hand-write Tailwind components; there is no component library (daisyUI was
  removed). Palette is stone (neutrals) + teal (accent) + red (errors).
- Dark mode is `data-theme="dark"` on `<html>` (default dark; toggle in
  `assets/js/app.js`). `app.css` remaps light stone/teal utilities for dark;
  for colors it doesn't remap, add an explicit `dark:` variant.
- Only `app.js` / `app.css` bundles exist. No vendored `<script src>`/`<link href>`
  in layouts, and **never** inline `<script>` in HEEx. Hooks go in
  `assets/js/hooks/` and are registered in `assets/js/app.js`. A hook that
  owns its DOM also needs `phx-update="ignore"`.
- UI should feel calm and polished: clean typography, subtle transitions and
  hover states, considered loading states.

## Skills

Framework rules are generated from dependency `usage-rules` into on-demand
skills under `.claude/skills/` (regenerate with `mix usage_rules.sync`):

- `phoenix-framework` — Phoenix, HEEx, LiveView (streams, forms, tests). Load
  before touching `lib/randos_web/` or templates.

Never edit generated content between `usage-rules-start`/`-end` markers or in
those skill directories by hand; change `usage_rules/0` in `mix.exs` instead.

<!-- usage-rules-start -->
<!-- usage_rules-start -->
## usage_rules usage
_A config-driven dev tool for Elixir projects to manage AGENTS.md files and agent skills from dependencies_

## Using Usage Rules

Many packages have usage rules, which you should *thoroughly* consult before taking any
action. These usage rules contain guidelines and rules *directly from the package authors*.
They are your best source of knowledge for making decisions.

## Modules & functions in the current app and dependencies

When looking for docs for modules & functions that are dependencies of the current project,
or for Elixir itself, use `mix usage_rules.docs`

```
# Search a whole module
mix usage_rules.docs Enum

# Search a specific function
mix usage_rules.docs Enum.zip

# Search a specific function & arity
mix usage_rules.docs Enum.zip/1
```


## Searching Documentation

You should also consult the documentation of any tools you are using, early and often. The best 
way to accomplish this is to use the `usage_rules.search_docs` mix task. Once you have
found what you are looking for, use the links in the search results to get more detail. For example:

```
# Search docs for all packages in the current application, including Elixir
mix usage_rules.search_docs Enum.zip

# Search docs for specific packages
mix usage_rules.search_docs Req.get -p req

# Search docs for multi-word queries
mix usage_rules.search_docs "making requests" -p req

# Search only in titles (useful for finding specific functions/modules)
mix usage_rules.search_docs "Enum.zip" --query-by title
```


<!-- usage_rules-end -->
<!-- usage_rules:elixir-start -->
## usage_rules:elixir usage
# Elixir Core Usage Rules

## Pattern Matching
- Use pattern matching over conditional logic when possible
- Prefer to match on function heads instead of using `if`/`else` or `case` in function bodies
- `%{}` matches ANY map, not just empty maps. Use `map_size(map) == 0` guard to check for truly empty maps

## Error Handling
- Use `{:ok, result}` and `{:error, reason}` tuples for operations that can fail
- Avoid raising exceptions for control flow
- Use `with` for chaining operations that return `{:ok, _}` or `{:error, _}`

## Common Mistakes to Avoid
- Elixir has no `return` statement, nor early returns. The last expression in a block is always returned.
- Don't use `Enum` functions on large collections when `Stream` is more appropriate
- Avoid nested `case` statements - refactor to a single `case`, `with` or separate functions
- Don't use `String.to_atom/1` on user input (memory leak risk)
- Lists and enumerables cannot be indexed with brackets. Use pattern matching or `Enum` functions
- Prefer `Enum` functions like `Enum.reduce` over recursion
- When recursion is necessary, prefer to use pattern matching in function heads for base case detection
- Using the process dictionary is typically a sign of unidiomatic code
- Only use macros if explicitly requested
- There are many useful standard library functions, prefer to use them where possible

## Function Design
- Use guard clauses: `when is_binary(name) and byte_size(name) > 0`
- Prefer multiple function clauses over complex conditional logic
- Name functions descriptively: `calculate_total_price/2` not `calc/2`
- Predicate function names should not start with `is` and should end in a question mark.
- Names like `is_thing` should be reserved for guards

## Data Structures
- Use structs over maps when the shape is known: `defstruct [:name, :age]`
- Prefer keyword lists for options: `[timeout: 5000, retries: 3]`
- Use maps for dynamic key-value data
- Prefer to prepend to lists `[new | list]` not `list ++ [new]`

## Mix Tasks

- Use `mix help` to list available mix tasks
- Use `mix help task_name` to get docs for an individual task
- Read the docs and options fully before using tasks

## Testing
- Run tests in a specific file with `mix test test/my_test.exs` and a specific test with the line number `mix test path/to/test.exs:123`
- Limit the number of failed tests with `mix test --max-failures n`
- Use `@tag` to tag specific tests, and `mix test --only tag` to run only those tests
- Use `assert_raise` for testing expected exceptions: `assert_raise ArgumentError, fn -> invalid_function() end`
- Use `mix help test` to for full documentation on running tests

## Debugging

- Use `dbg/1` to print values while debugging. This will display the formatted value and other relevant information in the console.

<!-- usage_rules:elixir-end -->
<!-- usage_rules:otp-start -->
## usage_rules:otp usage
# OTP Usage Rules

## GenServer Best Practices
- Keep state simple and serializable
- Handle all expected messages explicitly
- Use `handle_continue/2` for post-init work
- Implement proper cleanup in `terminate/2` when necessary

## Process Communication
- Use `GenServer.call/3` for synchronous requests expecting replies
- Use `GenServer.cast/2` for fire-and-forget messages.
- When in doubt, use `call` over `cast`, to ensure back-pressure
- Set appropriate timeouts for `call/3` operations

## Fault Tolerance
- Set up processes such that they can handle crashing and being restarted by supervisors
- Use `:max_restarts` and `:max_seconds` to prevent restart loops

## Task and Async
- Use `Task.Supervisor` for better fault tolerance
- Handle task failures with `Task.yield/2` or `Task.shutdown/2`
- Set appropriate task timeouts
- Use `Task.async_stream/3` for concurrent enumeration with back-pressure

<!-- usage_rules:otp-end -->
<!-- usage-rules-end -->

<!-- graft:start -->
## Graft — repo context graph

This repo is indexed in `graft/`: small linked markdown nodes that explain each
system and carry exact file:line spans, kept in sync with the code through git.

For ANY task here — understanding how something works, finding where code lives,
or scoping a change — get context from the graph before grepping or opening
source files. Re-ask freely (it's cheap) and reuse literal identifiers you
already have (symbol, error string, file name) as the query. New to this repo?
Run `graft map` first — a token-budgeted orientation (dir clusters, hubs,
hotspots), no LLM, no key.

- Run `graft ask "<your question>" --source` → ranked nodes with the relevant
  code spans inlined (each hit's ≤8-line crux by default; `--full` for whole
  definitions when the crux isn't enough). Match the tool to the task shape:
  for understanding or editing, the top node IS the answer — cite its
  `covers:` file:line spans and edit straight from `--source`. For
  exhaustive tasks ("every occurrence / every caller of this pattern"), ranked
  results are top-N, not complete — run `graft grep "<literal>"` instead
  (exhaustive over indexed files, grouped by enclosing symbol), falling back
  to raw `grep -rn` only for unindexed files.
- `graft skeleton <file>` → every definition's signature + span, ~10× cheaper
  than reading the file; use it to skim an API surface.
- `graft callers <symbol>` gives precomputed, exact edges — who calls this.
  Add `--direction out` for what it calls, or `--depth N` to walk
  transitively for the full blast radius. For structural questions, skip
  ranking and use this directly.
- Or browse: `graft/INDEX.md` lists every node; follow the links.
- Monorepos and folders of multiple repos rank fairly across sub-projects —
  hits carry `[scope/]` labels naming which one they're from. Narrow with
  `graft ask "<task>" --in <scope>/` once you know where you're working.

If a returned span is truncated ("+N more lines"), open the file at that exact
range before finalizing. Only open source files when a node genuinely lacks a
needed detail, and then at the exact file:line the node points to — never
re-read whole files.

After big code changes, refresh the graph with `graft build` (deterministic,
no API key, $0).
<!-- graft:end -->
