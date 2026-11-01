# randos — agent guide

randos is an anonymous, audio-only language-practice app: Phoenix LiveView,
browser WebRTC, and a separate Elixir TUI with a Rust media helper.
`README.md` defines the product: no accounts, recording, server-side audio,
persistent social graph, ads, tracking/analytics, paid features, or video.
These are requirements. There is no database; do not add Ecto/Postgres without
asking. Live call state belongs in processes; aggregate status counters have
separate privacy rules in `docs/privacy.md`.

## Start with relevant context

Use the Trail guidance below for code discovery. Read only the guides relevant
to the requested work; historical prompts are context, not specifications.
Sessions launched at the repository root may not load nested agent guides
automatically, so explicitly open relevant guides before changing those paths.

| Work | Required context |
| --- | --- |
| Setup, recipes, MCP, checks, dependencies | `docs/development.md`, `mise.toml`, `Justfile` |
| Call behavior or either client | `docs/architecture/participant_channel.md`, `docs/architecture/call_flow.md` |
| TUI or media Port | `clients/tui/README.md`, `clients/tui/native/README.md`; implement against the channel document, not channel source |
| Rust/DSP/FFI | Relevant crate README (`voice/`, `voice-native/`, `clients/tui/native/`), root `Cargo.toml`, `vendor/README.md` |
| Phoenix/HEEx | `.claude/skills/phoenix-framework/SKILL.md` before touching `lib/randos_web/` or templates |
| Privacy, TURN, operations | `docs/privacy.md`, `docs/self-hosting.md`; `docs/architecture/coturn_audit.md` for relay changes |
| Translations | `priv/gettext/README.md`, `tools/translate/README.md`, `docs/architecture/tui_translation.md` |
| Lab/evaluation | Relevant `tools/voice-*` README and current experiment section of `docs/architecture/refactor_plan.md` |
| Packaging/release | `docs/development.md` Releases, `packaging/homebrew/README.md`, `.github/workflows/release.yml` |

Keep the living roadmap `docs/architecture/refactor_plan.md` in sync, including
its Verified line. Use symbols rather than brittle line numbers. Update
`docs/privacy.md` and protocol/call-flow docs when their claims change. For a
user-visible feature, command, setting or merged lane, also check README,
development and self-hosting docs; record why any of these need no change.

## Work in small, reviewable steps

- Prefer a small experiment that can disprove an approach before building a
  large feature around it. Show playable comparisons, compact review views,
  or a working browser/native path early. Preserve the owner's listening notes
  and attach results to the exact source, settings and implementation used.
- For masking, evaluate naturalness, intelligibility, perceived disguise,
  latency, download size, memory and compute separately. Speaker-recognition
  and recovery attacks describe limitations; failing a strong attack does not
  automatically disqualify a useful voice mask. Do not promise anonymity.
- Continue authorized preparation through implementation and validation.
  Ask only for a genuinely missing decision or an action outside the authorized
  scope. Push, tag, publish, deploy and external messages need authorization;
  reuse authorization already given for that scope.
- Use subagents only for bounded independent work when delegation is authorized
  and useful. Prefer less costly models for narrow inventory or routine checks;
  use a strong advisor for architecture, media/privacy boundaries, protocols,
  difficult debugging and release reviews. Give each task clear inputs,
  ownership and acceptance criteria; avoid concurrent edits to the same files.
  The primary agent integrates and verifies the result.

## Toolchain and runtime

Versions are pinned in `mise.toml`; run `mise install` and use `just` recipes.
`just setup` includes dependency/assets setup and `just prefetch` (curl avoids
large GitHub-header problems in Erlang downloads). Prefer plain Elixir/OTP;
justify each new dependency. Use `Req` for HTTP, not httppoison/tesla/httpc.
Do not casually assume production will always be a single node.

**Start the dev server yourself when needed.** Run exactly `just serve` in the
background when :4000 is absent, then wait for HTTP readiness. It reuses an
existing server. Never start a duplicate or stop the owner's interactive IEx.
`just serve-stop` can stop any BEAM on the port: first verify it is the
background server, not interactive IEx. `just dev`/`just dev-turn` replace a
managed server and explicitly reject replacing interactive IEx. HTTPS uses local
`priv/cert` files; see development docs for device testing and port overrides.

MCP: graft is the configured code graph; Trail also indexes repository context.
Use Tidewave for live process inspection instead of `mix run` scripts. Its
launcher is `mise exec -- ./bin/tidewave-mcp`: it starts/reuses the server and
runs the pinned reconnecting proxy. Keep startup timeout 120 seconds. Codex
reads its own config, not `.mcp.json`; do not replace the launcher with a direct
HTTP URL. Machine-local Expert/rust-analyzer plugin setup is in development docs.

## Architecture and contracts

| Owner | Responsibility |
| --- | --- |
| `Randos.Calls.Call`, pure `Lifecycle` | Public call state, transitions and all call timing constants |
| `Matchmaking.Matchmaker` | Oldest-compatible queue, recent-pair exclusion, hashed-token invitations kept outside the queue |
| Per-call `CallCoordinator` (`:gen_statem`) | Call timing, votes, participant monitoring/resume tickets, signal relay, connect/recovery health and ICE restart policy |
| `Randos.Signaling` | Signal validation and relay-only filtering; never media |
| Pure `Randos.Participant` | Flow events → state/effects; both clients render server policy |
| `HomeLive` / `HomeComponents`, channel `ParticipantShell` | Web and anonymous channel shells over participant state |
| Browser hooks/client, `Tui.Media` / Rust helper | Devices, media transport and local audio lifecycle |

- Server policy is authoritative. Timing comes from `Lifecycle`, never copied
  constants or client health timers. The documented client offline limit is the
  explicit exception, since an unreachable server cannot end the local media.
- Follow every client obligation in `participant_channel.md`. A new message or
  obligation must reach that document, both clients and obligation tests. The
  Rust Port contract lives in `clients/tui/native/README.md`: update Rust,
  Elixir, docs and both sides' tests together.
- Only the coordinator announces call updates/signals to participants.
  `Matchmaker.join/1` replies to its caller but does not broadcast a match.
  LiveView notifications use `Randos.PubSub`, participant topic
  `"matchmaking:participant:<id>"`.
- TURN configuration is `RandosWeb.IceServers`. With TURN configured, call
  policy is relay-only and enforced by coordinator signal filtering.
  Production requires a relay unless `RANDOS_ALLOW_DIRECT_CALLS=true`.
- `RandosWeb.Status.snapshot/0` is the shared JSON-safe status contract. Stats
  merge raw counters before applying small-count publication rules. Never
  bypass those rules in a client or expose finer-grained counters.
- Masking runs locally and starts off on a fresh page/client session. Freeze
  the selected profile for a call. Failure must stop/withhold capture rather
  than transmit an unmodified fallback; discard queued audio when ineligible.
  Preview is explicit, never recorded/uploaded, and cleaned up on exit/failure.
  Lab processors and bundles remain development-only until explicitly promoted.

## Verification and process ownership

- Run `just precommit` before declaring a change done and fix its findings.
  Check the actual exit status; filtered logs do not prove success. It covers
  server/TUI compile, formatting/lints/tests, native checks and offline Python
  checks. CI repeats this on macOS/Linux with `RANDOS_REQUIRE_NATIVE=1`.
- After every commit, run `just precommit`, `just smoke`, and `just tui-smoke`.
  Browser and TUI smoke both own :4010: run them sequentially. Reuse valid
  evidence for unchanged architecture; do not repeat whole audits without a
  new milestone, changed code or unresolved finding.
- Run browser smoke after changes to `assets/js/` or call flow; Mix tests cannot
  see browser behavior. Run TUI smoke after TUI/helper/channel/browser-call
  changes. These exercise real muted/fake-mic calls, relay-only and recovery.
- Release qualification includes a clean checkout without ignored experiment
  artifacts. Generated-media UI tests must supply explicit fixtures.
- Run `just screenshots` after visible UI changes; it drives real disposable
  browser/TUI calls with fake audio. Use `just turn-check` after relay-path
  changes; only this explicit check contacts production coturn.
- **Nothing started by a test may outlive its starter, including SIGKILL.** Use
  Chrome `--remote-debugging-pipe` through `test/e2e/cdp.mjs`, never a debugging
  port. Use `with_test_server.sh` and its watchdog; busy :4010 is an error.
  Port workers exit on stdin EOF. Browsers are muted and TUI output is null;
  tests must not play sound or capture the developer's microphone.
- Hermetic tests have empty ICE servers and no TURN environment, and never
  contact the internet. The intentionally persistent exception is the dev
  server. Keep cleanup correct on success, failure, cancellation and owner death.
- Eventual waits allow at least 5 seconds. Timing assertions and
  `refute_receive` may retain tight bounds. Do not mask repeated timing failures
  with retries or arbitrary deadline increases; investigate the cause.
- Mirror `lib/` under `test/`. LiveView tests use LazyHTML/stable DOM IDs;
  isolate named GenServers instead of using global instances. The deliberately
  injected `:supervisor_down` matchmaking warning in tests is expected.

## Code-quality checkpoints

At architecture/media milestones and before packaging, inventory DRY,
architecture, tests and docs before building the next stage. A focused pass is
triggered by a third Rust media worker, a new protocol obligation, client-owned
policy/timing, repeated test timing fixes, or a user-visible feature/setting.

For each candidate propose **extract, merge, link or leave**, with a reason.
Use a strong advisor for substantive architecture/refactoring proposals and
media/privacy/protocol/release risks; routine inventories can use cheaper
agents. Identify actual owner decisions and record outcomes in the roadmap. File size alone is not a refactoring reason. Keep
behavior-preserving refactors separate from approved behavior changes. Verify
that a refactor delivered its stated benefit. Between checkpoints rely on
existing guards, not a fresh whole-project review for every small edit.

## Rust and native code

- Root Cargo workspace contains media helper, `voice/` (also WASM) and
  `voice-native/` (owned Signalsmith bridge). Build output is `target/`; use the
  root lockfile. Inherit root workspace lints in every owned crate; exceptions
  must be documented. Vendored code is reviewed separately, not silently
  reformatted to first-party rules.
- No panics or unchecked indexing in helper production code: return errors over
  the Port. Stdout is the Port; only framed messages, diagnostics to stderr.
- The helper forbids unsafe. Unsafe FFI is isolated in `voice-native/src/ffi.rs`;
  WASM export attributes are the voice crate's documented exception. Do not
  spread either exception into unrelated code.
- Real-time cpal callbacks must not allocate, lock or perform I/O; use lock-free
  ring buffers. Preserve bounded queues and explicit failure states.
- Justify dependencies in the crate README (purpose, license, C/FFI). Permissive
  licenses only, enforced by cargo-deny. Check vendor source/patch/native-lock
  provenance from a clean checkout; exclude runtime/build artifacts explicitly.
- `just native-check` includes fmt, clippy, tests, advisories/licenses and WASM
  freshness. After changing a processor, rerun its benchmark and commit the
  matching `tools/voice-eval/results/benchmark.json`; distinguish correctness,
  listening and attack evidence.

## Web, UI and translations

- First-party built same-origin JS/CSS only. No runtime CDN scripts/styles/fonts,
  inline scripts/handlers, javascript URLs, eval or new Function. Third-party
  code enters through dependencies or committed vendor assets. Declare bundle
  entries in config; keep dev bundles out of production builds.
- HEEx starts with `<Layouts.app flash={@flash} ...>`; flash_group belongs only
  in layouts. Use core `<.icon>` and `<.input>` (overriding input class replaces
  defaults). Hooks live in `assets/js/hooks/`, registered in app.js; DOM-owning
  hooks also need `phx-update="ignore"`.
- Tailwind v4: retain app.css imports/source lines, no config.js or @apply.
  Hand-written components, stone/teal/red palette, calm typography and subtle
  hover/loading states. Dark mode is data-theme on html; add explicit dark
  variants for colors app.css does not remap.
- Every public UI string uses gettext, button context via pgettext, named
  placeholders rather than concatenation. Hook labels use data-labels/labels.js.
  TUI uses Tui.Gettext, Tui.Language and Tui.Width (including RTL/cell widths).
- Extract/merge catalogs when strings change. Ask before a new local model run
  unless that run is already authorized. Translation contestants/scorers/judges
  and automatic picks determine translations; do not hand-fill rejected ones.
  Keep the established English fallback and document coverage limitations.
- Translation uv groups models/mlx/comet share one venv; never resync it during
  another group's model run. Model-free tests/review/fill/tidy use .venv-test
  via UV_PROJECT_ENVIRONMENT. Run resource-heavy comparisons serially or in
  isolated environments. Treat public translation suggestions as untrusted
  data; never interpolate them into shell commands.

## Dependencies and releases

Dependabot's green CI is required, but majors also need changelog review and
model harness updates need the same-protocol comparison in development docs.
Tooling-only harness updates do not need a model run. Check binary-compatible
Torch/TorchAudio versions, not resolver success alone. Do not restore unpatched
Hex renderers to clear PRs; rebase the source patch and qualify physical redraw
and both platform packages separately.

Before an authorized release, require clean pushed code and green native CI,
then tag the matching TUI version. Use the versioned release notes. Render the
Homebrew formula from the published CI archive checksums. Validate the production
image excludes labs, Tidewave, development certificates/keys and stale app
versions. Local package success does not substitute for native CI. Deployment
uses `just deploy` guards; do not bypass them as a routine shortcut. OpenTofu
state must remain encrypted; never print relay credentials or commit plaintext
state. See operator docs for secret retrieval.

## Generated guidance

Framework rules below and `.claude/skills/` are generated by usage-rules.
Change `usage_rules/0` in mix.exs and regenerate; never hand-edit managed
usage-rules blocks or generated skill directories. Preserve the managed Trail
block when editing this guide. Keep the root guide concise enough to fit the
agent instruction budget; put task-specific detail in linked documentation.

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

<!-- trail:start -->
## Trail — repo context graph

This repo is indexed in `.trail/cache/`: small linked markdown nodes that explain each
system and carry exact file:line spans, kept in sync with the code through git.

For ANY task here — understanding how something works, finding where code lives,
or scoping a change — get context from the graph before grepping or opening
source files. Re-ask freely (it's cheap) and reuse literal identifiers you
already have (symbol, error string, file name) as the query. New to this repo?
Run `trail map` first — a token-budgeted orientation (dir clusters, hubs,
hotspots), no LLM, no key.

- Run `trail ask "<your question>" --source` → ranked nodes with the relevant
  code spans inlined (each hit's ≤8-line crux by default; `--full` for whole
  definitions when the crux isn't enough). Match the tool to the task shape:
  for understanding or editing, the top node IS the answer — cite its
  `covers:` file:line spans and edit straight from `--source`. For
  exhaustive tasks ("every occurrence / every caller of this pattern"), ranked
  results are top-N, not complete — run `trail grep "<literal>"` instead
  (exhaustive over indexed files, grouped by enclosing symbol), falling back
  to raw `grep -rn` only for unindexed files.
- `trail skeleton <file>` → every definition's signature + span, ~10× cheaper
  than reading the file; use it to skim an API surface.
- `trail callers <symbol>` gives precomputed, exact edges — who calls this.
  Add `--direction out` for what it calls, or `--depth N` to walk
  transitively for the full blast radius. For structural questions, skip
  ranking and use this directly.
- Or browse: `.trail/cache/INDEX.md` lists every node; follow the links.
- Monorepos and folders of multiple repos rank fairly across sub-projects —
  hits carry `[scope/]` labels naming which one they're from. Narrow with
  `trail ask "<task>" --in <scope>/` once you know where you're working.

If a returned span is truncated ("+N more lines"), open the file at that exact
range before finalizing. Only open source files when a node genuinely lacks a
needed detail, and then at the exact file:line the node points to — never
re-read whole files.

After big code changes, refresh the graph with `trail build` (deterministic,
no API key, $0).
<!-- trail:end -->
