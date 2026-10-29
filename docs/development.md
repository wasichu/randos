# Developing randos

How to set up, run, and test randos locally, and where things are. For
running a public instance, see [self-hosting](self-hosting.md). Coding
agents (and people who like rules written down) should also read
[`AGENTS.md`](../AGENTS.md): its constraints apply to everyone.

## What's here

| Part | Where | What it is |
| --- | --- | --- |
| Server and website | `lib/`, `assets/` | Phoenix LiveView: matchmaking, one process per call, WebRTC signaling. The browser does the audio. |
| Terminal client | `clients/tui/` | A separate Mix project on [ex_ratatui](https://hex.pm/packages/ex_ratatui), talking to the server over the [participant channel](architecture/participant_channel.md) |
| Media helper | `clients/tui/native/` | Rust (str0m WebRTC, Opus, cpal), run by the terminal client as a Port: [its README](../clients/tui/native/README.md) |
| Voice processors | `voice/` | Rust (`randos_voice`), written once: native in the helper, WASM in the browser (`just voice-wasm` rebuilds the committed `.wasm`) |
| Translation shootout | `tools/translate/` | Python (uv): machine-translates the UI's gettext strings and scores the models |
| Voice benchmark | `tools/voice-eval/` | Python (uv): can a speaker model still identify a voice after a processor? |
| TURN server | `infra/coturn/` | coturn as code (OpenTofu + cloud-init): [its README](../infra/coturn/README.md) |
| Design notes | `docs/architecture/` | The [roadmap](architecture/refactor_plan.md), the [call flow](architecture/call_flow.md), the channel protocol, and more |

There is no database: the matchmaking queue and each call's coordinator are
processes, and everything vanishes on restart.

## Setup

Toolchain versions (Erlang/OTP, Elixir, Node, Rust, just, OpenTofu, mkcert,
and a few more) are pinned in `mise.toml`, and the commands live in the
`Justfile` (`just --list` shows them all).

```bash
mise install
just setup        # toolchain, deps, assets
just dev          # http://localhost:4000 (with IEx)
```

`just serve` runs the same server without IEx, in the background
(`just serve-stop` stops it).

### Tidewave MCP startup

`.mcp.json` starts Tidewave with `mise exec -- ./bin/tidewave-mcp`. The
launcher starts or reuses `just serve`, writing server output to
`tmp/serve.log`, then runs the pinned `mcp-proxy`. The proxy retries while
Phoenix boots and reconnects if it restarts. The dev server intentionally
stays running after the MCP client exits; `just serve-stop` stops it.

Codex uses its own MCP configuration rather than `.mcp.json`. Register the
same launcher, using absolute paths for your machine (especially when
starting the desktop app without a shell):

```bash
codex mcp add tidewave -- /absolute/path/to/mise -C /absolute/path/to/randos exec -- ./bin/tidewave-mcp
```

Set `startup_timeout_sec = 120` under `[mcp_servers.tidewave]` in Codex's
`config.toml`, and reload the MCP connection after configuration changes.
A direct HTTP registration can fail when the app starts before Phoenix;
the launcher and proxy avoid that ordering dependency.

### HTTPS, for the mic on other devices

Browsers allow the microphone only on `localhost` or over HTTPS. To try
randos from a phone or another computer on your network:

```bash
just certs        # local certificates with mkcert (priv/cert/)
just dev          # also https://<your machine's name or LAN IP>:4001
```

Other devices click through a certificate warning (or trust mkcert's CA).
`HTTPS_PORT`, `DEV_SSL_CERTFILE`, and `DEV_SSL_KEYFILE` override the defaults.

### TURN in development

Without TURN settings, the dev server hands out Google's public STUN
server, which is enough on one network. To use the real coturn relay (the
owner's setup: the secret comes from the encrypted OpenTofu state and is
never printed):

```bash
just dev-turn
```

`RANDOS_CALL_SEGMENT_MS=8000 just dev` makes calls 8 seconds long, for
trying the continue-the-call vote by hand.

## The terminal client

```bash
cargo build -p randos_media     # the media helper (once, and after Rust changes)
just tui                        # against the local dev server
just tui --url wss://randos.slowinput.org/participant/websocket
```

Without the helper, the client runs text-only and is matched only with
other text-only clients. More in [its README](../clients/tui/README.md).

## Tests and checks

| Command | What it checks |
| --- | --- |
| `just test [path]` | The server's tests (`just test-tui` for the terminal client's) |
| `just precommit` | Everything CI checks per platform: compile with warnings as errors, format, Credo, both test suites, the Rust crates (fmt, clippy, tests, cargo-deny), and the Python harnesses' offline tests (`tools/translate`, `tools/voice-eval`; no models). **Run it before calling a change done**, and check its exit status. |
| `just smoke` | Two headless Chromes with fake mics place a real call (`mix test` can't see the browser). Run after changing `assets/js/` or the call flow. Includes `just recovery-smoke`: a relay-only call through the test TURN relay (`just test-turn`) has its media cut, alone and with a websocket drop, and must come back by ICE restart. |
| `just tui-smoke` | Real terminal clients call each other and headless Chrome, with audio checked both ways, including recovery: relay-only through the test TURN relay, every path cut, and the call back on ICE restart (TUI ↔ TUI, and TUI ↔ browser in both roles; those tests start their own relay and server). Run after changing the terminal client, the helper, or the channel. |
| `just check-privacy` | That the coturn settings [privacy.md](privacy.md) promises are still in its config (part of precommit). |
| `just turn-check` | The helper against the real coturn, over UDP and TLS (owner only: needs the TURN secret). Run after changing the relay path. |

CI (`.github/workflows/ci.yml`) runs `just precommit` on macOS and Linux,
plus both smoke tests. The tests never play sound and never reach the
internet; the smoke tests start their own throwaway server on :4010.

`just setup` runs `just prefetch` (`bin/prefetch.sh`) between fetching
dependencies and compiling: it fetches with curl the prebuilt files a
build would otherwise download from GitHub releases with Erlang's :httpc,
which GitHub's large response headers now break (ex_ratatui's and
lazy_html's NIFs, the Tailwind binary). CI and the Dockerfile run it too.

### Translation fixes

A "Suggest a fix" issue becomes a pull request on its own
(`translation-fix.yml`). GitHub doesn't run CI on a pull request a
workflow opened with its own token, so the fix PR shows no checks until
someone closes and reopens it (that starts CI); then review and merge as
usual.

### Dependency updates

Dependabot (`.github/dependabot.yml`) opens grouped PRs: weekly for Mix,
Cargo and GitHub Actions, monthly for the two Python harnesses; a Monday
workflow (`dependency-check.yml`) runs `cargo deny check advisories` and
`mix hex.audit`. The rule for merging:

- **CI green, and no `major` or `gpu-check` label: merge.** A Python
  harness's `-tooling` PR (pytest, Ruff, setuptools) counts as this,
  though it carries `gpu-check` (labels are per directory).
- **`major`** (a dependency up a major version; these come in PRs of their
  own, `<group>-major`, labelled by `dependabot-labels.yml`): read the
  changelog for breaking changes first. Majors are worth taking, not
  ignoring; they just get that care.
- **`gpu-check` (a harness's `-models` group): compare before merging**,
  in a git worktree on the PR's branch (its own `.venv`; never the main
  tree's, and never while a model runs). For `tools/translate`: run each
  model the PR touches on a few strings (`cli run --model <m> --locales
  es --limit 5`) and diff the texts against the stored shootout entries
  (greedy decoding should match exactly), and rescore a copy of a stored
  run with MetricX and COMET-Kiwi (within about 0.01 of the stored
  scores). For `tools/voice-eval`, run a selected setting with
  `just voice-eval --only passthrough --output results/dependency-check.json`
  and compare it with `results/benchmark.json` (same corpus and protocol).
  A difference
  doesn't block merging by itself: it means the next run may pick
  differently, which is worth knowing first.

Check [TorchAudio's binary compatibility requirements](https://docs.pytorch.org/audio/stable/installation.html)
alongside the lockfile. Resolution and offline tests can pass while its native
extension cannot load against the selected Torch version; the model comparison
must actually import and run the updated libraries.

## More tools

- `just top`: the dev server plus a terminal dashboard of queues, calls, and
  events.
- Dev-only pages on `just dev` (never in production):
  [`/dev/voice-lab`](http://localhost:4000/dev/voice-lab), to hear and
  compare original and modified audio (Pitch shift or experimental McAdams): Listen & compare puts the two
  players and shared playback controls in one panel, side by side on wider
  screens. Sample, Modification, and modification-specific parameter controls
  sit under Playback; parameters support numeric entry and −/+ buttons and
  are hidden when the processor exposes none. The modified spectrogram prepares silently
  when a sample is selected; Play also prepares changed settings. The samples
  include a six-second excerpt from Wasichu’s 2009 Mencken reading, with source
  and conversion details in `dev/voice_lab/clips/ATTRIBUTION.md`. Try your voice,
  Audio basics, Call delay, and the saved Benchmark each have their own tab.
  Samples play once by default; Loop toggles repeating for both versions,
  including during playback. Changing settings or leaving Listen stops
  playback. Play original → modified starts both versions back-to-back from
  the beginning; Loop repeats the pair using one cancellable playback node.
  Comparison playback inserts a 250 ms silence after each full clip, including
  the final clip so the loop boundary also has a pause.
  Switching to a single version retains the current half's position.
  No microphone is opened for bundled samples. Try your voice is an explicit live
  headphone preview: it opens the mic only on a button press and closes it on
  Stop, tab changes, or navigation. No preview audio is recorded or uploaded.
  The saved benchmark does not follow the sliders.
  It shows verification error rates, top-1 recognition accuracy, and expandable
  processing diagnostics. McAdams is selectable for clips and live preview,
  with a resonance coefficient control (default .9; .7 is the other tested
  setting). It retains per-modification settings and flushes the delayed clip
  tail. Its worklet is built only by the dev profile, not the production
  call registry. Listening quality, voice disguise, known-recording matching,
  and recovery of the original-sounding voice are separate questions; the
  benchmark measures matching. The Recovery test tab separately reviews
  pre-rendered Original/Disguised/Recovered public clips and processing controls.
  Play all plays the selected case's original → disguised → recovered recordings
  back-to-back. Loop repeats the complete sequence; individual native players
  still loop their own clip. Stop, choosing another case, leaving the view,
  or starting an individual player cancels pending or active group playback.
  Run `just voice-recovery` once to generate its audio under `tmp/voice-recovery`;
  the saved JSON is in `tools/voice-eval/results/reconstruction.json`. This
  known-setting approximate inverse loads no recognition models; its numerical
  spectrum distance is not a naturalness or recovered-identity score.
  The Models tab presents a separate offline **Seed-VC V2** experiment on the
  same four public clips. `just voice-model` downloads pinned upstream code and
  weights (~2.7 GB once) into isolated local storage and uses its own Python
  environment; no app dependency or call processor is added. Original → Converted
  playback uses the same 250 ms gaps and Stop/Loop/cancellation behavior.
  The model regenerates style in its average-voice mode; reference independence,
  recovery resistance and live browser performance are untested. Review sound
  and any changed words/pronunciation/accent before expanding the experiment.
  See [`tools/voice-model/README.md`](../tools/voice-model/README.md) for selection,
  licensing and reproducibility; the report is
  `tools/voice-model/results/seed-vc-v2.json`, audio under `tmp/voice-model`.
  **Browser feasibility:** `just voice-browser` runs the published TVTSyn ONNX
  graph in muted Chrome, comparing a complete public clip against native ONNX
  before a minute of independently paced input. Its separate Python/npm
  environments and ~360 MB model stay outside production assets. Open the
  Models view's browser-report link (`/dev/voice-lab/browser-probe`) for timings,
  memory trace and original/native/browser listening. Code and weights are
  CC BY-NC research-only; no production dependency is selected. See
  [`tools/voice-browser/README.md`](../tools/voice-browser/README.md) for exact
  versions, timing definitions, software-GPU detection and reproduction.
  Prepared model outputs and the three fixed DSP presets are also selectable
  in **Listen & compare → Modification**. They load immutable WAV pairs, not
  model weights; controls/spectrograms/reviews are shared with DSP. Seed-VC
  contexts retain earlier saved reviews. TVTSyn native/INT8 cover all four
  public clips (mid voice is a same-target control). Browser WASM also covers
  all four: `just voice-listening-complete` fills missing cases with real
  browser renders and exact-input native parity checks, preserving existing
  contexts. The original paced/resource probe remains the high-voice run.
  `just voice-experiments` regenerates the fixed comparisons
  and the staged resource follow-up after `just voice-browser` setup.
  **Sound quality check:** `just voice-sound-check` reuses those saved native
  TVTSyn WAVs and renders pitch alone, McAdams resonance changes alone and both
  for all four public voices. In Modification, choose the **Sound quality check** group.
  Pitch is −2 semitones for high/mid voice and +2 for low/Wasichu; McAdams stays at .9.
  Mid voice is also TVTSyn's target, so its model output is labeled as a control.
  Whole-clip RMS levels are matched with common peak headroom, without limiting;
  this controls average signal level, not exact perceived loudness. Each clip
  retains 100 ms of ending space. Reviews have separate run/build contexts.
  The command needs the existing research environment and comparisons, and
  runs no neural inference or downloads. Recognition/reversal scores describe
  limitations; they are not the acceptance gate for useful voice masking.
  **Model-free DSP:** `just voice-dsp` prepares WORLD unchanged resynthesis,
  independent pitch, pitch + spectral-envelope scaling, and a breathier texture
  on all four public recordings. Find the **Model-free DSP · WORLD** group in
  Modification; start with the unchanged control. No trained weights or neural
  inference are used. A separate pinned research environment generates RMS-
  matched WAVs and records native offline throughput/worker RSS, not browser
  streaming performance. See [`tools/voice-dsp/README.md`](../tools/voice-dsp/README.md)
  for methods, licenses, reproduction and integration limits. No production
  dependency or audio path is changed.
  **WORLD chunking:** `just voice-dsp-chunks` adds 40/80/160 ms output chunks
  for every voice and the tone. Its menu group compares the saved whole-recording
  WORLD result on the left with the chunked result on the right, with explicit
  titles and reference → chunked playback. This checks quality at fixed pitch/
  resonance settings; auto-saved resemblance judgments refer to the reference
  voice in this mode. Native release/queue/playout estimates are an offline
  simulation, not browser or call latency. See the DSP README for exact context,
  overlap, EOS handling and source/provenance checks.
  **Coverage audit:** with the dev server running, `just voice-lab-audit`
  enumerates every Modification and all four public voices. It checks source
  identity, immutable WAV hashes, full decoded playback buffers and Original /
  Modified / paired playback in muted Chrome, without saving feedback. Results
  go to `tmp/voice-browser/lab-audit.json`. The generated tone is included too:
  **100 combinations** across 20 modifications and five sources, including
  whole-recording-versus-chunked WORLD comparisons.
  `just voice-tone` prepares its diagnostics after the research environments/
  cached models have been set up. It shares the browser's pure tone generator,
  preserves existing voice artifacts and uses cached models only. Neural tone
  outputs are non-speech diagnostics, not masking-quality evidence.
  All three listening views have feedback forms: optional naturalness, clarity,
  resemblance judgments and notes. Drafts are separate per exact source,
  build, parameters and experiment run, and survive browser reloads. Edits
  auto-save after a one-second pause and at most five seconds of continuous
  typing (while a request is available); switching contexts also queues the
  review being left. **Save now** remains an immediate-save/retry shortcut.
  Text-only feedback is appended to ignored
  `tools/voice-eval/results/listening-reviews.jsonl`; tell the assistant
  “reviews ready” to have it read the file on its next turn. Untouched forms
  are not posted. Failed saves retain browser drafts and retry with bounded
  backoff; unsent drafts resume on reload. Requests are serialized and each
  acknowledgment confirms its exact snapshot, preserving later edits.
  On departure, edits behind an in-flight request remain browser drafts until
  the lab opens again; only the Saved status confirms the checkout received them.
  A lost acknowledgment can cause a duplicate append: read the latest payload
  per exact context rather than counting JSONL records as independent reviews.
  Generated audio
  filenames include their WAV content hash, so regenerating an experiment
  cannot silently replace the audio behind an open review page.
  Also,
  [`/dev/translations`](http://localhost:4000/dev/translations), the
  translation shootout's review page (models side by side, where they and
  the evaluators disagree).
- `just voice-eval`: the anonymization benchmark (ECAPA-TDNN speaker
  identity and Whisper intelligibility on a LibriSpeech subset, downloaded
  on first run); commit its `results/benchmark.json`.
  `--only mcadams_1 mcadams_0.7 mcadams_0.9 --output results/mcadams.json`
  selects experiments without changing the corpus. The full run takes only a
  few minutes locally; see `tools/voice-eval/README.md` for the stronger
  known-parameter and search attacks, diagnostics, and native/WASM comparison.
  `just translate-test` and `just voice-eval-test` run the two harnesses'
  offline tests (part of `just precommit`).
- `just translate-update [site|tui]`: after changing UI strings, every
  model translates only the new or reworded ones, which are scored and
  judged, and each language's `.po` gets the picks (a person's fix is
  never overwritten). Models run locally, one at a time, for a while;
  `tools/translate/README.md` has the details.
- `/status` (also in production): the relay check and today's counts.
- `/translations` (also in production): every string per language, each
  with a link to a prefilled GitHub issue. Such an issue becomes a pull
  request through `.github/workflows/translation-fix.yml`:
  `tools/translate`'s `randos_translate.issue_fix` reads and checks it
  (issue text never reaches a shell), and `mix randos.translation_fix`
  writes the one entry with Expo, so the diff is one line (CI for it:
  "Translation fixes" above).
- `just screenshots`: regenerates the README's screenshots
  (`docs/assets/`) from a real call on a throwaway server, with fake audio
  (needs Chrome and `brew install vhs`).
- `just media-loopback`: mic → Opus → speaker through the helper, with the
  latency (use headphones).

## Releases

The terminal client is released from a version tag:

1. Update both clients' translations, review the model checks/picks and check
   translated layouts. Bump `version` in `clients/tui/mix.exs`, write
   `docs/releases/vX.Y.Z.md`, and commit after the release checks pass.
2. `git tag vX.Y.Z && git push origin vX.Y.Z`: CI builds the macOS arm64 and
   Linux x86_64 archives (`just tui-release` builds one locally) and attaches
   them to a GitHub release with the matching notes file. Packaging assembles
   from an empty release directory and rejects duplicate application versions.
3. Commit the output of `just homebrew-formula X.Y.Z` to
   [wasichu/homebrew-randos](https://github.com/wasichu/homebrew-randos) as
   `Formula/randos.rb` ([details](../packaging/homebrew/README.md)).

The server is deployed separately (`just deploy`, to Fly.io).

`just voice-dsp-browser` runs the dev-only three-adapter DSP Worker screen
(WORLD, Signalsmith, and the existing Rust chain), then publishes all five
sources per choice in Listen & compare. First setup downloads an isolated
Emscripten SDK and permissively licensed source archives; no model weights.
See `tools/voice-dsp/README.md` for prerequisites, exact-source checks and
measurement limits. The lab links its size/delay report; this adds no call feature.

`just voice-dsp-round` prepares the next bounded Signalsmith masking-strength
round using the already built browser probe. The dev lab's **Masking round** tab
compares Original, Current and three alternatives together, with shared level
matching, sequential playback and one automatically saved preference per source.
The new alternatives remain available in Listen & compare. No new model/tool
installation or production configuration is involved; see the DSP README.

`just voice-dsp-engines` prepares the preferred-settings Signalsmith/WORLD
comparison with a persistent unresolved-mid-voice note. Use live selects a
profile without requesting a microphone. In Try your voice, choose the explicit
Signalsmith / WORLD experiment and start headphone monitoring. The dev-only
module Worker and duplex worklet use bounded transfer buffers; underruns/overload
stop visibly, and all capture is discarded on Stop. The normal deployment and
call flow are unchanged. Precommit verifies vendored module hashes; smoke covers
actual worklet PCM parity and fake-microphone lifecycle/error cases. See the DSP
README for timing limits and pinned module regeneration.

The live DSP profile selector offers mild/stronger resonance shifts for both
lower pitch (−2, ×.90/×.80) and higher pitch (+2, ×1.10/×1.25). These are
manual listening profiles, not automatic choices based on a voice classifier.

`just voice-dsp-gentle` adds the four-way pitch-strength audition with fixed
resonance settings. Its No pitch shift version retains resonance processing;
None is useful remains a separate preference. Use live transfers exact strength.
`just voice-dsp-buffering` compares only 160/80 ms Signalsmith output prefill using
exact callback PCM and 60 s per mode without retaining minute-long output. The
shorter mode is a gated local experiment; current buffering remains default.
First release must include browser and TUI together; this browser experiment
alone does not qualify native integration or change that scope.

`just voice-dsp-native` is the next bounded feasibility check: the same C++ core
receives/emits TUI-sized 20 ms frames around unchanged 80 ms DSP batches. It
compares four strong-resonance settings with the browser, then measures one
independently paced minute each. Requires the pinned checkouts, exact input
fixtures and modules prepared by `just voice-dsp-browser`; it downloads nothing.
Results: `tools/voice-dsp/results/native-cadence.json`, browser parity in
`native-cadence-browser.json`, visual summary `tmp/voice-dsp/native/report.html`.
This does not link C++ into Rust or change the TUI, its protocol or production
calls. See `tools/voice-dsp/README.md` for limits and interpretation.

The subsequent Rust integration is `voice-native/` (`randos_voice_native`), a
third workspace member with a small owned C++ boundary. Vendored pinned MIT
headers build offline with a system C++17 compiler; the browser SDK is not needed
to build the helper. `just native-check` also verifies header pins and runs fatal
ASan/UBSan C ABI checks. `just voice-bridge-check` compares the actual Rust raw
core and causal frame adapter with the saved browser PCM (requires the native
experiment fixtures above). Failure diagnostics remain in
`tools/voice-dsp/results/rust-bridge.json`.

The TUI media worker uses it through `CallConfig::masking`, off by default,
with real local-call/mute/queue-purge tests and session-only product controls. See `voice-native/README.md` for the FFI audit, gain/range policy and
frame timestamp conventions. Packaging includes the upstream MIT notices;
Linux binaries also require the system C++ standard library (`libstdc++6`).

Product voice choices are now session-only in both clients: the website's Voice
masking panel, and `b` in the TUI (`1/2/3` styles, arrows for tone, `p` audition,
Esc stops/closes). Hear myself starts only after an explicit action; use
headphones. The selection freezes for each call; fresh sessions start Off.
The local helper Port's optional `masking` field is documented in its README;
participant signaling is unchanged. Browser workers/worklets use the production
`voice_masking` build profile, digested same-origin URLs and embedded WASM/license
notices. The dev lab remains dev-only. Its audited adapter/bridge mechanics are
shared, with test PCM capture disabled in the production entry point.
`voice_product_smoke.mjs` covers public choices, preview ownership/cancellation,
processed sender identity, mute/ICE gates, processor failure and device loss.
Terminal/browser integration and recovery cases select masking in both roles.
Do not run translation models without the owner's approval; new strings have
been extracted into both catalogs and use existing-language fallbacks.


The TUI footer shows essential actions; `?` opens complete contextual keyboard
help, `↑/↓` scroll and Esc/Enter/`?` close it. Help consumes input, including
paste, and closes when connection/call status changes. In the join-link text
prompt `?` remains a literal character. Voice choices on the website are a
collapsed row in the existing setup card; closing it stops local preview,
including permission or DSP setup still pending. The homepage is one centered
column: compact title, horizontal progress pills, then setup. Hearing-language
chips start collapsed with the current selection visible. Both disclosures
preserve the person's open/closed choice across LiveView updates.


The website's voice disclosure opens beside the main form at desktop widths;
its chevron points right/left there, down/up in the stacked mobile layout.
Opening it retains the same DOM order, forms and microphone cleanup owner.
The TUI's `l` opens an interface-language list: arrows preview only the cursor,
Enter applies/saves and updates server locale, Esc/`l` cancels. Supported locales
come from Tui.Language.available; display names come from the channel's language
list, with code fallback. The selected row scrolls into view on small terminals.


The TUI carries a small source-pinned renderer patch (vendor/README.md) for
multilingual-popup cleanup. Rustler builds the existing NIF locally; cold builds
need the pinned Rust toolchain and compile longer than the former prebuilt path.
`just prefetch` skips the unpatched renderer downloads. `just screenshots` now
asserts pixel-for-pixel restoration after the language menu closes in VHS; native
TestBackend cannot reproduce the physical width mismatch. Popup transitions use
`full_redraw?` instead of writing ANSI outside the renderer.


Homepage keyboard help is an ignored DOM island owned by `HomeShortcuts`.
`?` or its visible button toggles an inline keycap panel below the form.
Visible means active; hiding with `?`, Esc or the button disables shortcuts.
The panel shares the main card’s edges (including its expanded voice layout),
and opening it never scrolls or moves keyboard focus.
There is no checkbox, modal or focus trap. Once opened, a browser-local flag
restores the active panel on returning to Home or reloading (including language
changes); Escape hides it for the current visit. Actions click the existing available controls, preserving
validation and preview cleanup; editable fields, composition, repeats, Ctrl/Command/Alt modifiers
and open dialogs suppress actions. Letter shortcuts accept either case, including
Shift+letter and Caps Lock. Preview explicitly opens the disclosure.
`VoiceSettings` owns one microphone session and a separately versioned preview
processor. Style/Tone changes retire the previous processor before constructing
the latest choice, while keeping capture active. Off explicitly monitors the
original through a gain-matched branch; failures stop capture. Stop, collapse,
queue/join and navigation cancel both generations, including late grants.
The public link and page heading now read Server Status.

The hermetic Chrome harness disables host-candidate mDNS obfuscation so local
peers do not depend on the runner's multicast/DNS setup. Production browser
behavior is unchanged; default Chrome mDNS itself is not covered by this suite.
Relay-only policy and the local test TURN interruption/recovery remain enforced.

Homepage shortcuts also offer A (click the acknowledgment checkbox), B (native
voice-disclosure toggle), P (preview microphone on/off, opening the voice panel if needed),
S (next Style) and T (next enabled Tone). M is only the call mute button.
E clicks End call; N clicks Next rando. Both are shown only when their call
buttons exist; invitation calls omit Next rando. They share the visibility,
input and modifier guards of the other shortcuts.
Cycling dispatches the existing change event and preserves focus; no microphone
opens from selection alone. Collapsing still uses VoiceSettings cleanup. Help
shows panel-only actions dimmed when closed, labels their scope, and lists Esc;
the expected form-input guard remains in place without explanatory UI prose.

The TUI's headphone audition now keeps its input/output devices open while
Style/Tone changes queue `loopback_masking` to the existing Rust worker. Off
explicitly previews the original at matched headroom. The helper advertises
`live_audition` separately; the silent mic meter retains its own mode and level.
Stop/Esc, call entry and helper/processor failure still stop preview. Already
queued local output drains and the new processor primes with a brief gap.

Live audition start/update reply metadata and all preview helper events carry a
local generation. Old audition and silent-meter start replies/failures cannot
alter a replacement audition. This is only the local Port contract; call-channel
messages and obligations are unchanged.

The homepage uses `Layouts.app`'s home variant: one brand in the main hero,
with horizontal desktop navigation at inline-end and no extra masthead row.
Mobile keeps a normal-flow compact toolbar; other pages keep the shared branded
header. Existing link/locale/theme IDs and in-call locale hiding are unchanged.
The recognition caveat is subdued monospace and the local preview note reads
Headphones recommended (speaker playback can feed back into the microphone).
Shortcut help retains an accessible section label without a repeated visible
heading or status dot. Its activation and no-scroll behavior are unchanged.

The compact homepage keeps the form and shortcut panel within a 1366×768
browser viewport, with masking closed or expanded. Shortcut groups start at the
panel top; Escape's Hide shortcuts button sits beside the outer toggle. The
philosophy line moved to the home footer and aligns to inline-end, wrapping on
small screens. X clicks Stop looking while queued, so the active shortcut panel
continues to offer a relevant action during search. Existing activation/input
and availability guards apply.

Shortcut legend design review: three compact columns (Conversation, Voice, Site)
with concise labels preserve the 1366×768 fit. P is the sole preview key; V and
preview-M aliases are removed. O/R click existing About/Server Status links and
retain ordinary navigation/teardown behavior. L opens the interface-language
menu and focuses the current option. While focus is in that menu, app letter
shortcuts pause; arrows/Home/End move focus and native Enter/Space submit. Escape
closes the language menu first, then the shortcut bar. Hidden in-call locale
controls remain unavailable. Locale POST and native LiveView navigation continue
to own reload/cleanup; no new queue, call or persistence policy is introduced.

Preview form/Invite forwarding resumes in a new browser task after audio cleanup.
A native submit/click activation rejects re-entry during its own microtask
checkpoint; a zero-delay scheduling boundary prevents a cleaned-up action from
being silently lost. This is DOM activation scheduling, not a call-health timer.
Destroyed hooks and disconnected targets cannot replay an action.

Pending preview forwarding keeps one intent; repeated submits cannot bypass
cleanup. Restarting preview invalidates that intent, and the deferred action
checks its audio-session token before using the WeakSet bypass. This prevents a
new preview from being carried through an older pending navigation.

`randos:shortcuts-opened` stores exactly `1` once the panel has been opened;
closing does not clear this ever-opened flag. Guarded storage reads/writes keep
manual toggling working when the flag cannot be stored; a module-local boolean
then supports same-runtime LiveView returns only. Restoration uses the existing
setOpen path and never moves focus, scrolls, invokes an action or captures audio.
The preference never enters participant/channel messages or server storage.
