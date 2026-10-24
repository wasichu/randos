# randos roadmap

Verified against the code at `8c0f513` (2026-10-23). Update this line, and
check that every module/function named below still exists, whenever the plan
changes. This doc names symbols, never `file:line` (line numbers rot; graft
finds symbols). The reasoning and code review behind the 2026-10-19 decisions
is in [`2026-10-19-refactor-findings.md`](2026-10-19-refactor-findings.md).

## Goals

1. **A TUI participant client** (ex_ratatui) alongside the web UI. It must
   never attach to production Erlang nodes or be served over SSH: it is a
   standalone client that talks to the server like a browser does, over the
   public participant channel.
2. **Voice anonymization**, run locally on the user's device (DSP and/or a
   small model). The server stays media-blind.

## Status

| Phase | What | Status |
| --- | --- | --- |
| 1 | Cleanup: dead code, daisyUI, ghost-call and ETS-leak bugs, Ash replaced by plain Elixir/OTP | Done |
| 2 | UI-agnostic participant core; LiveView becomes a shell | Done |
| 3 | Public participant channel (browser stays on LiveView) | Done |
| — | coturn audit, hardening and rebuild; infra on OpenTofu with encrypted state | Done (see [`coturn_audit.md`](coturn_audit.md)) |
| 4 | TUI | Done: monitor, text client, call audio (STUN/TURN, echo cancellation, FEC), release builds, Homebrew tap (v0.2.0) |
| — | Relay-only calls, enforced by the server; `docs/privacy.md` | Done (2026-10-21) |
| 6 | UI translations | Done (2026-10-22): 20 languages (English and 19 machine translations), fixes welcome through "Suggest a fix" |
| — | Translating the TUI ([`tui_translation.md`](tui_translation.md)) | Done (2026-10-23): the same 19 languages as the site, chosen from the environment or with `l` (saved); right to left in every terminal (reordered by the TUI where the terminal doesn't) |
| — | Invitation links: bring someone you know ([`invitations.md`](invitations.md)) | Done (2026-10-24): both clients, reviewed by the owner in two rounds of screenshots, in all 20 languages |
| 5 | Voice anonymization | **Next**, when the owner says; its voice lab starts with a code-quality pass over what landed since the last one (2026-10-23, done): the TUI's translation, invitations, the translation tool's updates, Dependabot. Inventory first, then the owner's decisions |

## How it fits together

- **`Randos.Participant`** is the pure core of one person's flow (find → queue →
  call → back): `handle/2` returns `{participant, effects}`.
- **`RandosWeb.ParticipantShell`** runs that core for a transport process:
  `run/2` executes server-side effects (matchmaker, call coordinator) and
  returns client effects (`{:push_signal, _}`, `{:ice_servers, _}`);
  `client_state/1` is the JSON-safe view (no ids, no peer).
- Two transports share the shell: **`RandosWeb.HomeLive`** (browser, LiveView,
  rendered by `RandosWeb.HomeComponents`) and **`RandosWeb.ParticipantChannel`**
  on `RandosWeb.ParticipantSocket` (everything else; protocol in
  [`participant_channel.md`](participant_channel.md)).
- **`Randos.Matchmaking.Matchmaker`** pairs `Randos.Matchmaking.Entry` structs
  into a `Randos.Matchmaking.Match` and starts the call.
- **`Randos.Calls.CallCoordinator`** (a `:gen_statem`, one per call, `:temporary`)
  owns the `Randos.Calls.Call` struct, moves it through
  `Randos.Calls.Lifecycle`, and broadcasts `{:call_updated, call}` and
  `{:signaling, message}` (built by `Randos.Signaling`).
- **`RandosWeb.IceServers`** mints STUN/TURN credentials per call.
- **Telemetry:** `[:randos, :call, :start | :status | :stop]` and
  `[:randos, :matchmaking, :join]`, with metrics in `RandosWeb.Telemetry`.
- Browser media lives in `assets/js/randos/webrtc_client.js` (`WebRTCClient`)
  and `assets/js/hooks/call_hook.js`; `just smoke` exercises it end to end.

## Phase 4: TUI

### 4.1 Local dev monitor (done)

A terminal dashboard for watching the server while developing: queue depth by
language pair (`Matchmaker.snapshot/0`), live calls and their status changes,
and a feed of recent call/matchmaking events, all from the telemetry events
above. It's also the learning ramp for ex_ratatui before the real client.

Built as `RandosDev.Monitor` (an `ExRatatui.App`) over the pure
`RandosDev.Monitor.State`, run by `mix randos.top` / `just top`. Code lives in
`dev/`, compiled only in dev and test.

- **Data path (decided): in the dev VM.** Telemetry handlers and the
  Matchmaker are local to one BEAM VM, so the monitor runs *inside* the dev
  server's VM: `just top` starts the server and the monitor together (logs go
  to `tmp/` so they don't fight the TUI for the terminal; the browser still
  works against it). No networking and no new process registry. Not chosen:
  a separate `--sname` node over local Erlang distribution; it works, but adds
  moving parts for no gain here.
- **Dependency:** `ex_ratatui` with `only: :dev` in the server's `mix.exs`, so its
  NIF never reaches the release.
- **Tests:** ex_ratatui's headless backend; the state the monitor renders comes
  from a plain module that folds telemetry events, tested without a terminal.

### 4.2 Text-only participant client (done)

A separate Mix project in `clients/tui` (its own deps; nothing in the server
release). It is a **renderer of the channel's `state` pushes**: it holds no
participant state machine of its own, because the server's
`Randos.Participant` already is that. Choose languages, queue, see the match
and timer, vote on extensions, hang up, Next. Audio is a stub. It can be
matched with a browser user.

- Built as `Tui.App` over the pure `Tui.Model`, connected by `Tui.Connection`
  (Slipstream, chosen for join/heartbeat/reconnect handling and its test
  helper). Languages come from the join reply. With no audio, the client
  answers a peer's `offer` with `end_call` (only the peer is requeued; see
  the protocol doc); two TUIs can hold a call (used by `just tui-smoke`).
  `just tui` runs it against the local dev server. Not production-safe yet:
  see "Text-only clients and browsers" under open items.

### 4.3 Audio (done: Stages 0 to 3)

Design: [`tui_audio.md`](tui_audio.md). Proposed: all media in one Rust helper
run as a Port (str0m, Opus via libopus, cpal), Elixir keeps signaling and UI;
`ex_webrtc` rejected for its in-VM NIFs (OpenSSL, libsrtp) compiled on users'
machines. Staged: skeleton → browser interop with real TURN → hardening → AEC.

Stage 1 (browser interop) is built: the helper places and answers
WebRTC calls (str0m), the TUI drives them from the pure `Tui.Media.State`,
and `just tui-smoke` runs an automated TUI ↔ headless Chrome call in both
roles with audio checked both ways. STUN is done: the helper gathers a
server-reflexive candidate and trickles it (checked against Google's STUN
server and a hermetic fake one). TURN is done too: one relay allocation per
call via `turn-client-proto`, trickled as a `relay` candidate (hermetic fake
TURN server; coturn checked with bogus credentials). The str0m-vs-webrtc-rs checkpoint
passed: a whole relay-only call runs through our coturn (`just turn-check`),
so we stay on str0m (see `tui_audio.md`). The end-of-Stage-1 code-quality
pass is done (below). **Live call: done (2026-10-20)**, TUI ↔ Safari on an
iPad through `just dev-turn` on the same network, with each side answering
once: both worked, connected quickly, no dropouts. Within earshot (and with
noise-cancelling headphones) each person also heard the other through the
air, slightly offset: expected without echo cancellation (Stage 3), and
worth a line in the headphones advice. Still to try: the same call across
real networks (iPad on cellular, against production), which is what
exercises STUN/TURN. See `tui_audio.md` Stage 1.

**Stages 2 and 3 (done 2026-10-21; the owner asked for both, no open
design decisions).** All seven items below are built, each with tests,
the relay ones also against coturn (`just turn-check`: four calls/tests).
Order, one commit each, reviewed with the advisor:
1. Relay permissions for every known remote candidate when the allocation
   comes up (the open item below; live-test follow-up).
2. Mute: the helper sends silence and keeps RTP flowing (a stopped stream
   looks like a stall to the peer); Port contract only, as browser mute
   isn't signalled either.
3. The call's path (direct or relayed) in `call_stats` and the TUI's Status.
4. Packet loss: Opus in-band FEC on one-frame gaps, concealment sized from
   the RTP timestamp gap (capped), tested with injected loss.
5. Device selection: list devices, choose them for a call; in-session only.
6. Stage 3, echo cancellation with `sonora` (BSD-3-Clause, a pure-Rust port
   of WebRTC's audio processing; `aec3` if it falls short): render audio fed
   as it's played, capture processed before encoding, never on the mic-test
   loopback (it would cancel your own voice). Tested with a synthetic echo
   (echo reduction and near-end passthrough), then the "headphones
   required" advice becomes "recommended".
7. `turns:` (TURN over TLS, coturn serves it on 5349) as a fallback when the
   UDP allocation isn't up within a few seconds; last, as the heaviest item
   (TLS over a TCP stream in the session loop, `ring`).

Not planned: ducking (superseded by echo cancellation); Firefox stays a hand
test (the e2e harness speaks CDP, Firefox needs WebDriver BiDi). Only a person
can verify echo cancellation on real speakers, Firefox, and `turns:` on a
UDP-blocked network.

Stage 0 code is done:
- the helper (`clients/tui/native`, crate `randos_media`) speaks a JSON Port
  protocol (requests with ids, replies, events) and runs a cpal → Opus → cpal
  loopback (latency measured; see `tui_audio.md`);
- `Tui.Media` owns it (pure `Tui.Media.Protocol`), under `Tui.Supervisor`
  next to `Tui.App`, so a helper crash restarts only the helper;
- `t` on the TUI's idle screen runs a 5 s mic test through it.

**Headphone test: done (2026-10-19)**, on Bluetooth: no feedback, glitches,
or mic prompt; it moved resampling into Stage 0. Results in `tui_audio.md`.

Capability-aware matching is built: `find` carries `audio` (browsers always
`true`, the TUI `false` until Stage 1), and `Matchmaker` keys its queues by
`{speaks, listens, audio?}`, so text-only clients only meet each other.

Decisions for Stage 1 (from the Stage 0 review):
- **Media state lives in a pure module (done).** `Tui.Media.State` holds
  local audio state as `{state, commands}` transitions (the mic test today);
  Stage 1's call audio (ICE, mute, levels) goes there too, not in `Tui.App`.
  `Tui.App` sends requests with `Tui.Media.request_async/2` and never blocks
  on the helper.
- **`OpusLoop` is loopback-shaped.** Stage 1 splits encode (mic → network)
  from decode (network → speaker), and the WebRTC path replaces the device
  sink. It isn't an abstraction to keep.

### 4.4 Distribution (done 2026-10-21: v0.1.0 released)

A `mix release` directory, not Burrito: Homebrew installs a directory
well, and nothing unpacks to a cache on first run. `just tui-release`
makes `dist/randos-VERSION-OS-ARCH.tar.gz` (~18 MB: ERTS, the app, the
media helper in `priv/`, and `bin/randos`, `Tui.CLI`'s wrapper, which
follows symlinks) and checks the unpacked copy (`--version`, `--check`).
Installed builds default to production and log under the user's cache
directory. The macOS release links nothing outside the system (this
Erlang's crypto has OpenSSL built in); Linux is checked in CI.
`.github/workflows/release.yml` builds macOS arm64 and Linux x86_64 on a
`v*` tag (the tag must match `mix.exs`'s version) and attaches them to a
GitHub release; run by hand it only builds artifacts. No tag has been
pushed: releasing is the owner's call.

### 4.5 Homebrew (custom tap) (done 2026-10-21: v0.1.0 is installable)

**Live:** `brew install wasichu/randos/randos` installs v0.1.0 from the
`wasichu/homebrew-randos` tap (checked on macOS arm64: install, `--version`,
`--check`; the formula passes `brew test` and `brew audit --strict`). Each
new version: bump `clients/tui/mix.exs`, tag `vX.Y.Z`, then commit
`just homebrew-formula X.Y.Z` to the tap (automating that needs a token).
Linux through Homebrew is untested.


**Built:** `packaging/homebrew/` (the formula template, `render.sh`, and the
owner's remaining steps). The rendered formula installs and passes
`brew test` through a local tap pointed at a locally built archive. Left
for the owner: the `wasichu/homebrew-randos`
repository, the first `v*` tag, and publishing the rendered formula there
(`just homebrew-formula VERSION`); automating that last step needs a token
for the tap repo. The plan below stands.

Goal: `brew install wasichu/randos/randos`, then `randos` just works. Far
off: it needs 4.3 Stage 1 (real call audio) and 4.4 (release binaries).

- **A tap, not homebrew-core.** Core wants formulas built from source (Rust
  plus Erlang/Elixir toolchains at install time) and a notable project; a tap
  (`github.com/wasichu/homebrew-randos`, formula `randos`) can install our
  prebuilt release archives, one per platform (`on_macos`/`on_arm` blocks
  with a `sha256` each). Linuxbrew gets the Linux glibc build from the same
  formula. Core can be revisited if the project grows.
- **What it installs:** the TUI and the `randos_media` helper side by side,
  so `Tui.Media.default_helper_path/0` finds it without `RANDOS_MEDIA_BIN`.
  Decide in 4.4 whether that's a Burrito binary (unpacks to a cache dir on
  first run) or a plain `mix release` directory; the latter suits Homebrew's
  layout better.
- **Release automation:** a tagged release in CI builds the archives,
  attaches them to a GitHub release, and bumps the formula's URLs and hashes
  in the tap (needs a token with write access to the tap, stored as a repo
  secret: owner's call when we get there). The formula's `test do` block runs
  the TUI's `--version` and pings the helper.
- **Product defaults that change for installed users:** `mix tui` defaults to
  the local dev server; an installed `randos` must default to production
  (`wss://randos.slowinput.org/participant/websocket`), with `--url` kept for
  dev.
- **macOS:** Homebrew formulas don't add the quarantine attribute, so an
  unsigned binary runs; mic permission is granted to the terminal app hosting
  it. Signing and notarization are optional for a tap, but revisit them if the
  4.3 Stage 0 mic-permission findings show an unsigned helper is treated
  differently.

## Phase 6: UI translations (after the first release; alongside Phase 5)

**Status (2026-10-22, later): done, 19 languages.** Vietnamese, Urdu,
Swahili, Persian and Filipino added (`new_languages.md`), 142 of 142
strings each. Owner's decisions: two judges everywhere (Mistral and
Qwen3 30B-A3B; Mistral sits out ur, sw and fil, which its card doesn't
list), either can veto, their mean breaks ties; the new checks
(untranslated English, Arabic letter forms in ur/fa, NFC) re-run on every
locale and the 14 existing ones refilled with `--redo`: 121 strings
re-picked (Arabic's "الراديو", *the radio*, for the relay, and
"التسجيل الصوتي", *recording*, for audio, among them gone; Spanish's
"Conexión", "En una llamada telefónica" and "Su rando" now "Conectando",
"En llamada", "Tu rando"; German's "Sie" now "Du"). Picked most: MADLAD
7B in ur, sw and fa, Hy-MT2 in vi and fil. Judging all 19 locales took
21 minutes (3,765 Qwen, 366 Mistral judgements). The run found a GPU
memory blow-up: Opus-MT and M2M100 repeating themselves to the output
limit took 45–55 GB on MPS and swapped the Mac to a halt; their outputs
are now budgeted to the input, batches are smaller, and M2M100 runs on
the CPU (3.3 GB). Layout checked in ur, fa (right to left) and vi: no
clipping with the system font, so no `:lang` rule or webfont.

Numbered after Phase 5 but started first: after 4.4/4.5 ship, before the
voice lab gets going, and worked on in parallel with it. Scoped 2026-10-20;
design details when we get there.

**Status (2026-10-22): filled, every language, by the models alone.** No
person chooses or reviews translations (the owner's rule); a visitor's
"Suggest a fix" (`/translations`, the translation-fix workflow) is
welcome on top. The shootout ran seven contestants (Hy-MT2, TranslateGemma
4B/12B/27B, MADLAD-400 7B in bf16 with one string at a time and 2 beams
so its generation memory fits, Opus-MT, M2M100) and four scorers
(back-translation chrF, MetricX-24, COMET-Kiwi, the tone judge). Each
string ships its best translation among those passing every check, by
combined quality rank, with a judge veto (rated ≤ 4 while another passing
one is ≥ 7: the judge is the only scorer that sees the context);
translator comments (`gettext_comment`) give the models that take context
the sense of ambiguous strings ("About" the page, "End" hang up); "randos"
is lowercased in every output and checked case-sensitively; no added full
stop. 137–141 of 141 strings per locale; the one plural is left in
English. Judge speedups (2026-10-22): the judge sees only what can
change a pick, the passing translations and of those the finalists
(`review.to_judge`, in rounds over every run at once), reuses its verdicts
(`results/judge-cache.json`, keyed by everything it saw; seeded with the
shootout's 13,270), and batches its prompts (mlx-lm's `batch_generate`).
On the shootout's runs: 2,635 judgements instead of 13,270, at 0.75 s each
instead of ~2.7 s (a batched check gave 128 of 128 verdicts identical);
9 of 1,974 picks would differ from judging everything (the mean rank
depends on which translations are left, and judging everything vetoes
some that were never in contention). The first run with them
(2026-10-22, the extension-vote string, plus "Stop looking" for the
models that read its new comment): 67 judgements, about a minute. It
showed a glossary-check bug: "rando" counted inside other words
("espe*rando*", the French "*rando*nnée", a hike), so French had shipped
"Trouver une randonnée" for "Find a rando"; fixed (a word of its own,
Turkish suffixes allowed), and six French strings and one Portuguese
re-picked. Next: new languages (`new_languages.md`), when the owner says.

**Status (2026-10-21):** plumbing done (`RandosWeb.Locale`, the switcher,
RTL, per-locale `.po` files, the precommit template check, hook text via
`data-labels`); the shootout harness (`tools/translate/`) is proven on
Opus-MT en↔es. Next: the owner logs in to Hugging Face for the gated
models and sets aside GPU time; then the full field runs, the results
page, and filling the `.po` files. Checked: gettext uses fuzzy entries at
runtime, and an empty `msgstr` falls back to English. The review page is
done: `cli review` builds `results/review.json` (models side by side,
disagreement, evaluator conflicts, best per string, winner per locale) and
`/dev/translations` (`RandosDev.TranslationReviewLive`, dev only) shows it.
Proven with Opus-MT and M2M100 418M on es (all strings), ar and ja (20
each): Opus-MT wins es, M2M100 wins ar (Opus-MT's en→ar fails short
strings). Evaluator conflicts need a second scorer, so they appear once
MetricX or COMET-Kiwi runs.

**Where it starts.** The web UI already wraps ~80 strings in `gettext`
(home components, About, layout, `ParticipantErrors`); only `errors.pot` has
ever been extracted, and there are no translations or locale selection.
Language names are already endonyms (`Randos.ConversationLanguages`), so they
need no translation. The TUI's own strings weren't in gettext then (they
are since 2026-10-23: "Translating the TUI" in Open items).

**Languages.** The 14 non-English practice languages: es, zh, hi, ar, pt,
bn, ru, ja, fr, de, ko, it, tr, id. Arabic needs right-to-left layout.

**Plan**
1. **Plumbing.** `mix gettext.extract --merge` into `default.pot` and one
   `.po` per locale; a CI check that the template is current. Locale from an
   explicit choice (a small switcher kept in the browser: no account, no
   tracking), then `Accept-Language`, then English; missing strings fall back
   to English. RTL for Arabic. Interpolation only via `%{name}` (no string
   concatenation), translator comments (`#.`) where context matters.
2. **Translation shootout** (the AI-engineering part). Several open models
   translate every string into every locale; automated checks score them; the
   winner per language ships. Candidates, evaluators, licenses, and memory
   needs are in [`translation_models.md`](translation_models.md) (researched
   2026-10-20): front-runners Hy-MT2 (Apache-2.0, all 14 languages) and
   TranslateGemma (Gemma terms), with MADLAD-400, M2M100 and Opus-MT as
   baselines and a general LLM; NLLB, Tower, and Aya are out (non-commercial).
   Checks, none needing a human:
   - placeholders (`%{count}`) and glossary terms ("rando", "randos") intact,
     length sane (buttons), script correct for the locale;
   - back-translation to English, compared with the source (chrF);
   - reference-free quality estimation with two independent models
     (MetricX-24 and COMET-Kiwi): TranslateGemma was trained on MetricX, so
     never rank on MetricX alone;
   - an LLM judge for tone (calm, informal) as a tiebreaker.
   **Hardware bound:** everything runs locally on the owner's machine (Apple
   M5 Pro, 48 GB unified memory, ~36 GB usable by the GPU): dedicated
   translation models at any size listed, LLMs up to ~32B at 4-bit (MLX),
   nothing 70B-class. ~1,100 short strings in all, so memory, not speed, is
   the limit. The LLM tone judge comes from a different family than any LLM
   contestant (models favour their own output). Tooling (Python,
   `transformers` on MPS, `mlx-lm`) lives in its own directory and pinned
   environment, never in the app's dependencies.
3. **Results as documentation.** A page or diagram of the shootout: scores per
   model and language, where models disagree, what failed the checks. It
   doubles as the record of why each language uses the model it does.
4. **No human review, so make fixes easy.** Machine translations ship as
   they are (check how gettext treats `fuzzy` entries at runtime: don't mark
   shipped strings fuzzy if that hides them); a short "help fix a
   translation" note points to the `.po` files on GitHub (a PR or an issue).
   Human fixes must survive re-runs: the pipeline only fills untranslated
   entries unless asked to redo a language.

## Phase 5: Voice anonymization

The most experimental phase, so it's built around a **voice lab** that
makes trying an approach cheap and comparing approaches easy, by ear and by
eye, before anything touches a real call. (Design reviewed with the advisor
2026-10-19.)

**Status (2026-10-21):** the seam is done in both clients (browser:
`processLocalStream` in `assets/js/randos/voice/seam.js`, off unless
`RANDOS_VOICE_PROCESSOR` names a processor; the TUI helper: `CallConfig`'s
voice step, passthrough, not yet selectable over the Port), processors
are written once in `voice/` (`randos_voice`: Rust, no dependencies,
compiled natively and to a committed 31 KB WASM), and lab v0 is done at
`/dev/voice-lab` (offline renders through the call's own worklets,
switching, spectrograms, real-time factor, delay, live seam latency) with
three public-domain clips spanning low to high voices. Measured in
headless Chrome: the passthrough seam adds ~20 ms to a call, the pitch
shifter ~20 ms more, at well under 1% of real time. Next: the owner
listens; re-measure the seam on real devices.

**Benchmark (2026-10-21):** `tools/voice-eval` (`just voice-eval`) measures
identity (ECAPA-TDNN EER against ignorant, informed and shift-back
attackers) and intelligibility (Whisper WER) on a 20-speaker LibriSpeech
subset, through the real processors; results show in the lab. First
results: no pitch-shift setting hides a speaker. Fixed shifts fool only the
ignorant attacker (informed EER 0–7%, shifted back 0–1%); random per-clip
shifts fool the informed attacker (38%) but are undone by searching for the
shift (0%). WER stays at 5–10% (original 5.7%). Next processors must change
what the speaker model keys on, not just pitch: formant shifting
independent of pitch, randomized per call; McAdams coefficients (the
VoicePrivacy DSP baseline); then voice conversion to a fixed target voice
(the model mini-project). Each future processor needs its own "undo it"
attacker.

### Decisions (2026-10-19)

1. **Processors are written once, in Rust** (one implementation, no
   competing versions in different languages). Each variant compiles two
   ways: to WASM for an AudioWorklet (the lab and the browser call) and
   natively into the media helper (the TUI). The lab therefore tests exactly
   what both clients run. This replaces the 4.3 plan to prototype in Elixir;
   Elixir/Nx stays an option only for model-based experiments that can't be
   expressed this way.
2. **Bundles follow the first-party, same-origin rule** (AGENTS.md; the
   rule was broadened from "only `app.js`/`app.css`" to the security
   properties it protects, so this needs no exception):
   - worklet processors are their own esbuild entry points (or static files
     under `priv/static/`), served from our own origin, because
     `audioWorklet.addModule(url)` loads each one from its own URL;
   - the lab UI is a separate `voice_lab.js` entry built only with
     `dev_routes`, so dev code never ships;
   - shippable processors live under `assets/js/randos/voice/` (the winner
     joins the production call path); only the lab UI goes under
     `assets/js/voice_lab/`.

### Plan

1. **Seam first.** One explicit spot in each client's audio path between the
   mic and the call, with a pass-through default:
   - Browser: in `WebRTCClient.startConnection()`, after `captureLocalAudio()`
     and before `addTrack`: `localStream = await processLocalStream(rawStream)`.
     Teardown must stop the *raw* tracks and close the processor's
     AudioContext; decide whether mute and the visualizer act on raw or
     processed audio; share one AudioContext, created at the capture rate
     (48 kHz) so the seam doesn't add a resampler.
   - TUI: the equivalent spot in the helper's pipeline (its `Processor`).
   - **Done when** `just smoke` passes with pass-through *in the call path*
     and the lab has measured pass-through latency (a worklet hop costs at
     least one render quantum plus destination buffering). That number is
     the budget every real variant is measured against.
2. **Voice lab (local web page).** A dev-only LiveView at `/dev/voice-lab`,
   inside the existing `dev_routes` scope, so it never ships to production
   (the phoenix-framework skill applies; canvas hooks need
   `phx-update="ignore"`).
   - **One file per variant.** Sliders come from the processor's own
     AudioWorklet `parameterDescriptors` (name, default, min, max), so there
     is no separate manifest to keep in sync; a few static fields add display
     name, description, and which clients it runs in. A pass-through
     baseline is always present.
   - **Sources.** Bundled, openly licensed speech clips chosen to span the
     pitch range on purpose (low and high voices, where anonymization quality
     diverges), with a license/attribution file next to them; a test tone;
     and the live mic.
   - **Comparison works on rendered clips.** Every variant of a clip is
     rendered up front with `OfflineAudioContext`: deterministic, faster than
     real time, and exactly in sync. That gives instant switching at the same
     position, blind A/B, parameter sweeps, and side-by-side spectrograms.
   - **Live mic is a separate "listen live" mode:** real time to headphones
     with a level meter and nothing else. Nothing is recorded, stored, or
     uploaded (README product constraints).
   - **Honest numbers.** CPU cost is the offline render time divided by the
     clip length (real-time factor). Algorithmic latency comes from
     cross-correlating each rendered output with its input. (Check which
     timing APIs `AudioWorkletGlobalScope` actually has before promising
     per-frame timing.)
   - **Same code as the call:** variants plug into the seam function the
     browser call uses, so a lab winner is one setting away from a real call.
3. **Built in stages.**
   - **v0:** seam + pass-through + one pitch-shift variant, offline render,
     play and switch, spectrograms. Enough to start judging results.
   - **v1:** blind A/B, parameter sweeps, pitch tracks, real-time factor and
     latency numbers, listen-live mode.
   - **v2:** comparison write-ups.
4. **Comparison write-ups.** After each round, a report page: variants
   tried, their numbers, spectrogram images, blind A/B results, a
   recommendation, and the processed clips embedded so the report can be
   listened to. Only bundled clips, never a recording of anyone's voice.
5. **Model mini-project** (its own design doc once the lab exists): DSP
   (pitch/formant shifting) vs. on-device voice conversion, latency budget,
   browser WASM/WebGPU vs. native, and how much anonymity each actually
   gives (a speaker-similarity check belongs in the lab once there's a
   candidate model).

## One call policy for both clients (done 2026-10-20)

**Goal:** the TUI and the browser are different UIs over the same behaviour.
Both clients used to run their own call-health state machine (5 s grace,
"send `connection_established` once", teardown on a peer's signal), in two
languages. The fix moved that policy to the one place both trust.

**What changed (option A, owner's decisions):**
- `CallCoordinator` owns call health from clients' raw `media_state` reports:
  `in_call` (and the call clock) only once both sides are connected; ends
  `connection_failed` on the connect timeout (configurable,
  `RANDOS_CONNECT_TIMEOUT_MS`), a disconnected grace, or `failed`. Text-only
  pairs activate as before. Values live in `Randos.Calls.Lifecycle`.
- Clients start media at the match (`connecting`), report raw state, tear
  down on the server's status, and end a call they can't carry with
  `end_call` + a reason (no more `connection_failed`, which requeued both and
  could loop for a mic-denied browser user).
- Each participant's `state` push carries the call's `ice_servers` and both
  sides' `media`; error text comes from the server (`error_message`,
  `RandosWeb.ParticipantErrors`). The browser has no default STUN server.
- The spec is "Client obligations" in `participant_channel.md`, checked for
  both clients in both e2e harnesses (coverage table there); diagrams in
  `call_flow.md`.

**Found along the way:** the server never decided a call failed; str0m has
no ICE `Failed` state (a TUI call could sit in `Checking` forever); and an
instant rematch reused the previous call's browser WebRTC hook (fixed by
keying the element by call id). Stale signals were never a client problem:
`Randos.Participant` already drops signals for other calls.

## DRY pass over Phase 4.3 Stage 1 (done 2026-10-20)

Before STUN/TURN; no behaviour changes. Rule: shared logic in one place,
environment-specific code only where the environment differs. Reviewed with
the advisor. Each item: **extract**, **merge**, **link**, or **leave** (with why).

**Rust helper**
- **Extract `audio::Devices::open`**: `Loopback::start` and `Call::start`
  repeat ~20 lines (open capture and playback, play the streams, name them),
  and the call imports `Started` from the loopback. `Started` moves to `audio`.
- **Extract a `Peak` level tracker** (max rms, `dbfs`, reset per report) next to
  `codec::rms`: the loopback inlines the dB formula, the call has a function.
- **Leave the two `Report`s**: they report different facts (latency breakdown
  vs packets and levels each way); a generic report would be the wrong
  abstraction. The once-a-second gate is four lines.
- **Leave the two thread lifecycles**: different stop mechanisms (a flag vs a
  command channel); revisit if Stage 2 adds a third worker.
- **Leave** the dropped-frame rule: it already lives once (`Playback::write`).

**TUI (Elixir)**
- **Leave `Tui.Media.State` as one module** (decision 1): the one shared rule
  (a helper restart fails both features) is already a single clause, and a
  split adds a facade with no behaviour.
- **Verify `pending_signals`** (buffering signals that arrive before the call
  starts): with ICE servers now in the `state` push, a peer's signal may never
  beat our `connecting` push. Prove that with a channel-level test before
  deleting anything; otherwise leave it.
- **Leave `Tui.App`'s routing**: clean, nothing to merge.

**Tests and harnesses**
- **Extract `Tui.TestSupport`** (`clients/tui/test/support/`): `kill_helper`,
  `eventually`, `keys`, `await_model`, and the language-picking `find`,
  repeated across five test files.
- **Extract the smoke server start** in the `Justfile`: `smoke` and `tui-smoke`
  repeat the env, port, trap, and wait-for-server lines verbatim.
- **Leave the three signal-relay loops** (`call.rs` tests, `tests/port.rs`,
  `app_test.exs`): three interfaces in two languages, and each loop is its
  test's subject. (Since 2026-10-23 the Port one is `tests/common::Call`,
  shared by `port.rs` and `restart.rs`.)
- **Leave the e2e scripts**: `cdp.mjs` is the shared part; the scripts are
  different scenarios.

**Docs: one source per fact, others link**
- Timing values: the code (`Randos.Calls.Lifecycle`). `participant_channel.md`
  states them for client authors and points there; `AGENTS.md` and this
  roadmap stop restating numbers.
- Measurements (≈81 ms, ≈290 ms): `tui_audio.md` only.
- Stage status: this roadmap only. `tui_audio.md`'s Stage 1 "Progress" block
  (already stale: it still says the TUI mirrors the browser's grace) becomes
  a link.
- Port protocol: the crate README only.
- The one-call-policy proposal above is now history: condense it to the
  decisions and outcome (decision 3).

**Browser vs TUI, still different**
- **"I left" has two `ended_reason`s**: the browser's page-hide sends
  `peer_disconnected`; the TUI closing its channel ends `disconnected`. Same
  human event. Unifying them changes server behaviour, so it's outside this
  pass (decision 2).
- **Leave**: both clients now get `media.peer` and neither shows it yet (same
  in both); `end_call` reason strings exist in three languages by necessity,
  guarded by the channel's validation and the obligation-6 tests; mute
  (browser only, Stage 2 for the TUI); the TUI holding mic audio until
  connected (a media detail).

**Decisions (owner, 2026-10-20)**
1. `Tui.Media.State` stays one module (no layers that only add indirection).
2. **Unify "I left"**, as a server-behaviour change. Done as: the TUI sends
   `peer_disconnected` when it quits, like the browser's page hide, so the
   same human event gives the same reason from both clients. `disconnected`
   keeps meaning a lost connection (network drop, crash), which a future
   reconnect grace (the "socket blip" open item) needs to tell apart.
   Obligation 7 says so.
3. The one-call-policy proposal is condensed in this roadmap (done).

**Delivered (checked after landing):**
- `audio::Devices::open` and `codec::Peak`: both workers use them; `Started`
  lives in `audio`; no copies left.
- `Tui.TestSupport`: the five files import it; no inline helper copies or
  `kill -9` snippets remain outside it.
- `test/e2e/with_test_server.sh`: the only place the throwaway server starts.
- `pending_signals`: proved unreachable (the server only forwards signals for
  the current call) and removed.
- "I left": the TUI sends `peer_disconnected` on quit (obligation 7).
- Docs: one source per fact; `call_flow.md` has the diagrams.
- Found along the way: a headless Chrome stranded by an interrupted run kept
  reconnecting to test servers. Fixed at the root: nothing a test starts can
  outlive its starter (Chrome over a DevTools pipe, a test-server watchdog,
  Port scripts exit on stdin EOF); see "Testing" in AGENTS.md.
Every commit passed `just precommit`, `just smoke`, and `just tui-smoke`.

## Quality pass at the end of Phase 4.3 Stage 1 (done 2026-10-20)

The milestone pass after STUN/TURN and the str0m checkpoint; no behaviour
changes, reviewed with the advisor. Each gate ran `just precommit`,
`just smoke`, `just tui-smoke`, and `just turn-check` (the only proof of the
relay path).

**Rust helper**
- **Extract `candidates.rs`**: `call.rs`'s session also gathered candidates
  and routed every datagram (STUN interception, TURN wrapping, the trickle
  queue). Now `Candidates` (sans-IO) owns the STUN `Gatherer`, the `Relay`,
  and the trickle; the session keeps the socket, the `Rtc`, and audio. The
  receive order and "relayed data arrives at the relayed address" moved with
  it, with unit tests.
- **Regression guard for the late trickle**: `Candidates::trickle` is tested
  with "SDP sent, mid unknown" directly (the bug once reached `main` with all
  gates green; a timing-based call test couldn't pin it, this can). Checked
  by reintroducing the bug: the test fails.
- **Merge onto `stun-types`**: one STUN codec instead of our own plus the TURN
  crate's; the RFC 5769 vector, a hand-built reply, and a new MAPPED-ADDRESS
  test guard it.
- **Extract `test_support.rs`**: the hand-built STUN reply and the fake STUN
  and TURN servers; relay-only tests moved into `relay.rs`.
- **Leave** the TURN crate's clock and `Transmit` types (contained in
  `relay.rs`), and `Gatherer`'s retransmit timer (a STUN transaction detail,
  not call policy; browsers do the same internally).

**Docs**: the helper README, `call_flow.md` (the TUI diagram and the
same/different table), and AGENTS' TUI row now cover STUN/TURN.

**Owner decisions**
- Bad TURN credentials: **fail fast** (the owner's call). The crate would
  retry for ~40 s; `Relay` now reports `Failed` on coturn's first refusal.
  No user-visible change (the server's 15 s connect timeout decides the
  call either way), no library patch; it gives up the crate's guard against
  a forged 401, which only an on-path attacker could send.
- e2e tests never reach the internet: the test server hands out no ICE
  servers (`RANDOS_ICE_SERVERS='[]'`); srflx is covered by the Rust tests.
- `relay_only` stays test-only (`CallConfig`), not a Port field; it's a
  one-line field if a user's network ever needs diagnosing. (Superseded:
  relay-only calls made it `call_start`'s `relay_only`, 2026-10-21.)

## Quality pass before packaging (done 2026-10-21)

The milestone pass before 4.4/4.5, after Stages 2 and 3; no behaviour
changes, reviewed with the advisor. Each commit ran `just precommit`,
`just smoke`, `just tui-smoke`, and `just turn-check` where the relay path
moved.

**Rust helper**
- **Extract `report.rs` and `tls_stream.rs`** from `call.rs` (it had grown
  back to 938 production lines; now 753): the stats and meters, and the
  TCP connection under a TLS relay.
- **Extract `CallConfig::new(role)`**: six struct literals no longer repeat
  every test-only field.
- **Merge `Relay::allocate`/`allocate_tls`** onto one constructor.
- **Leave** the new client-side constants (`TLS_FALLBACK_AFTER`,
  `TLS_CONNECT_TIMEOUT`, `MAX_CONCEALED`, `LEVELS_EVERY`): they describe this
  network path or this codec, not call policy, so the server couldn't own
  them.

**TUI**
- **Extract `Tui.View`**: the screens (pure functions of the app's state)
  leave `Tui.App` (585 lines, now 231; `App.render/2` delegates).

**Tests**: a warning in every run (`participant/5`'s unused default) gone.

**Docs**: `call_flow.md` (the helper's parts and the same/different table),
`tui_audio.md` (stages done, and the checkpoint's "no C" premise, which
turned out wrong; the str0m decision holds, see there), this roadmap.

**What tests didn't catch tonight**: three bugs passed every hermetic test
and showed only against real coturn or real-device conditions (the late
trickle, two identical test tones cancelled as echo, the 4 KiB TLS drop).
That's why `just turn-check` is in the gate for relay changes, and why the
hand checks matter: echo cancellation on real speakers, Firefox, and TLS
TURN on a network that blocks UDP.

## Quality pass at the start of the voice lab (done 2026-10-21)

Over what landed since the last pass (`13902a9`..: Tui.CLI and the
release, relay-only and its enforcement, the screenshots, the docs
split). Done before Phases 5 and 6 run in parallel, so the pass and Phase
6's template edits don't collide.

| Item | Decision | Why |
| --- | --- | --- |
| The test server's URL read in three TUI integration tests; the audio-TUI starter in two | **Merged** into `Tui.TestSupport` (`server_url/0`, `start_audio_tui/2`) | Same lines, same meaning; one place to change the test server |
| AGENTS.md pointed at a README section that's gone, and didn't mention relay-only enforcement | **Fixed** | Stale docs mislead agents first |
| Two `scenario` helpers in `call_smoke.mjs` and `relay_only_smoke.mjs` | **Left** | Different shapes (one runs a closure, one a whole call); a shared one would need options for both |
| Relay-only explained in README, privacy, self-hosting, the channel doc, the roadmap | **Left**, checked consistent | Each is for a different reader at a different depth |
| `Randos.Signaling`'s candidate parsing vs the helper's own in Rust | **Left** | Different languages and jobs (filter vs gather); nothing to share |

No behaviour changes.

## Quality pass before the voice lab, second (done 2026-10-23)

Over what landed since the last pass (`966f085`..: recovery and ICE
restart, the status page and its stats, the voice seam, the translation
tool, the extension vote, five languages). Four read-only reviews
(server, clients, Rust and voice, the translation tool and user docs),
each claim checked against the code before it reached the owner; the
owner decided in two rounds of questions. Each commit ran its suite;
the batch ran `just precommit`, `just smoke`, `just tui-smoke`, and
`just turn-check` (the relay path moved).

**Bugs fixed** (behaviour changes, approved):

| What | Fix |
| --- | --- |
| The browser's call countdown froze after a dropped socket came back | the hook no longer stops it on `disconnected` (the deadline is the clock's); the call smoke checks it |
| A TUI helper session that died mid-call left the call to fail at the budget, requeuing both | `audio_failed` (obligation 6, widened to "can't go on") |
| A TUI matched again at once (status never left a call) kept the old helper session, so the new call died | the media state follows the server's call id; it was behind tui-smoke's connect-timeout flake (4 in 10) and likely its "Chrome heard silence" |
| The TUI kept the mic open while the server was out of reach | obligation 11: `Lifecycle.offline_limit_seconds/0`, sent in the call; both clients stop at it |
| The pick crashed when the judges vetoed each other's favourite | vetoes that would leave nothing stand down (the owner's rule) |
| Mistral's tokenizer shipped a broken regex (a tenth of the judge's prompts) | fixed at load, part of the cache key; Mistral re-judged (46 strings changed) |
| `--redo --judge X` wiped the other judge's verdicts | only X's are reset |
| `just precommit` re-synced the shared venv under a running model | the model-free commands use `.venv-test` |
| Gettext shows fuzzy entries, so a reworded string shipped a merge's guess | `fuzzy_threshold: 1.0` (English until the shootout fills it) |
| "..." for "…", "٪{minutes}" for "%{minutes}" | `models.tidy`; 29 strings, and Arabic's `%{minutes} min` filled |
| A translation could add a number ("%{minutes} + 1") and pass every check | the `numbers` check (localized digits and spelled-out English numbers count) |
| The README said calls go direct when they can; `privacy.md` had a spliced bullet | fixed |
| The repo URL in six places (a fork's "Suggest a fix" opened issues here) | `config :randos, :source_url` |
| Digested favicons were 404 in production | `only_matching: ~w(favicon)`; the call smoke fetches every icon |
| The status page typed "10 minutes" and "30+" (web and TUI) | the snapshot carries both numbers |
| Relay failure reasons were English on every page | codes (`RelayHealth.Turn.reason/0`), put into words by `RandosWeb.RelayReasons` and the TUI |

**Merged / extracted** (no behaviour change): `bind_socket`/`host_candidate`
in the helper's `call.rs`; `recover/2` and `activate/1` in
`CallCoordinator`; `ParticipantShell.resume/1` returns the ICE servers;
`Stats.endings/0`; `Tui.Model.call_statuses/0`; `enqueue` in
`webrtc_client.js`; `cdp.mjs`'s `eventually`, `launchBehind`,
`watchAppears` and `audioFlows`; `tests/common::Call` (the helper's Port
tests); `Randos.Eventually` (server tests); `Tui.TestSupport`'s
`start_app` and `await_browser`; in the translation tool, `judging.py`
(the judges' rounds, out of `cli.py`) and `runs.py` (the results write,
now atomic for `run --append` too), one locale list (`models.NAMES`,
checked against `priv/gettext` by a test), the score names from
`scoring.JUDGE_SCORES`, judge parameters required rather than defaulting
to Mistral, and the superseded first runs in `results/archive/`. Ruff
checks the Python.

**Test waits** (the "timing fix more than once" trigger, twice): the
helper's in-crate call tests wait for the call to connect, not a fixed
3.5 s; `Tui.TestSupport`'s waits have deadlines (a per-message timeout
never fired in a call). New coverage: obligation 9 with audio in the
TUI, the pick rule's untested branches, `fill_best` and `tidy`.

**Docs**: AGENTS.md (the Calls row, the timing constants, what smoke,
tui-smoke and precommit run, the translations page), the helper README,
`ice_restart.md`, `tui_audio.md`, `call_flow.md`, `participant_channel.md`
(obligation 11, `peer_reconnecting`, the ticket exception, the tests
table), the translation README, moduledocs that had gone stale.

**Left** (with reasons): the two TURN pump loops (test_support's
in-process counters vs the cuttable `test_turn`); a restart's blocking
DNS and loopback fallback (the server's 5 s retry covers it inside the
budget); the TUI ignoring `stream_error` (the README says it may
recover); the shells' twin `handle_info`s and the
`{:shutdown, :connection_failed}` contract (link, don't extract); the
TUI status screen's 30 s poll; the coordinator's health predicates
staying in it (move them if the recovery tests need another timing
fix); `cli tidy` keeping pre-tidy scores (typographic changes only);
both offerer guards for ICE restart (each has its own job). The voice
processor isn't in the protocol yet: Phase 5's decision.

Not inventoried: `.github/workflows/ci.yml`, `config/`, `infra/`.

## Open items

Not scheduled; pick up when relevant.

- **Invitation links (proposed by the owner, 2026-10-22).** Anonymous,
  one-time links, after Lichess's anonymous challenges: create a link,
  share it elsewhere, the first to open it is in a one-to-one call with
  you; it dies once used, after 15 minutes, or when you leave. Design in
  [`invitations.md`](invitations.md): the Matchmaker holds invitations (a
  waiting entry found by token, so claims are serialized and the call
  start, monitoring and 18+ check are reused), the token rides in the URL
  fragment (never in a log or a link preview), and an invitation call is
  an ordinary call marked `kind: :invitation` (both go idle after it, no
  "Next"). The owner's decisions (2026-10-22): both go idle after the
  call; the same 10 + 10 + 10-minute limit; a 15-minute expiry; both
  clients in the first cut; counted among calls started but not language
  pairs; the button says "Invite someone". Likely before the voice lab.
- **Coordinator tests on 20 ms timers (for the voice lab's quality pass).**
  A test needed a timing fix twice on 2026-10-24 (the relay-dead restarts,
  the extension vote: both on a slow macOS runner, both where the timer
  wasn't what was tested). `call_coordinator_test.exs`'s defaults are 20 ms
  for the segment, the extension and the vote: check which tests assert
  timing and which only sequence, and give the latter long timers.
- **TUI help line (idea, the owner 2026-10-24).** It wraps to two rows
  at 80 columns since invitations; fine for now. If it grows, show the
  essentials and a `?` for a screen with every key, a common TUI move.
- **RUSTSEC-2026-0387 ignored (2026-10-24, the owner's call).**
  crypto-bigint 0.5.5's timing side channels reach the helper through
  str0m's DTLS crypto (p256/p384/ecdsa 0.13); the fix needs str0m on the
  0.14 elliptic-curve crates, and its latest release (0.24.1) isn't.
  `clients/tui/native/deny.toml` ignores it; drop the ignore and update
  str0m when a release moves.
- **Translating the TUI (done 2026-10-23).** Every string in gettext
  (`Tui.Gettext`), the language from the environment or `l` (saved),
  right to left checked by eye in Terminal.app (which reorders) and Ghostty
  (where `Tui.Bidi` does); `tui_translation.md` has the plan and the bidi
  spike. Its catalog's first shootout ran six models (TranslateGemma 27B
  skipped to save hours; it won 8% of the site's picks). A string whose
  every translation fails only on a final full stop the English lacks now
  ships the best one without it (`review._without_final_stops`; three
  strings in Japanese and Korean, none on the site). After changing UI
  strings, `just translate-update [site|tui]` translates only what
  changed (`cli plan`, `run --append`, the judges' cache). Its first real
  use (4 minutes) re-translated two TUI status words given context:
  Chinese had read "no call" as "no need to call", now right. Context
  wasn't enough for "not looking" (six languages read it as "not
  watching": the winning models don't read comments), so the English
  became "not looking for a rando". A translation that was the only one
  passing its checks shipped unjudged (about 2% of strings; Chinese got
  "rando: page not found" for that new string): the judges now rate lone
  ones too and either rating it ≤ 4 drops it (the owner's call). That
  dropped 7, now English: the site's Korean "Finding a rando" and "Your
  rando" and an Urdu 18+ line; the TUI's Korean "Your rando", Japanese
  "%{time} to decide", Urdu "%{minutes} min or more" ("May") and that
  Chinese line.
- **Translations still off (2026-10-23).** Arabic leaves "Your rando",
  "About randos" and "Looking for a rando…" empty (English shows): every
  model writes "rando" in Arabic letters or translates it away, and a
  translator comment telling models to keep it in Latin letters made most
  locales quote or explain the word ("Dein „rando“"), so it was taken out
  again. Japanese "requesting microphone" (マイクを頼む) and German
  ("Anforderung eines Mikrofons") still read oddly. Italian "Terminare"
  for the End button is left: it had context, both judges passed it, and
  the infinitive is an accepted Italian button style. Judging only
  finalists hadn't converged everywhere: each re-run today re-picked one
  or two strings outside the ones it was for, when Qwen judged a finalist
  for the first time. The translation-fix workflow has never run on a
  real issue (it was invalid until 2026-10-22's fix).
- **The helper's restart-test flake (fixed 2026-10-23).** Not a timing
  problem: the test relay filed the events one helper sent while the test
  waited on its reply under the other helper, and never relayed them (a
  lost `answer`: no call; a misfiled `disconnected`: credited to the wrong
  side). One harness (`tests/common::Call`) now keeps each side's events
  in its own inbox, for `port.rs` and `restart.rs`; it also waits for the
  call to connect rather than a fixed 3.5 s. This doesn't count toward
  the "timing fix more than once" trigger; the helper's in-crate call
  tests, which still wait fixed times, are in the quality pass.

- **Lost messages in a drop (audited 2026-10-22).** Obligation 9's flake
  was real: a `media_state` lost as the socket dropped left a call
  `connecting` until it failed. Fixed: after a resume both clients repeat
  their last report. The whole protocol was then audited message by
  message ("What a drop can lose" in `participant_channel.md`). The one
  gap, the extension vote, is closed (below).
  Also from this: the obligation 9 test needed timing fixes four times
  (the "timing fix more than once" trigger, raised with the owner); smoke
  failures now keep each scenario's server log and page consoles
  (`test/e2e/failures.mjs`, a CI artifact).
- **Recovery and ICE restart (built 2026-10-22).** A real network change
  (Wi-Fi to cellular, NAT rebinding) kills the media path and drops the
  connection to the server together. Owner's decisions: build ICE restart
  now rather than wait for data; consistent behaviour across every
  failure, so one recovery budget (`Lifecycle.recovery_budget_seconds/0`,
  15 s) replaces the separate grace timers, with restarts inside it
  (2 s after `disconnected`, at once on `failed` or a resume, every 5 s);
  a "Reconnecting audio…" notice (`call.recovering`). Behaviour changes
  approved: a dead call with an older client ends at 15 s (was 5), and a
  dropped connection gets 15 s to come back (was 10). Built: the server
  (`reassess/2` in `CallCoordinator`), the browser (`restartIce`), the
  helper (`call_restart`, re-gathering from a new socket), the test TURN
  relay that can cut a client (`examples/test_turn.rs`, `just test-turn`),
  `recovery_smoke.mjs`; the TUI (`call_restart` as offerer when the
  generation grows, the notice, `recovery_test.exs`: TUI↔TUI and
  TUI↔browser in both roles through the test relay, in `just tui-smoke`).
  The helper noticed a dead path only after ~15 s (Chrome ~5.5 s): two
  gates in str0m's ICE agent, a hard-coded 15 s window after the peer's
  last binding request (`RECENT_BINDING_REQUEST` in `is`) and the default
  STUN retransmit schedule (over 20 s alone). Owner's decision: a patched
  copy of `is` in `vendor/is` (4 s; `vendor/README.md`) with the helper's
  STUN timing tightened; now ~4 s, guarded by
  `a_dead_path_is_noticed_within_seconds`. An upstream issue (configurable
  window) is drafted, not filed. (AGENTS' "a client gains a constant"
  check: the STUN pacing and the window stay in the helper. They're the
  ICE agent's own timing, which the server can't see or run; the policy,
  when to restart and when to give up, is still all on the server.) `just turn-check` passed 2026-10-22,
  including the restart through the real coturn (one helper rebound to a
  new socket mid-call). Design and
  outcome: `ice_restart.md`. Also: `just deploy` now refuses commits that
  aren't on `origin/main` (an unpushed commit once reached production).
- **The extension vote shows what you chose (done 2026-10-22).** A vote
  lost in a drop wasn't counted and nothing showed it. Now the call keeps
  who agreed to continue (`Call.continuing`, reset with each vote) and
  the coordinator broadcasts each counted `continue`; `call` carries
  `agreed_to_continue` (your own only, never ids), and a repeat is
  harmless. Both clients show the choice in place of the question
  (owner's wording: "You agreed to continue, waiting on your rando…",
  never "you voted"), keeping a way to end; after a resume an uncounted
  vote shows the question again. Protocol: a new field, documented in
  `participant_channel.md` (the mini-pass: both clients, the channel
  test of a vote surviving a drop, the smoke's extension scenario). The
  string was translated by the whole field, judged with the speedups.

- **Hearing several languages (done 2026-10-21).** Each person speaks one language and
  picks any number they're comfortable hearing. Two people match when each
  one's speaking language is among the other's hearing languages: the same
  language both ways, or crosstalk. Owner's decisions: the speaking
  language is pre-checked among the hearing languages (and can be
  unchecked); among several compatible people, whoever has waited longest
  is matched. The Matchmaker's `{speaks, listens}` keys become a scan of
  the waiting list (fine at 15 languages, then 20); the browser form gets
  checkboxes; the TUI a multi-select; the channel's `find` accepts a list
  while still taking a single language from v0.2.0 TUIs (a protocol change:
  the mini-pass applies). Built as designed, plus: the speaking language
  is pre-checked only when the form first appears (or, in the TUI, without
  saved settings); after that, changing the speaking language leaves the
  hearing choices alone, in both clients (the owner's call, 2026-10-21:
  replacing the auto-checked language was annoying); the call
  map gains `peer_speaks` (the rando's language), shown in both clients.
  Mini-pass done: `participant_channel.md`, both clients, the obligation
  tests.
- **Relay regions (designed 2026-10-21; build when users far from New
  York appear).** One relay per region (New York now; Frankfurt, then
  Singapore), each person given the one nearest them.
  - *Why per person works:* in a relay-only call each client allocates on
    its own relay and the call runs between the two relay addresses, so
    Madrid (Frankfurt relay) to Houston (New York relay) goes Madrid →
    Frankfurt → New York → Houston: close to the direct path, with short
    detours at each end. Two people in one region share a relay. Relays
    need no knowledge of each other: one shared secret, so any relay
    accepts a call's credentials.
  - *Choosing (decided):* by the Fly edge region that received the
    person's connection (Fly's `Fly-Region` request header; Fly already
    routes each visitor to its nearest edge), mapped to the nearest relay
    by a small table in `RandosWeb.IceServers`. No lookup of anyone's IP
    address, no GeoIP database. First check that the header reaches the
    LiveView and participant-channel websocket connections. Rejected:
    GeoDNS (a paid DNS feature, and it locates the DNS resolver, not the
    person) and handing out every relay (ICE doesn't choose by latency,
    and every call would hold allocations on every relay).
  - *Work:* the coturn OpenTofu config becomes one instance per region
    (own hostname and certificate, e.g. `turn-fra.slowinput.org`); the
    region table and per-participant relay choice in `IceServers` (ICE
    servers are already minted per participant, so no protocol change and
    no client change); `just turn-check` against each relay;
    `docs/privacy.md` and the coturn README list every relay. About $6 a
    month per region.
- **Multi-node matchmaking.** Production runs one Fly machine because
  `Matchmaker` is node-local (two machines split the queue). Before scaling
  out, pick one: a cluster-wide singleton (`:global`/Horde), or a queue over
  `:pg`/PubSub that matches locally and falls back to remote.
- **CI (done).** `.github/workflows/ci.yml`: `just precommit` on macOS and
  Linux (with `RANDOS_REQUIRE_NATIVE=1`), plus `just smoke` and
  `just tui-smoke`. Deploys stay manual (`just deploy`).
- **Same pair rematching on "Next" (done 2026-10-21).** Two people who just
  ended a call aren't matched again for `Lifecycle.rematch_window_seconds/0`
  (90 s), remembered in the Matchmaker's memory only; when the window closes
  and both are still waiting, a timer matches them. The owner's decision:
  a call that never connected skips the window (the coordinator exits
  `{:shutdown, :connection_failed}`, and the Matchmaker unblocks and
  rematches the pair at once). Past three hearing languages, the "Looking
  for…" sentence gives a count instead of the list (both clients).
- **`RandosWeb.IceServers` reads env vars per call (done 2026-10-21).**
  `config/runtime.exs` reads the TURN settings once at boot (`:turn`), so
  with the boot check a missing relay fails at startup.
- **Surviving a connection blip (done 2026-10-21).** A participant whose
  connection drops mid-call is marked away (`call.away`; the rando sees
  `peer_reconnecting`), and the call waits (then
  `Lifecycle.reconnect_grace_seconds/0`, 10 s; since 2026-10-22 the one
  recovery budget, `Lifecycle.recovery_budget_seconds/0`, 15 s). The client rejoins with a
  one-time resume ticket (`Randos.Calls.ResumeTicket`: hash kept in a
  Registry owned by the coordinator; memory-only in clients) and takes
  the same seat. The browser's LiveSocket params carry it and its WebRTC
  hook survives the drop; the TUI's `Tui.Connection` rejoins with it.
  Client obligation 9, with tests in both harnesses; mini-pass done
  (protocol doc, both clients, obligation tests). Open: no ICE restart if
  the media path broke too; v0.4.0 TUIs ignore the ticket (they rejoin
  fresh, and their rando waits 10 s for nothing); the browser stops the
  mic if the server stays unreachable past the grace plus 2 s, a client
  timer derived from the server's constant (raised with the owner).
- **`boundary` library (decided 2026-10-21: no dependency).** The one rule
  (the core never calls the web layer) is enforced by
  `test/randos/boundary_test.exs`, from the compiled modules' import
  tables; `Randos.Application` is exempt. Mutation-checked.
- **Upstream reports (the owner's call: it means posting on other
  projects).** `turn-client-rustls` 0.1.2 gives rustls one `read_tls` per
  chunk, losing bytes past 4 KiB (worked around in `Relay::recv`); and
  `str0m-rust-crypto` pulls in AWS-LC through `dimpl`'s `rcgen` feature.
- **TUI config file (done 2026-10-21; `Tui.Config`).** Managed with
  `randos --settings`, `--edit-settings` (opens `$VISUAL`/`$EDITOR`, then
  checks the file is still JSON) and `--reset-settings`; the idle screen
  says where the file is. A small file in the
  user's config directory (`~/.config/randos/`, or the platform's) keeping
  the chosen mic and speaker, the languages, and that the 18+ notice was
  agreed to. Local only; nothing goes to the server.
- **Decide after a real call:** sonora's noise suppression and gain control
  (only echo cancellation is on).
- **Approved 2026-10-21 (Phases 5 and 6 follow-ups):** hide the language
  switcher during a call (switching reloads the page); make it a small form
  (POST) rather than a link, so prefetching can't switch the language;
  validate `RANDOS_VOICE_PROCESSOR` at boot (all done). The Python harnesses'
  offline tests run in `just precommit` (so in CI), with uv pinned in
  `mise.toml` (done). The full translation run waits for the owner's go-ahead
  (their compute is busy for now).
- **coturn follow-ups** for its next intentional rebuild: see
  [`coturn_audit.md`](coturn_audit.md).

## Decisions

All 2026-10-19 unless noted.

- **Relay-only calls (2026-10-21).** Every call goes through the TURN relay
  (`ice_transport_policy` `"relay"`, obligation 8 in
  `participant_channel.md`), so neither person learns the other's IP
  address: for anonymous calls between strangers, that was the biggest leak
  left (Omegle's was exactly this). The owner keeps an escape hatch for bad
  latency: `RANDOS_ALLOW_DIRECT_CALLS=true` allows direct calls with the
  relay as the fallback. Production refuses to boot without a relay unless
  direct calls are allowed (`RandosWeb.IceServers.check!/0`). If latency
  from far away is the problem, the fix is more relay regions, not direct
  calls. The server enforces it too (`Randos.Signaling.relay_only/2`):
  it drops direct candidates from relayed signals and blanks the addresses
  a relay candidate or SDP could carry, so a v0.1.0 TUI (which ignores the
  policy) can't leak its owner's address; the TUI honours it from v0.2.0.
  Measured from Houston: about 50 ms each way to the NYC relay. When users
  far from New York appear, add relay regions: see "Relay regions" in the
  open items.
- **Public /status (done 2026-10-21):** relay health (UDP and TLS
  allocation every 5 minutes) and today's aggregate counts, cluster-wide
  (counters summed over nodes, then filtered). Daily totals persist on
  the 1 GB volume (`Randos.Stats.FileStore`, one JSON file per day, saved
  after each event; `RANDOS_STATS_DIR=/data/stats`); the image's
  `bin/start` runs as root only to hand the root-owned volume directory to
  `nobody`, then drops privileges with `setpriv`. The TUI status screen is
  done: the channel's `status` request, `s` on the TUI's idle screen;
  mini-pass done (protocol doc, channel test, TUI model, render and
  integration tests). Open: a status link outside About; rate-limiting the
  `status` request if the cluster grows (each one is a multicall).
- **A 1 GB Fly volume for aggregate stats (2026-10-21).** The owner
  approved it (about $0.15 a month) to keep the status page's daily totals
  across sleeps and deploys, keeping costs low: auto-stop stays on. It holds
  only aggregate counts (no IPs, ids, or anything per person), so "no
  database" still holds for people; the small file of totals is the one
  thing kept on disk.
- **License (2026-10-21): AGPL-3.0-or-later.** The owner would mind someone
  running a closed, modified randos; the AGPL's network clause means anyone
  who runs a modified copy for others must offer them its source. The site's
  GitHub link offers ours. Dependencies stay permissive (`deny.toml`).

- **Order after Stage 1 (2026-10-20):** 4.3 Stage 2 (hardening, scoped by
  what the live call shows), then Stage 3 (echo cancellation), then
  packaging (4.4, 4.5); then Phase 6 (UI translations), with Phase 5's
  voice lab starting after it and running alongside; the owner works on
  the voice lab freely. Quality passes stay at their milestones (before 4.4/4.5,
  and at the start of the voice lab).

- **Ash removed**; plain Elixir/OTP first, justify every dependency. Call
  coordinator is a `:gen_statem`.
- **The TUI never attaches to Erlang nodes or uses SSH**; it uses the public
  participant channel.
- **Browser stays on LiveView**; the channel is for non-browser clients.
- **"End" no longer reloads the page** (it hangs up and goes idle).
- **Production runs one machine** until multi-node matchmaking exists.
- **TURN credentials are minted per call**, TTL ≥ longest call + 10 minutes.
- **coturn: hardened via rebuild** (option C, step A skipped), errors-only
  logging, pinned image.
- **Infra on OpenTofu with encrypted, committed state**; passphrase in the
  owner's Keychain and password manager.
- **Dev monitor (4.1) runs in the dev VM**, not as a separate node.
- **TUI audio (4.3): one Rust helper as a Port** (str0m, Opus, cpal);
  headphones in v1; capability-aware matching before Stage 1; the Phase 5
  anonymizer is written once in Rust (WASM in the browser, native in the
  helper). See
  [`tui_audio.md`](tui_audio.md).
