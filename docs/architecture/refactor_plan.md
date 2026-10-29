# randos roadmap

Verified against v0.10.0 (`31679a2`) plus the local post-release conversation
preferences, speaking shortcut and agent-guide update (2026-10-29). Update this line, and
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
| 5 | Voice masking experiment | **In progress; first release requires browser + TUI together.** Level-matched listening and resource costs guide the next DSP/model choice. Recognition/recovery attacks describe limitations; the October 24 benchmark-first gate is superseded by the October 25 goal reset |

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

**First-release requirement (2026-10-27): browser and TUI support ship together.**
The browser lab remains research, not a browser-first rollout. Shared Signalsmith
behavior/presets and native/WASM parity are required. The owned Rust/FFI bridge
and joint browser/TUI product controls are now in place, default off; native
raw/frame speech parity and local Opus mute/resume tests pass. Both clients offer
explicit local audition and session-only selections. Real-device listening,
Linux CI and constrained-device qualification remain before release. See the
dated product integration checkpoint.

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

### Plan refresh (2026-10-24)

Historical decision: the benchmark-first listening gate below was superseded
by the owner's October 25 voice-masking goal reset, recorded later in this file.

The plan below, checked against the code after the TUI's translation,
invitations and three quality passes. The voice code hasn't changed since
2026-10-21 (only the shared lints), and decisions 1 and 2, the seam in
both clients, lab v0 and the benchmark all still hold. The seam's latency
varies between headless runs (≈10 to 20 ms, `measureSeamLatencyMs`);
real devices are still unmeasured. What changed, and the owner's calls:

| Question | Decision |
| --- | --- |
| Next step | **A processor first, not lab v1.** The benchmark already showed pitch shifting hides no one; the owner's ears are the costly judge and hear only what the benchmark passes. So: the benchmark's quick mode (a few clips, its run time measured first; Dependabot's voice-eval PRs wait on it too), then a formant shifter and McAdams (the VoicePrivacy baseline). Lab v1's tools (blind A/B, sweeps, listen-live) only when a finalist needs them |
| Whether a call is disguised | **Each person chooses for themselves, before the call** (on the form, in both clients), not a setting applied to calls or participants; so invitation calls need no rule of their own |
| Who picks the processor's settings per call (randomized, as the benchmark asks) | Later, once a processor passes the benchmark: the call's coordinator (a protocol field; the AGENTS.md mini-pass) or each client |
| The owner listening to lab v0 | Not yet: after the next processor, so the listening is spent on something worth hearing |

Open, for when the opt-in is designed: whether your rando is told your
voice is disguised; whether the choice is remembered (the browser's
cookie, the TUI's settings file); its strings in both catalogs (a
translation run the owner approves first); and `privacy.md`. In the
helper, a processor runs inside the audio callback, which may not
allocate: FFT buffers are made up front, and a model would run on its own
thread.

### Voice lab usability review (2026-10-24)

The owner's first visit found the playback, sliders, spectrograms and “seam”
measurement unclear. Updated lab v0 before further processor work:

- **Merge** playback into two equally accessible Original/Modified controls;
  Selecting a sample (including the initial one) silently prepares its modified
  spectrogram. Play also prepares changed settings on demand. One source plays at a
  time. Settings changes, Stop and leaving Listen cancel playback intent,
  including a pending preparation. Play/Stop use familiar media icons; the
  owner removed the separate preparation-only button and passthrough as a
  listening choice (Original is the reference); the modification selector
  stays, initially offering only Pitch shift. A shared Loop toggle defaults
  off, applies to both versions, and can change during playback; playing once releases the audio
  context when the sample ends.
- **Extract** basic digital-audio and call-delay explanations into
  `RandosDev.VoiceLabGuide`; **leave** DSP and benchmark calculations unchanged.
- **Group** Listen & compare, Audio basics, Call delay and the saved Benchmark
  into keyboard-accessible tabs. Try your voice adds explicit live headphone
  monitoring using the same worklet and microphone constraints; no recording
  or upload. The preview controller can cancel even before microphone
  permission is granted, and closes tracks on Stop, tab exit, navigation,
  setup failure, or device loss. Explain slider units and spectrogram axes;
  rename the misleading CPU percentage to offline render time. Keep the Call
  delay diagram neutral stone for contrast in both themes, explain lag before
  processing overhead (no unexplained “seam”), and put the benchmark results
  table before its explanation. Sample provenance is visible beside listening.
  The next owner review moved the players above compact selectors and sliders;
  numeric entry and bounded −/+ controls share the same parameter values.
  A further layout review merged the players, shared playback controls and
  settings onto one surface, with playback alongside the samples on wide
  screens and responsive stacking on smaller screens. The following review
  moved Sample, Modification and parameter controls under Playback. Parameter
  controls come from worklet descriptors; no descriptors means no control
  section or adjustment hint. No playback logic changed.
  A six-second Wasichu/Mencken excerpt (2009) joins the bundled listening
  references, with source, timestamp and conversion details in ATTRIBUTION.md.
  The benchmark corpus and calculations are unchanged.
- **Link** the contributor guide to the revised workflow. README and
  self-hosting remain accurate: no production UI or processor setting changed.

Advisor reviewed the async playback and tab lifecycle: original playback
must not wait for processing; renders snapshot settings, cache only the
current revision, and cannot start sound after cancellation. The owner still
judges the next UI round; no new processor or anonymity claim is approved.

### First formant experiment and benchmark corrections (2026-10-24)

The owner approved a small experiment before any larger architecture choice.
This supersedes the quick-mode work in the earlier plan refresh: the historical
original/passthrough/random-pitch calibration took 111 seconds, and the full
stronger benchmark takes a few minutes, so `--only` selects existing settings
without maintaining another corpus or runner.

Implemented one dependency-free, bounded Rust McAdams adaptation: 48 kHz to
16 kHz anti-aliased decimation, LPC order 20, 20 ms frames/10 ms hops,
pole-angle warping, residual resynthesis, normalized overlap-add, interpolation
back to 48 kHz. Known delay is 1,022 samples (21.29 ms). Alpha=1 is the matched
bandwidth/resampling/OLA control, bypassing LPC; .7 and .9 are the first
candidates. This is a fresh implementation from the mathematics in the paper,
not copied GPL reference code or an exact baseline reproduction.

The old random-pitch informed result (38% EER) used weaker, independently
randomized reference clips. Protocol 2 fixes tied-score EER thresholds, holds
trial parameters constant over each simulated call, gives the attacker those
exact parameters, and preserves separate prototypes per configuration. McAdams
also faces a six-setting bank (.5 through 1), maximizing scores symmetrically
for genuine and impostor comparisons. These are fixed-model probes, not a full
retrained VoicePrivacy attacker. Top-1 recognition, WER and processing defects
join EER in the saved report and lab table. Historical calibration is labeled
separately and must not be compared as a protocol-2 result.

Focused code-quality inventory, reviewed with the stronger advisor:

| Item | Decision | Reason |
| --- | --- | --- |
| Enrollment and attack score construction | **Extract** `attacks.py` | Preserve per-setting prototypes and apply identical scoring to target/impostor comparisons |
| DSP math versus causal audio framing | **Extract** private `lpc` module; **leave** framing in `mcadams` | Polynomial/root checks have separate invariants; no new general DSP framework |
| Fixed public controls and candidate grid | **Leave** explicit | Three hypotheses do not need a sweep engine or new dependency |
| Native and WASM implementation | **Reuse** one crate | Compare compiled output on four public speech fixtures before any browser integration |
| Offline scoring alignment and diagnostics | **Fix/link** renderer and harness | Flush the delayed tail, align trials/references equally, and expose failed/clipped reference audio per configuration |
| README, development and self-hosting | **Update/link** crate/harness/development; **leave** product README/self-hosting | No new call setting, protocol field or production UI |

Advisor review found no remaining blocking DSP or score-construction issue.
It required the flushed-tail correction, reference diagnostics (including
stronger bank settings), and a separate LPC identity reconstruction test, all
implemented. Allocation-free streaming buffers, bounded root iterations,
root reconstruction/conjugacy checks, muted failed frames and clipping counters
are tested. Sample-rate rejection is explicit at the WASM/renderer boundary.
The native/WASM comparison checks waveform agreement and warm Node timings;
it does not measure browser scheduling or prove anonymity.

Neither initial coefficient passes the recognition filter; .7 additionally
clips. The corrected 266-second run identifies 98.3% of .7 trials and 100%
of .9 trials with matching-parameter references (5% uniform chance).
The .7 trial audio has three failed frames and 388,267 clipped samples;
.9 has no failed frames and 1,710 clipped samples out of 23.4 million.
Stronger bank references also have defects, now visible in the report;
these cannot support a positive privacy claim, while clean matching .9
references already identify every trial. In the four-clip native/WASM probe,
the maximum output difference is 5.96e-8, with measured worst blocks of
0.077 ms native and 0.963 ms warm Node WASM including copies, below the
2.67 ms block duration. These measurements do not cover browser scheduling.
Retain the candidate offline, with no McAdams browser worklet entry,
call setting, or TUI protocol change. This is evidence about these settings,
not proof that all formant transformations fail. The owner's next decision is
which small hypothesis to test next (for example, independent pitch plus
formant changes versus a bounded voice-conversion model probe); choosing a
production architecture or building a broad comparison framework is premature.

### Listening access and revised evaluation goals (2026-10-24)

The owner corrected the experiment's acceptance framing: failing known-speaker
matching must not prevent listening (pitch shift was already available).
McAdams now appears under Modification with its alpha coefficient, default .9,
numeric entry and −/+ controls. Parameters remain independent when switching
modifications, which stops playback and automatically prepares a spectrogram.
Both bundled clips and headphone microphone preview use the same Rust/WASM
implementation. The lab appends zeros to preserve McAdams's delayed tail,
retains its audible latency, and stops instead of wrapping to the beginning
when switching past the original clip's end with Loop off.

The owner's priorities are a natural, intelligible voice that sounds different
from the speaker's original, and especially resistance to recovering an
original-sounding voice from a recorded disguised conversation. A disguise
may still be acceptable even if an attacker with reference recordings can
match identities, provided that limitation is explained. The current ECAPA
benchmark measures the latter; it does not establish perceptual naturalness,
human recognizability or McAdams reconstruction resistance. Pitch reversal
tries to restore the shift and then scores matching, but recovered-voice
listening remains unassessed. McAdams parameter-bank matching is not an
inversion attack. The next attack experiment should explicitly attempt
reconstruction (first a bounded inverse-resonance probe), preserving these
separate questions instead of making one recognition threshold a universal
feature gate. No reconstruction result is claimed yet.

The lab explanation now includes the attack assumptions and corpus provenance:
LibriSpeech test-clean, 10 women/10 men, five clips each (two references,
three trials), separate from the four LibriVox listening excerpts. Failed
matching results remain visible as evidence; the owner judges audible quality.

Focused mini-pass for the new selectable experiment, with advisor review:

| Item | Decision | Reason |
| --- | --- | --- |
| Experimental worklet registration | **Extract** dev-only `processors.js`/`mcadams.js` | Keep the production call registry and supported call settings unchanged |
| Mono worklet-node construction | **Leave** the small dev wrapper explicit | Eight configuration lines are cheaper than broadening the production factory API for one experiment |
| Parameter initialization | **Leave** eager for two small worklets | Switching is synchronous and settings stay independent without async control-rebuild races |
| Playback revisions, cache and exclusive output | **Reuse** existing lifecycle | Processor switches invalidate like source changes; stale renders cannot replace the current choice |
| Tail handling | **Fix** finite-clip flush and end switching | Preserve final speech without silently restarting a shorter reference |
| Documentation | **Update/link** guide, benchmark, contributor and crate docs; **leave** product README/self-hosting | No production feature, new setting or protocol change |

Advisor found no blocking lifecycle, sample-rate or build-boundary issue; its
tail-switch edge case is fixed and covered. Browser checks cover .9/.7 audio,
non-silent rendered samples, padded duration, automatic spectrograms, parameter
retention, original/modified switching, live 48 kHz preview and cleanup.

### Approximate recovery and back-to-back listening (2026-10-24)

The owner's listening feedback: mid/high voices sounded promising with
McAdams, roughly .70–.75 could sound nasal, and milder changes remained
recognizable. These are qualitative observations from an initial listen,
not a measured perceptual study. Retain all cases and separate naturalness,
comprehension, perceptual difference, reference matching, and reconstruction.

The initial reference-based test was chosen as a cheap, repeatable screen
inspired by VoicePrivacy's unlinkability task. Our known-setting oracle and
20-speaker fixed pretrained model are a small adaptation; the official 2024
protocol retrains its attacker, and the original McAdams paper's semi-informed
attacker does not know exact settings. Treating the small test as a universal
gate was inappropriate for the owner's broader voice-disguise goal.

Added `just voice-recovery`: four public clips at .9/.7, same fixed .25 input
gain once before processing each original clip (predeclared headroom), no original provided to the
inverse, and no model training. Rust's explicit offline inverse factory
reestimates LPC and applies exponent 1/alpha. Reestimated angles outside the
forward image cap at π−1e-6; corrected poles/frames are reported separately
from numerical failures and clipping. Forward controls remain .5..1 and the
inverse is not a WASM variant or a call setting. Every pass flushes/aligns
the known delay; sham recovery and original→alpha1→alpha1 are controls.

All eight cases have zero failed frames and zero clipping with this common
headroom. Recovery's log-spectrum distance is lower than disguised/sham in
all eight, but .7 needs caps in nearly every frame and .9 in 227–308/601.
This is a numerically clean approximate attack awaiting human listening,
not evidence that the original voice was reconstructed. The full-level
recognition benchmark and its clipping finding are unchanged. Do not
generalize these results to unknown-alpha searches or learned inversion.

The Recovery test tab has an eight-case selector, exclusive Original /
Disguised / Approximate recovery players, loop/stop, and controls/diagnostics
in a disclosure. Generated WAVs stay under ignored tmp/voice-recovery; only
public-derived basenames are served by a dev route. The saved JSON is committed
as an experiment artifact, with no claim of a privacy pass. A separate pitch
reversal listening positive control and unknown-setting search remain follow-ups;
known-pole forward/inverse and coefficient cap tests validate this first probe.

The owner also requested Original→Modified playback. The lab joins those
finite buffers into one playback node, starting at the beginning; shared
Loop repeats the whole pair. Stop, edits, navigation and the active button
cancel it through the existing lifecycle. Switching to a single version uses
the position within the current half. Loop-toggle bookkeeping preserves the
position when an already-repeated pair is made one-shot.

Focused quality mini-pass, with the advisor:

| Item | Decision | Reason |
| --- | --- | --- |
| Inverse LPC math | **Reuse/extract** private angle-warp helper | One root/pairing/rebuild implementation; forward exponent/range unchanged |
| Inverse mode | **Leave** explicit offline factory/renderer option | Avoid accidentally clamping 1/alpha to 1 or exposing a new call setting |
| Audio rendering bridge | **Extract** raw 48 kHz renderer helper | Benchmark resampling and public-clip review use identical native I/O |
| Recovery clips/metrics | **Leave** in bounded script | Eight fixed cases need no training service or large evaluation framework |
| Sequential playback | **Merge** into existing player | One cancellable node avoids timers, gaps and a second playback state machine |
| Native review players | **Leave** finite public-file players | They need pause/exclusivity, not microphone or worklet ownership |
| Docs | **Update/link** crate, harness, development/privacy and roadmap; **leave** README/self-hosting | No production configuration, protocol or product UI change |

Advisor found no original-audio leak or blocking DSP/UI defect. It required
exact cap-coefficient assertions (implemented) and identified the pitch
listening control as a remaining limitation. Next: the owner hears the
reconstruction examples; then a small fixed pitch+formant combination probe
is a reasonable candidate, rather than committing to a conversion model.

### In-lab listening reviews (2026-10-24)

The owner asked to answer review questions while listening instead of typing
them into chat. Listen & compare now has optional categorical naturalness,
clarity and resemblance judgments plus notes; Recovery has separate disguised
and recovered judgments. All start Not judged. Drafts persist in this browser
per exact source/build/parameters or recovery run/case/headroom. Save review
explicitly sends the snapshot to a dev-only CSRF-protected endpoint, appending
one bounded validated JSONL record to an ignored local review log. No audio,
account, tracking, database or production endpoint is involved. The owner can
say “reviews ready” once; the assistant then reads the file, not pasted answers.
Saving does not itself launch a new assistant turn.

The client captures an immutable context/signature before awaiting a save.
A late response updates only that snapshot's saved marker; edits and other
cases remain unsaved drafts. Storage/file failures preserve answers and do
not disable audio. The log is git-ignored local research data, not a source
artifact. Appends use one bounded encoded record/write, with concurrent-save
coverage verifying complete parseable lines. Feedback analysis takes the last
appended answer for each exact context, not an average across settings/runs.

Advisor inventory and outcome for this user-visible feature:

| Item | Decision | Reason |
| --- | --- | --- |
| Draft identity, storage, save snapshots and status | **Extract** `review.js` | Keep feedback failures/state independent of audio resources |
| Form options, strict validation and local append | **Extract** `VoiceLabReviews`, thin controller | One vocabulary for categorical answers; fixed file path, bounded text only |
| Exact sample identity | **Link/hash** source, WASM, shared worklet and rendering/factory code | A label alone cannot identify the audio that was judged |
| Generated recovery audio | **Fix** immutable content-addressed WAV names and atomic publication | An open page must not fetch new bytes under old run metadata |
| Existing playback | **Leave** unchanged | Feedback neither captures audio nor controls its lifecycle |
| Documentation | **Update/link** development, privacy, harness and roadmap; **leave** README/self-hosting | Local developer workflow only; no production setting or call behavior |

The advisor found the async snapshot/validation/privacy design sound, and
required the shared processing-code fingerprints and regeneration fix above.
Coverage includes concurrent writes, invalid/oversized/unknown fields,
CSRF, separate recovery judgments, failed writes, draft reload/parameter
restoration, storage quota failure with continued playback, and stale save
responses after edits/case changes. Browser tests stub successful writes
instead of polluting the owner's real feedback log; the actual store is tested
against isolated files. The owner judges whether the form is convenient enough
before a larger review wizard or evaluation framework is built.

### Recovery sequence playback (2026-10-24)

The owner requested the recovery samples back-to-back. Play all now plays
the selected case's Original → Disguised → Recovered, starting at the beginning.
Loop repeats that complete sequence; the existing native players remain
individually accessible. Stop, case/view changes, navigation and native
playback cancel a pending or active sequence.

Focused mini-pass for this user-visible control, with advisor review:

| Item | Decision | Reason |
| --- | --- | --- |
| Recovery loading/decoding/playback resources | **Extract** `createRecoveryPlayback` | Immediate cancellation during fetch/decode, same ownership pattern as live preview |
| Sequence timing | **Merge** three decoded buffers at the context's rate | One audio node gives correct order and full-sequence looping without timer coordination |
| Native clip players | **Leave** independent, link exclusivity | Their seek/volume controls remain useful; starting one closes the sequence |
| Settings/DSP/review identity | **Leave** unchanged | The same immutable recordings are played in a different order, with no transformation change |
| Docs | **Update/link** contributor guide and roadmap; **leave** README, self-hosting and privacy | No new capture, storage, production UI, setting or call behavior |

The controller resumes its 48 kHz context in the click gesture, snapshots
the three immutable URLs, aborts pending fetches on cancellation, and rejects
late decode/start/status updates. Loop changes during preparation are applied
when playback starts. All completion/failure paths close the context. Browser
checks use three distinct short PCM fixtures to verify order, total length,
whole-sequence looping, natural completion, Stop during decode, HTTP failure
and retry, and exclusive handoff to an individual player.

The advisor caught an initialization edge: Recovery is available before
Listen's sources/worklets finish loading. Cleanup is now registered before
any await, and a dedicated startup token (separate from render revisions)
prevents late initialization after departure without treating early slider
edits as navigation. Browser regressions cover both early Recovery navigation
and parameter edits during a delayed worklet load.

### Brief pauses between comparison clips (2026-10-24)

The owner found contiguous comparison playback sounded cut off. Both Listen's
pair and Recovery's triple now insert 250 ms of silence after every complete
clip, including the final clip so loop wrap also pauses. No input audio is
trimmed or faded. This is a local developer listening presentation constant,
not a call-timing policy that belongs on the server.

Focused mini-pass: **extract** `joinComparisonBuffers` so both controls share
the same pause; **leave** processing, saved WAVs, Stop/Loop and resource
ownership unchanged; **link/update** contributor docs and this roadmap, while
README/self-hosting/privacy stay accurate. The advisor required uniform mono
sample rates and piecewise, target-clamped positions when switching out of a
comparison during a pause or modified tail. These are implemented. Browser
checks assert full-clip preservation, zero-filled pauses and loop boundary,
plus switching from the first pause to Modified's beginning.

### First pretrained-model listening probe (2026-10-24)

The owner saved all eight McAdams recovery reviews: every recovered voice
still resembled the original person; stronger disguises often sounded
artificial. The owner chose to try a pretrained model next, rather than
making another DSP hybrid a prerequisite. With the strong advisor's input,
selected **Seed-VC V2** for an isolated four-public-clip listening probe:
narrow content tokens plus autoregressive style regeneration and average-voice
generation test a different mechanism. This is the strongest fit among the
inspected candidates, not a global model ranking or a privacy result.

`just voice-model` uses pinned upstream code and model revisions with its own
Python environment under ignored tmp storage. GPL code/weights stay outside
the Rust workspace and production browser bundles. OpenVoice V2 (MIT) remains
an alternative; a low-latency StreamVC paper/demo without usable official
weights does not suffice for this immediate experiment. No training, Rust
port, model runtime selection or live-call integration is approved by this
probe. The existing processor interface remains available for later work.

All four six-second clips rendered locally on MPS (float16 autocast/AR cache;
some modules float32), using style conversion **on**, anonymization-only **on**,
30 diffusion steps and seed 20261024. Final run took 10.21 s for the first
inference and 7.76–8.46 s with the model already loaded; outputs span
5.89–6.52 s and remain untrimmed. The vocoder hit its ±1 boundary on 19/13/270/31
samples respectively; fixed .25 listening gain causes no export clipping.
These wall times are not call latency and do not show real-time feasibility.
The model still processes a fixed mid-voice reference; random-voice mode
clears speaker-style/acoustic-prompt conditioning but leaves reference content
in attention context. Reference independence is unverified.

The Models tab offers Original → Converted, individual exclusive players,
Loop, 250 ms comparison gaps and per-run reviews. Full source/weight hashes,
settings, seed, device/dtype, durations and timings are in
`tools/voice-model/results/seed-vc-v2.json`. Content-addressed WAVs preserve
open review provenance. Failures remain visible, never interpreted as
anonymity. Next decision belongs to the owner: do the voices sound natural,
different and clear without damaging pronunciation/accent? If promising,
test deployment costs and recorded-output recovery; recognition remains a
separate diagnostic. No reconstruction resistance has been tested here.

Focused quality mini-pass (new feature/command trigger), advisor reviewed:

| Inventory | Outcome | Reason |
| --- | --- | --- |
| Native/WASM processor interface | Leave | Offline quality evidence precedes runtime integration. |
| Comparison loading, joining, cancellation | Reuse | Models and Recovery share the existing cancellable buffer player and pause helper. |
| View controls | Leave thin adapters | Different case data and statuses do not justify a new UI framework. |
| Review store/drafts | Extend | Same optional judgments, exact model run/build/source context, fixed local text-only destination. |
| Model source/weights/environment | Isolate and pin | No live audio reaches a service; no production or Rust dependency change. |
| Docs | Link/update | Contributor/privacy/roadmap describe the experiment; README/self-hosting remain accurate for production. |

Advisor findings fixed: Recovery loop no longer changes Models loop state;
source pin check includes staged edits; reference independence is explicitly
unverified. Muted browser checks cover ordered complete clips/gaps, loop,
natural end, navigation cancellation during loading, native exclusivity,
missing-file retry, per-case review drafts and model context. Desktop/mobile
screenshots were inspected. `just precommit` and the full `just smoke` suite
passed; all eight generated WAV URLs were verified on the running dev app.

### Browser feasibility checkpoint (2026-10-24)

The owner completed all four Seed-VC reviews: every voice sounded like a
different person; high/mid natural, low/Mencken slightly artificial; high/low
clear, mid/Mencken some unclear speech. Changed accent and odd syllable stress
make pronunciation preservation a key next criterion. Ordinary speech→text→TTS
is a valid research approach, but can replace a learner's pronunciation with
the synthesizer's. It is not the default next path. The owner approved an early
actual-browser test before substantial integration work.

With the strong advisor, selected the published **TVTSyn streaming ONNX** bundle
for this bounded feasibility probe. StreamVoiceAnon needs export investigation;
LiveAnon's export docs still mark checkpoint distribution pending. TVTSyn's
noncommercial code/weights are isolated research material, not a production
selection. `just voice-browser` pins upstream code, model revision, Python and
npm dependencies; a native reference uses the same graph and fixed public
mid-voice target embedding. All inference remains local. A throwaway site
serves same-origin runtime/model files; neither enters production assets.

The first six-second public clip must preserve complete output and agree with
native ONNX before a one-minute, independently paced stream. Browser processing
runs in a worker, explicitly carries all 207 states, resets before independent
runs and drains/crops exactly like upstream. Main-thread release timers follow
an absolute clock, so slow inference cannot hide input backlog. Whole-step
timing includes input/feed construction, CPU-readable output and state disposal.
Startup, input clock lateness, deadline misses, backlog, output availability
and approximate browser process RSS are separate measurements. Output
availability excludes microphone/playback/call buffering; download timing is
localhost only. WebGPU adapter identity is checked: SwiftShader is software,
so no hardware GPU performance claim is made. WASM CPU inference is measured
independently. Results and the original/native/browser listening artifact are
linked from Models at `/dev/voice-lab/browser-probe`; detailed definitions and
exact report are in `tools/voice-browser`.

Focused quality mini-pass (new command/artifact trigger), advisor outcomes:

| Inventory | Outcome | Reason |
| --- | --- | --- |
| Model inference | Isolate | Actual browser evidence precedes a runtime/production decision. |
| CDP browser lifecycle | Extend existing helper | Explicit GPU opt-in preserves muted/GPU-disabled defaults; failed-launch pipe/process cleanup now handles spawn/timeout errors. |
| Comparison audio | Reuse | The report uses existing cancellable playback and pause logic. |
| Model state/flush | Follow published contract | Native parity includes ending and reset, avoiding a different streaming algorithm. |
| Measurements | Correct | Advisor required whole-step timing and complete runtime loader assets, not false model failures or narrow kernel timings. |
| Docs | Link/update | Contributor/privacy/roadmap explain local probe; README/self-hosting still accurately describe production. |

The continuation decision belongs to the owner after sound/runtime evidence.
Passing only establishes feasibility for this pipeline on this machine; it
does not establish anonymity, recovery resistance, mobile performance or
production suitability. Weight download size, memory, pronunciation fidelity
and licensing remain separate gates. No browser call feature, Rust model port,
microphone recording, server-side call processing or deployment is added.

Observed on this Mac in headless Chrome: four-thread WASM passed complete
waveform parity (maximum absolute difference 0.0000373, relative RMS 0.0000106).
During the paced minute, p95 whole-step time was 29.7 ms, maximum 32.8 ms,
with zero steps over the 100 ms interval and zero input backlog. First output
was available at 231 ms, excluding device/playback/call buffering. The ~360 MB
model and ~2.3–2.6 GiB approximate Chrome process-tree RSS are material resource
costs. Hardware WebGPU remains untested because only SwiftShader was available.
The generated report's playback and desktop/mobile screenshots were verified;
advisor review found no blockers. `just precommit`, full `just smoke` (including
failed-browser startup cleanup), and `just tui-smoke` all passed.

### Unified listening and resource/recognition follow-up (2026-10-25)

The owner wants all candidates in Listen & compare, not isolated listening
sections. Its Modification menu now includes prepared Seed-VC, browser TVTSyn,
four-sample native TVTSyn, native INT8 and three fixed DSP presets. Existing
research sections retain detailed methods/results. The prepared adapter loads
small content-addressed WAV pairs only, updates both references together,
rejects stale loads/source mismatches and uses the same playback/spectrograms
and review store. Earlier Seed-VC reviews keep their exact contexts. There
are no sliders or live-model microphone processing for these choices; original
mic preview remains available. Missing cases clear stale output/review state.
Neural-file timing changes are never reported as DSP/call latency.

The fixed DSP comparison is McAdams .9 then pitch ±2 semitones, or McAdams .85
then pitch −1, with 40 ms pitch slices and a retained 100 ms tail. All four
public clips were prepared with fixed .25 headroom; diagnostics show no failed
frames or clipping. The owner's ears nevertheless found static-like degradation,
source-dependent usefulness of upward/downward shifts and some original voice
remaining. Do not strengthen these presets further as the next experiment.
TVTSyn/INT8 sounded convincing and clear to the owner, but the resource burden
remains a practical obstacle. Mid voice is also the TVTSyn target: its own
conversion is a same-target control, not disguise evidence.

The staged memory test confirms the inference cost is substantial, rather
than merely ordinary browser overhead: ~316 MiB empty, 561–575 MiB with the
runtime, 2434–2451 MiB session-ready, 2203–2219 MiB after a minute (approximate
summed process RSS). Full four-thread runs repeat consistently around 30 ms
p95 per 100 ms chunk; one-thread WASM without isolation headers achieved
61.5 ms p95 with no paced misses/backlog on this Mac. Post-termination RSS
does not return to the empty-browser baseline. The dynamic MatMul/Gemm INT8
graph is 199 MB versus 360 MB; native listening works, but the browser/native
parity gate fails (relative RMS .52) even after using byte-identical input and
recording actual graph/input/speaker/reference hashes. Its paced test was
stopped. Root cause is unestablished; this is not a qualified browser variant.

Known-reference recognition uses the existing 20-speaker selection, distinct
2-enrollment/3-trial utterances, fixed pretrained ECAPA and no retraining.
Original top-1 identification is 100%; TVTSyn against original references 5%;
with matching transformed references 21.7%, verification EER 31.8%. Whisper
word error rises from 5.7% to 9.2%. Corpus IDs/source/output hashes are validated
before scoring; an interrupted rerender cannot silently score mixed outputs.
These are limited diagnostic results, not a calibrated real-world identification
probability or proof of reconstruction resistance. A learned output-only
recovery attack would require paired training data from separate speakers;
providing original-speaker references would be a different, oracle-assisted
scenario. Recorded-output-only reconstruction remains untested.

Owner direction: useful **voice masking with explicit limitations** can be
worth offering; perfect anonymity is not a prerequisite. Name/claims and
method-specific attack disclosures must match evidence. TVTSyn remains a lab
quality reference; warnings alone do not establish acceptable resource costs
or supported-device reliability. Seed-VC v2 (about 2.6 GB downloads, 7.8–10.2 s
per 6 s clip on MPS, RAM not measured) is not a current live-browser candidate.
CC BY-NC is noncommercial, not intrinsically research-only; attribution,
modification notices and distribution fit still matter, including for INT8.

Focused feature/command quality mini-pass, strong advisor reviewed:
**leave** DSP/worklet/call interfaces; **add** the small prepared-pair adapter;
**reuse** comparison rendering/player/reviews; **extract** Seed context creation
to preserve identical review identity across views; **link/update** roadmap,
contributor and privacy docs, with production README/self-hosting still accurate.
Advisor findings corrected exact-input quantized parity, actual-override hashes
and corpus hash validation. Browser regressions cover paired gain references,
no neural latency labels, review sharing, unsupported cases, original mic,
missing files and late-load cancellation. Next work should diagnose artifacts
or screen substantially smaller models, not add stronger versions of these
same presets or port the heavy Seed configuration.

Checkpoint validation: all prepared choices loaded real WAVs in muted Chrome;
desktop/mobile screenshots and the updated listening report were verified.
`just precommit` (now linting both research-tool directories offline) and the
full `just smoke` suite passed. The next proposal should start with a small,
loudness-controlled artifact diagnosis, then one better DSP method or a
bounded screen of smaller pretrained models under a provisional resource budget.

### Focused quality pass: voice-lab controls and live preview (2026-10-24)

Triggered by the new user-facing controls and microphone preview. Inventory
and outcome, with the advisor reviewing async setup and resource ownership:

| Item | Decision | Reason |
| --- | --- | --- |
| Live microphone graph, permission wait, cancellation and cleanup | **Extract** `createLivePreview` into `assets/js/voice_lab/live.js` | It owns resources and exposes immediate cancellation; the lab owns UI intent |
| Microphone constraints and voice processor implementation | **Reuse** `captureLocalAudio` and `createVoiceNode` | Preview and calls must use the same capture settings and worklets |
| Clip rendering versus live monitoring | **Leave** separate | Finite cached clips and ephemeral streams have different lifecycles; sharing a player would obscure cleanup |
| Tab selection, loop choice, render revisions and pending playback intent | **Leave** in the lab | Local developer UI state, not call policy; no server timer or protocol change |
| Digital-audio and delay explanations | **Extract** `RandosDev.VoiceLabGuide` | Keep explanatory content out of playback logic |
| README, development, self-hosting and privacy claims | **Link/update** development and privacy; **leave** README/self-hosting | Lab behavior changed; production UI, configuration and call handling did not |

The advisor's final review found no blocking lifecycle defect in the live
preview. A bounded follow-up review of compact numeric controls found no
concrete defects: partial entry is preserved, values clamp on commit, and
range/number/buttons share one setting. Keep this UI logic together rather
than introducing a general parameter-control framework for two controls. Browser coverage includes late permission after cancellation,
denial, worklet failure, device loss, tab/navigation exit, exclusive routing,
loop boundaries and silent automatic spectrogram preparation. No dependency,
new DSP algorithm, recording feature, or protocol message was added. The
owner's next decisions are experimental acceptance criteria and which
processor to try; this pass does not decide them.

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

## Quality pass before the voice lab, third (done 2026-10-24)

Over what landed since the second (`a10ac18`..: the TUI's translation,
invitations, the translation tool's plan/update/batching, CI and build
fixes, Dependabot). Four read-only reviews (server, TUI, translation
tool, CI/build/docs), the serious claims checked against the code, the
advisor's view, then the owner's decisions:

| Decision | Choice |
| --- | --- |
| The bugs found | Fix them all |
| Arabic prefix before the Latin name (ب, و, ل, ك, ف, ال) | "بـrando" (tatweel); "بrando" was live in the Arabic reconnecting message |
| Veto beyond a lone candidate | English when every judge that rated the pick gave ≤ 4 (14 site, 4 TUI strings; "any judge" would have been 68 and 41) |
| The TUI's `l` and the server's words | A `set_locale` protocol event |
| The TUI's own feedback (copy result, prompt checks, refused requests) | A line under the main panel's text |
| `just deploy` | Refuse a dirty tree and a HEAD without green CI (overrides for emergencies) |
| README screenshots | Regenerate, with invitation shots |
| The link's time left | On the website too (the TUI has it) |
| `dependabot/fetch-metadata` | Pinned to a commit |
| Wording when an invitation call's connection fails | "Your call ended." for any ending you didn't choose |

T5's proposed length check for key/log hints was dropped after measuring:
it flagged correct translations ("unmute" → "desactivar el silencio");
only the printf check (a `%s` the source lacks) stays, inside the
placeholders check.

Outcome (commits "Quality pass 3, …" and after): every bug fixed, with
tests: the server's (an invitation withdrawn on leave, the resumed
joiner's own languages, `token` filtered from logs, the coordinator's
sequence-only tests on long timers), the TUI's (its feedback was never
drawn; the join prompt cut its 18+ line and the link; a disconnect left
the prompt deaf; the help line dropped `l`; the clipboard's exit status
and SSH), the translation tool's (`script_brand` inside words, judged
text recorded per candidate, the update guard, test leaks), and the
build's: `bin/prefetch.sh` (`just prefetch`) is now the one place that
fetches what Erlang's :httpc can't (both NIFs and Tailwind), for setup,
CI and the Dockerfile. Found while finishing: the TUI's key names were
translated ("tab" became a browser tab in six languages, "(y/n)" became
"(Ja/Nein)"), so key names are now placeholders; "idle" alone became
"waste" in Japanese, so the log reuses "not looking for a rando"; and
`just screenshots` read the developer's own TUI settings (now
`RANDOS_TUI_SETTINGS`, dev only).

Left, with reasons: MLXChat's and the judges' batching (four lines each,
different post-processing: extract at a third user); `issue_fix`'s
catalog default (the workflow is site-only); telemetry's `kind` without a
consumer (harmless); the retired 27B's translations keep competing (as
decided); two greedy word packers (different separators and cutting); the
participant core's three similar clauses (clearer apart); Arabic letters
reordered but not joined on terminals without bidi (shaping is out of
scope, documented); `view.ex`'s length (split when it next grows).

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

Not inventoried: `config/`, `infra/` (the workflows and Dependabot were
reviewed in the third quality pass).

## Tidewave startup wiring (2026-10-24)

Codex's direct HTTP registration failed when it initialized before the dev
server was reachable. **Reuse** the pinned `mcp-proxy` for retries and
reconnection; **extract** `bin/tidewave-mcp` as the shared launcher for Codex
and `.mcp.json`. It starts or reuses `just serve`, keeps server output off
the protocol's stdout, and leaves the intentional dev server running.
`mise exec` supplies pinned tools without relying on interactive shell
activation; a 120-second Codex startup timeout covers cold compilation.
Updated AGENTS and development setup. README/self-hosting and production
behavior are unchanged; no dependency or runtime policy changed.

## Open items

Not scheduled; pick up when relevant.

- **Invitation links (done 2026-10-24).** Built and reviewed by the owner
  in two rounds of screenshots; [`invitations.md`](invitations.md) has the
  design and every decision, the quality passes the follow-ups.
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
  skipped to save hours; it won 7% of the site's picks). A string whose
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

### Voice masking goal reset and sound quality check (2026-10-25)

The owner clarified the acceptance goal: useful audible voice masking, natural
and intelligible speech that preserves pronunciation, small downloads and
reasonable memory/compute/delay. Hardware-dependent alternatives remain an
option. Strong known-reference recognition and recovery tests document limits;
they are not a product pass/fail gate. This supersedes the October 24 plan's
benchmark-first listening gate and the requirement for every future processor
to have an undo attacker before listening. Existing attack results remain
visible; our fixed ECAPA tests are not the full retrained VoicePrivacy protocol.

Start with two contrasting voices and isolated operations: pitch alone,
McAdams resonance change alone, both, and saved native TVTSyn. High voice uses
−2 semitones; low voice +2; McAdams remains .9 and pitch slices 40 ms. No stronger
masking preset or neural port is authorized by this experiment. Equal .25 gain
had left model output much louder than DSP; the sound check instead matches
whole-clip RMS and uses one common peak attenuation per voice, without limiting.
This is an average signal-level control, not exact perceived loudness matching.
All versions retain 100 ms ending space. Source/output hashes, gains, diagnostics
and build/run context are retained; reviews are separate from earlier runs.

Next decision follows listening: if pitch adds roughness, compare a better
pitch shifter; if McAdams does, compare a different spectral-envelope/vocal-tract
warp. Independent pitch/formant controls are promising; these two algorithms
are not the entire DSP palette. Avoid adding effects until this bounded test
informs the next one. TVTSyn remains the clear-sound reference; do not infer that
a better DSP algorithm will necessarily match its quality or conceal identity.

Focused feature/command mini-pass inventory: **leave** production DSP, call and
worklet interfaces; **reuse** saved TVTSyn WAVs, existing paired players and review
store; **add** one small offline preparation command; **group** Modification
options to keep the comparison discoverable; **link/update** contributor/tool
instructions and this roadmap. README and self-hosting remain accurate because
no production setting, dependency or audio path changed. Strong advisor review
found no blockers. Its interpretation caveat is recorded: the pitch operation
also moves resonances; the McAdams path includes filtering/resampling, so this
comparison isolates operations rather than pure acoustic properties. A cheap
follow-up, if pitch introduces roughness, is 20/40/60 ms slices at fixed ±2
semitones before replacing the algorithm. A model-free analysis/synthesis
vocoder such as WORLD is another candidate family, pending a bounded listening
and resource trial; no new dependency or implementation has been selected.

Checkpoint: real saved WAVs for all eight modified cases loaded in muted Chrome;
desktop/mobile layouts were inspected, with aligned desktop play buttons and
spectrograms. Exported RMS spread is below .001 dB per voice, with no clipping
or failed processing frames. Mathematical level/headroom guards, strict review
contexts and browser regression coverage pass. Final `just precommit` and full
`just smoke` exited successfully. The lab is ready for owner listening feedback.

### Sound-check coverage fix and listening direction (2026-10-25)

The initial two-voice sound check disabled mid voice and Wasichu playback;
that scope limit was confusing in the shared Sample/Modification controls.
Prepare all four public recordings for each sound-check choice. High/mid use
−2 semitones, low/Wasichu +2, with McAdams .9 and 40 ms pitch slices unchanged.
These are fixed experimental choices, not automatic voice adaptation. Mid
TVTSyn remains a clearly labeled target-voice control. The generated tone is
still unsupported by prepared experiments; the browser TVTSyn probe still
covers high voice only. No neural inference or new downloads were needed.

Owner listening feedback at these settings: pitch + resonance is promising;
pitch alone can provide useful masking; resonance alone leaves too much of
the original voice; TVTSyn sounds best but may cost too much. Prioritize
cleaner combined DSP while holding masking strength steady, keep pitch alone
as a simpler comparison, and retain TVTSyn as the sound-quality reference.
The next proposed experiment is a small pitch-window comparison at fixed
pitch/resonance settings, rather than stronger transformations or a model port.

Coverage-fix checkpoint: strong advisor found no blockers; all sixteen real
modified clips loaded in muted Chrome, exported RMS spread stayed below .001 dB
per source, and DSP diagnostics reported no failures or clipping. The browser
regression now plays mid/Wasichu pitch + resonance pairs, checks the mid-target
control label and retains the unsupported-tone guard. `just precommit` and full
`just smoke` both exited successfully. No production behavior changed.

### Model-free DSP auditions and complete listening matrix (2026-10-25)

Owner direction: explore more DSP/model-free options while retaining participant-
side processing; centralized TVTSyn inference is outside Randos's environment.
A bounded WORLD screen now provides four choices for every public voice:
unchanged resynthesis control, independent pitch with the original spectral
envelope, pitch + envelope scaling, and added mild aperiodicity/breathiness.
No trained weights, transcription, new production dependency or call path is
involved. WORLD is modified BSD and PyWORLD MIT; the isolated Python research
requirements are hash-pinned. Rubber Band was investigated but not selected:
its GPL/commercial license does not fit the workspace's permissive-only policy.

At 48 kHz, Harvest uses 50–800 Hz and 5 ms frames. Strong advisor review caught
CheapTrick's inconsistent default floor, which affected particularly Wasichu;
all final samples were regenerated with floor50/FFT4096 explicitly shared with
D4C. Pitch ±2 preserves zero-valued F0; spectral scales .9/1.1 affect the whole
envelope, including unvoiced sounds. The control isolates resynthesis loss.
Common resampling/tail and RMS/peak matching apply to every candidate/original.
The report records exact source/output/native-extension provenance, settings,
gains, levels, timings and peak fresh-worker RSS. On this Mac native offline
analysis+transform/synthesis RTF is .15–.17; peak Python worker RSS ~287–295 MiB;
the installed native extension is 480,640 bytes. These are not WASM bundle size,
browser memory or streaming latency measurements. Harvest currently uses whole
clips. Listening must justify any streaming/FFI/WASM investigation first.

The owner also requested every modification for every public voice, including
old experiments. Only browser TVTSyn lacked three cases; those were generated
with actual WASM, byte-identical native-reference inputs and passing parity
(relative RMS 8.4e-6, 8.3e-6, 2.6e-5). The high-voice report/input files and review
context remain intact. Per-processor merging adds the missing cases without
replacing high voice. Mid remains a target-voice control in both native/browser
variants. Older prepared WAVs and their contexts were not regenerated.

Focused feature/command quality inventory: **leave** production DSP/worklet/
call interfaces and Rust dependency rules; **reuse** prepared-pair playback,
spectrograms, level matching, immutable WAV publication and review storage;
**add** one bounded DSP screen, missing-case browser completion and a complete
matrix audit; **link/update** contributor/tool documentation and this roadmap.
README/self-hosting stay accurate because production behavior is unchanged.
Strong advisor review corrected the WORLD analysis floor and an audit duration
assumption: older Seed-VC Wasichu is 5.886 seconds, so completeness is verified
against the actual selected artifact rather than a six-second minimum.

The real-data audit passed **68/68 pairs: 17 modifications × four voices**.
It verifies source IDs, WAV hashes, decoded sample counts/rates, finite non-silent
Original/Modified playback and paired durations with the existing pauses. Muted
Chrome writes no feedback. All sixteen WORLD pairs and desktop/mobile layouts
were checked separately. `just precommit` passed; final browser smoke validation
is recorded below on completion. No further experiments should replace these
samples before the owner's listening and notes.

Final checkpoint: `just precommit` and full `just smoke` exited successfully,
including WORLD review/playback, all-voice browser TVTSyn, unsupported-tone guards
and call/recovery regressions. Re-running `just voice-listening-complete` was a
no-op for existing cases; saved contexts remained unchanged. The owner can now
use the stable 68-pair set for listening and notes before further experiments.

### Include the generated tone in every modification (2026-10-25)

The owner clarified that completeness includes the generated test tone, not
only four voices. The canonical four-second harmonic glide now lives in the
pure `assets/js/voice_lab/test_tone.js`, shared by the browser and offline Node
rendering. Its own source hash replaces the whole UI-file hash for tone review
identity, so unrelated UI changes cannot invalidate prepared diagnostics.

`just voice-tone` adds all fifteen offline choices: cached Seed-VC V2 through
a separate diagnostic report, native/INT8/browser TVTSyn, fixed DSP presets,
RMS-matched sound checks and WORLD. The two adjustable DSPs already supported
the tone. Actual browser conversion passed parity (64,000 input/output samples,
relative RMS ~3.1e-5). Generated outputs have explicit non-speech diagnostic
notes; they cannot establish speech quality or masking. Existing voice WAVs
and prepared review contexts were not regenerated. Tone outputs use the same
processor settings/implementations as their voice experiments.

Focused mini-pass: **extract** the shared tone generator to avoid numerical
drift; **reuse** existing processors, cached model environments, immutable WAV
publication, strict contexts and players; **add** a separate tone-only manifest
and extend the audit to every source. Strong advisor verified canonical PCM,
artifact/source hashes and browser parity. Its two provenance findings were
fixed: standalone browser completion validates tone PCM against the generator,
and tone run scope states four-second synthetic input rather than six-second
public speech. README/operator settings remain accurate; contributor/tool
instructions describe the new command. No production dependency/path changed.

The expanded real-data audit passed **85/85 pairs (17 modifications × five
sources)**, including Original/Modified/paired playback and full selected WAV
lengths. No feedback was written by the audit. Final precommit/browser results
are recorded below after completion.

Tone checkpoint: full `just smoke` and final `just precommit` exited successfully;
the updated menu regression verifies tone availability across legacy and new
prepared choices. Existing voices were not regenerated. The 85-case audit is
now the complete lab-source check, ready for the owner's listening and notes.

### Listening feedback and automatic review saves (2026-10-25)

Read the latest saved feedback, deduplicating each exact context. WORLD pitch
alone is clear/natural but sounds like the same speaker in all four reviewed
voices. WORLD pitch + spectral-envelope scaling is promising: high/low stay
clear and natural with partial resemblance; mid is slightly artificial and
still retains accent/cadence. Breathiness is not a consistent winner: low was
rated different, mid/Wasichu partial. The owner's summary likewise favors
WORLD + DSP with uncertain help from breathiness. Keep the plain combined
WORLD candidate as the primary direction, retain texture as an optional
comparison, and preserve pronunciation rather than chasing stronger masking.
No audio or processor setting was changed for this UI task.

The owner requested auto-save. The three review forms now back up edits in
localStorage and share one serialized save queue, coalesced by exact context.
Attempt after 1 s idle or 5 s continuous editing while the sender is available;
queue old-context drafts immediately on a source/setting switch, and flush on
visibility/page transitions. Save now remains available. Unchanged/untouched
forms do not append repeatedly. Snapshot acknowledgments cannot overwrite later
edits; dirty restored drafts resume automatically. Requests time out after
12 s; network/server failures retry at 5–30 s, with visible failures and retained
drafts. Validation errors wait for an edit/manual retry. This is UI durability
policy in the browser, not a call-health timer or participant protocol change.

Focused mini-pass inventory: **extract/merge** form saves into one queue so
multiple views cannot race writes to the same context; **reuse** the existing
strict endpoint, CSRF, append-only file and draft format; **leave** production
paths and dependencies unchanged; **update/link** contributor/privacy docs,
with README/self-hosting still accurate. Strong advisor caught old instances
replacing a new page's entire draft store after navigation. Persistence now
merges the changed context into current storage, preserves later notes, and
destroyed instances cannot persist acknowledgments. Per-key unsaved-memory
tracking preserves quota-failed edits. Delivery is at least once: a lost reply
may duplicate an append, so summarize latest payload per exact context rather
than treating lines as independent ratings. No database or audio upload added.

Browser coverage includes automatic idle/periodic saves, coalescing without
clean re-appends, failures/retry, held requests and later edits, source changes,
reload recovery, storage quota failures, recovery reviews and navigation.
Mocks install before application startup on every page, so automatic test
feedback never reaches the owner's JSONL. Final checks are recorded below.

The advisor verified the late-ack fix preserves both same-context new-page text
and unrelated drafts. One intentional limit: navigation stops the old queue;
edits behind an in-flight request remain durable browser drafts and resume on
the next mount, rather than being guaranteed written on departure. The Saved
indicator confirms a particular snapshot reached the checkout.

Auto-save checkpoint: `just precommit` and full `just smoke` exited successfully.
The revised regression verifies the late-ack navigation fix, automatic retry,
periodic typing, restored outbox, context binding and quota-failure fallback.
Saved listening feedback supports WORLD pitch + envelope as the leading small
candidate, with breathiness optional and the mid-voice weakness retained in
our interpretation. Audio samples/settings remain at the listening checkpoint.

### WORLD short-window feasibility screen (2026-10-25)

The owner approved the next small experiment: preserve the promising pitch +
resonance settings and compare short overlapping chunks against saved whole-
recording WORLD, before any browser port. Other DSP families remain open (PSOLA,
phase-vocoder/time-stretch pitch changes and waveform-preserving spectral warps);
a poor result here rejects this reset-synthesis wrapper, not DSP or streaming
WORLD generally. The upstream stateful synthesizer is a possible separate
follow-up if excitation resets cause the texture problem.

`just voice-dsp-chunks` prepares 40/80/160 ms output hops for all four voices and
the canonical tone. Each bounded window uses 80 ms past, 20 ms retained output
overlap and 40 ms right context. The current hop is final when this window is
processed using its predecessor's overlap; no extra future hop is silently
needed. Initial input buffering is thus 100/140/220 ms before compute. Linear
complementary fades have unit coverage at every sample, including odd final
hops. End padding is available only on EOS. The existing whole-clip reference
never enters the transform, alignment or F0 estimation; it is used only for
listening comparison and whole-clip RMS presentation after rendering.

Native schedule: `finish=max(release,previous_finish)+compute`, with release at
the declared window input end, clamped at EOS. Required fixed playout is max
`finish−output_start`. On this Mac, across all five sources:

| Output hop | Native RTF | Simulated required fixed playout |
| --- | --- | --- |
| 40 ms | .67–.70 | 129–136 ms |
| 80 ms | .40–.42 | 174–183 ms |
| 160 ms | .26–.28 | 265–275 ms |

Steady-state queue wait is zero in all fifteen trials. EOS drains take up to
~49 ms and are recorded separately from steady backlog. These are short native
Python/C++ offline runs from preprocessed 48 kHz input, excluding resampling,
normalization, capture/playback and transport. They are not browser/call delay,
long-call reliability or low-end-device measurements. The harness keeps whole
output/coverage arrays for artifacts; it is not a bounded-memory live client.

The existing Listen & compare UI now gives three **WORLD · chunking comparison**
choices. For these only, explicit headings identify **Whole-recording WORLD**
(left) and **Chunked WORLD** (right); icon playback and back-to-back controls say
reference → chunked. Level matching uses one shared headroom factor for all four
versions per source, without limiting. Review mode `chunked_world` changes the
resemblance prompt/options to the reference voice, so quality judgments are not
misread as masking success. Returning to other modifications restores Original /
Modified labels and original-person judgments. Existing prepared source/audio
and review contexts remain intact; new cases use the same automatic-save store.

Focused feature/command mini-pass: **leave** production Rust/worklet/call paths;
**reuse** WORLD settings/warp, immutable reference WAVs, level matching, players
and review persistence; **add** a pure chunk join/scheduling harness and small
metadata adapter for reference labels; **link/update** DSP/contributor docs,
with README/self-hosting still accurate. Strong advisor validated causal bounds,
finalized-hop accounting, OLA and scheduling, and requested separate EOS/steady
metrics (added). Browser regression caught Phoenix's implicit label wrapper;
reference text now updates only its label span, preserving the select and its
accessible label. A dev-server reload interrupted the first broad real-data
audit; final audit runs after asset-rebuilding suites on a stable test server.

Pure tests cover unit-gain identity reconstruction, endpoints/odd final hops,
prefix causality, scheduling arithmetic and rejection of invalid chunk output.
Full native/server/offline precommit and focused browser regression passed;
final browser/audit results are recorded below. Subjective chunk quality remains
for the owner to judge before choosing a port or another DSP method.

Chunking checkpoint: final `just precommit` and full `just smoke` exited
successfully. The stable throwaway-server real-data audit passed **100/100
pairs (20 modifications × five sources)**, with no feedback writes. Desktop/
mobile screenshots were inspected; reference/chunked play controls align, the
reference-specific question is visible, and normal labels restore correctly.
Existing whole-recording references and settings are unchanged. Await listening
on clicks, periodic roughness and consonant fidelity before another experiment
or the separate browser feasibility probe.

### Browser DSP adapters and three-way listening checkpoint (2026-10-26)

Owner accepted the 80 ms WORLD chunk quality and authorized a browser harness
plus three approaches to audition before selecting an implementation. The goal
remains clear, natural **voice masking** within practical local resources;
recognition/recovery attacks are diagnostics, not a perfect-anonymity gate.

Focused mini-pass inventory: **reuse** the accepted WORLD window/warp settings,
existing Rust McAdams/pitch processors, public sources/tone, immutable WAV
serving, comparison players and auto-save reviews; **extract** a tiny shared
Worker adapter contract (sample-positioned output, finish/drain, close), with
algorithm-specific state/buffering retained by each adapter; **leave** production
calls, Rust FFI and AudioWorklet scheduling untouched; **link/update** contributor
and DSP reproduction docs. README and self-hosting still describe the product
correctly because this is a dev-only public-clip experiment. Strong advisor
review found an early input-release clock and missing file provenance checks;
both corrected, with a clock regression test and exact PCM/native/module hashes.
Finish timing is separate from normal blocks, and pending input includes active
work. There is no architectural or privacy-policy decision for the owner yet.

Three candidates: bounded-window WORLD pitch/resonance, deterministic stateful
Signalsmith Stretch phase-vocoder with independent formant scaling, and the
existing Rust McAdams + delay-line pitch reference. WORLD/Signalsmith C++ wrappers
are isolated research code compiled native and WASM from pinned permissive
upstreams; the Emscripten SDK stays ignored and is not an app download.

Native WORLD must reproduce the accepted Python version. Browser/native parity
is gated for all 15 voice/tone cases before one independently paced minute
per approach. Nine additional silence/onset/ending checks retain strict
waveform failures as explicit diagnostics; an affected choice is an experimental
audition, not qualified for arbitrary inputs. All output is finite, contiguous,
exact-length PCM. The clock releases blocks at their ending timestamp; excessive
pending input fails visibly. Report includes raw/compressed assets, local setup,
compute/drain, pending input, required output playout, WASM linear capacity and
approximate process-tree RSS (shared/retained pages prevent precise per-algorithm
RAM comparisons). Capture, device playback, network, low-end hardware and
AudioWorklet deadlines remain unmeasured. Pitch's variable acoustic delay is not
represented by emission timing alone. No full minute of output is retained.

Each new Browser DSP modification covers four voices and the synthetic tone,
compared with raw Original, with shared RMS/headroom matching. Existing cases
and review contexts remain intact. A small HTML report is linked from the lab;
listening uses existing paired playback/spectrograms/automatic text reviews.
Stop for the owner's sound judgments before trying stronger settings or ports.

Browser probe results: all 15 speech/tone native/WASM comparisons passed;
WORLD native/Python relative RMS error was ~2–6e-13. Seven of nine additional
boundary waveform checks passed. Signalsmith onset/ending impulses exceeded
the unchanged .001 relative threshold (.00228/.00706; max absolute
.0000229/.0000925), while output remained finite, contiguous and complete.
The numerical cause is unconfirmed. Advisor approved retaining both failed
checks/PCM and allowing explicitly experimental listening, rather than tuning
settings or weakening the thresholds. The report and Signalsmith listening
notes retain that qualification; this is not an all-checks-passed claim.

All three independently paced minutes completed with at most one 80 ms input
block unacknowledged and no WASM linear-memory growth. Required output playout
on this machine was ~227 ms WORLD, ~167 ms Signalsmith, ~107 ms Rust reference;
these exclude capture/device/network latency and pitch's variable acoustic delay.
Raw module+loader sizes were ~118/83/52 KiB respectively. Configured WASM
capacity was 32/32/2.25 MiB; this is not total browser memory. Browser-generated
WAVs cover all 15 pairs. Required project and real-data playback checks follow.

Checkpoint verification: `just precommit` exited 0 (server, native/WASM,
TUI units, translation and voice-eval offline tests); `just smoke` exited 0,
including the new browser-choice playback/review coverage. The stable-server
real-data audit passed **115/115 pairs (23 modifications × five sources)**
without saving reviews. The report was visually inspected, and the dev lab
answered HTTP 200. Direct impulse checks confirmed nonzero onset and retained
ending energy for all three browser outputs; the two Signalsmith numerical
parity failures remain explicit. Stop here for listening feedback; no production
integration or algorithm selection has been made.

### Stronger Signalsmith round and compact preference view (2026-10-26)

Owner judged all three initial browser DSP outputs clear/acceptable but subtle,
and approved one small stronger Signalsmith round before trying the best setting
through WORLD or integrating a live microphone/phone path. Current remains ±2
semitones with .9/1.1 resonance scales. New choices are more pitch (±4, current
resonances), more resonance (±2, .8/1.25), and opposing (±3, 1.1/.9). Directions
are explicit per voice; opposing changes two parameters, not one isolated cause.

Feature-trigger inventory: **reuse** source/tone identities, spectral adapter,
native/browser parity runner, immutable WAV serving, joined playback with 250 ms
gaps and auto-save/draft queue; **extend** the runner with one bounded round flag
and separate artifacts; **add** a small dev-only component/controller for five
rows and one preference; **leave** old comparison contexts, production calls,
Rust FFI, model choices and latency policy. Contributor and DSP docs updated;
README/self-hosting still describe the product/operator surface correctly.
Strong advisor reviewed design and implementation, catching loop-off progress
and native-player reverse ownership gaps; both fixed with browser regression
coverage. The owner decides which, if any, voice disguise is worth pursuing.

All four voices and tone receive Original, Current and three candidates, matched
as one five-way level set. All 20 browser outputs pass strict native parity;
Current PCM matches the earlier browser baseline exactly. The whole ordered set,
source/settings, gains and immutable audio filenames bind the preference's build
identity. Blank Not judged differs from None is useful. The shared review schema
strictly isolates whole-round preferences from individual quality/resemblance
ratings. Prior artifacts and feedback remain intact. Synthetic tone feedback
is diagnostic; inherited impulse-parity discrepancies remain unresolved.

The new Masking round tab offers icon playback, progress highlighting, waveform
amplitude previews, one source choice, loop/stop and all-five playback. Source
changes cancel preparation, partial loads expose no playback or preference, and
all lab audio owners stop one another. A tiny preference plus optional notes
uses the existing periodic auto-save, network retry and local draft persistence.
No new performance or privacy result is inferred from this listening round.

Round checkpoint: final `just precommit` and full `just smoke` exited 0,
including the compact round's sequence/progress, loop-off, native-player reverse
ownership, auto-save/source-isolation, stale preparation and missing-file tests.
The final stable-server real-data audit passed **130/130 normal listening pairs**
(26 modifications × five sources) and **25/25 compact-round clips**, checking WAV
hashes, source identities, complete playback and five-way gap arithmetic, with
no review writes. Desktop/mobile layouts and dark active playback were visually
inspected; no horizontal overflow at 390 px. Explicit dark row/hover states keep
playing text legible. Stop for the owner's preference feedback before selecting
settings or proceeding with WORLD/live microphone/phone experiments.

### Preferred engine comparison and live DSP preview (2026-10-27)

All four exact-context user reviews were read: high/low prefer Current; Wasichu
prefers More resonance for better disguise with acceptable quality; mid selects
None because cadence/accent remain recognizable and stronger variants distort.
Owner approved comparing the preferred settings through WORLD and Signalsmith,
then an explicit local headphone/microphone experiment. Mid is persistently
marked unresolved, never presented as a successful masking result. No recognition
attack is promoted back to a shipping gate, and no production processor is chosen.

Feature-trigger inventory: **reuse/extract** the verified browser adapter into
`assets/js/voice_lab/dsp/adapter.js`, parameterize the existing compact component
for one three-way comparison, preserve shared players and auto-save store;
**add** one bounded duplex bridge/Worker and immediate-close controller for the
live prototype; **vendor/build** exact pinned WASM/loaders/licenses with a source
and binary-hash guard; **leave** participant contracts, Rust/helper workers,
server timing policy, call flow and deployment assets. Internal dev audio-port
messages are not participant protocol obligations. Initialization timeouts and
buffer constants describe a local dev audio experiment, not server call policy.
README/self-hosting still describe the product; contributor/privacy/DSP docs
updated. The owner still decides sound quality and whether to pursue call work.

Signalsmith/WORLD use identical per-source settings: high/mid −2/.9, low +2/1.1,
Wasichu +2/1.25 and diagnostic tone −2/.9. All ten new browser/native checks pass;
Signalsmith PCM matches the reviewed preferred outputs. Original and both engines
are level-matched together, with immutable round/source/settings/audio context
for auto-saved preferences. Old auditions and feedback remain available.
Use live selects an engine/profile without microphone permission; start is explicit.

The dev-only ESM Worker receives PCM directly from a duplex AudioWorklet via a
transferred MessagePort. The worklet has five reusable 80 ms input buffers,
320 ms maximum pending input, a 640 ms output ring and 160 ms output prefill.
Only bounded capture/playout runs on the render thread; synthesis stays in the
Worker. Both original/modified paths use fixed .25 gain and no RMS normalization.
Dry monitoring still consumes wet output to avoid stale speech on switching.
Starvation after startup, overflow, missing/nonfinite/clipped spans or worker
failure stop/mute visibly, with no automatic dry fallback or rebuffering. Live
Stop discards rather than draining; fixture drain requires a finite sample count.
Tracks, context, ports and worker share one lifecycle owner, including late grants.

Strong advisor reviewed design and implementation, catching unsafe Infinity drain
and misleading prefill-as-latency assumptions before implementation, then a missing
timeout around the offline test reference (fixed). No blocking audio-path defect
was found. Actual 128-frame callback tests match independent exact-input Worker
renders, including startup silence and complete ending audio, for both engines.
Initial measured bridge delays were ~240 ms Signalsmith/~277 ms WORLD plus unmeasured
hardware latency. This is one-machine headset feasibility, not mobile performance,
network call latency or an improved privacy guarantee. Fake-mic tests cover both
engines, switching, profile changes, initialization/permission cancellation, worker
failure, device loss, navigation and restart. Existing impulse diagnostics remain.

Engine/live checkpoint: `just precommit` exited 0, including the new pinned DSP
asset guard. Full `just smoke` exited 0: existing call/relay/recovery tests,
comparison/review suites, actual-worklet exact-PCM checks for both engines,
stalled/underrun failures and complete fake-mic lifecycle coverage. An older
five-way test initially counted controls across both comparison views; its
assertion is now correctly scoped, and the full suite passed after the fix.
The offline reference stage also has a bounded deadline and port/worker cleanup.

Final stable-server audit passed **140/140 listening pairs**, **25/25 strength-round
clips**, and **15/15 preferred-engine clips**, with no feedback writes. Desktop,
390 px mobile, and active dark live-preview layouts were visually inspected;
there was no horizontal overflow. Existing real-review latest timestamp remains
2026-10-27T11:56:22.537671Z, with no fabricated engine votes. Actual phone performance
and the owner's live listening remain pending; no call integration was added.

The existing :4000 process required a restart after esbuild configuration changed.
Tidewave confirmed it was non-interactive and had zero calls started; the standard
serve-stop/serve recipes restarted only that background server. The lab then
answered HTTP200, Tidewave reconnected and confirmed the updated Worker entries,
and the complete fake-microphone lifecycle suite also passed against :4000.
The context graph was rebuilt with `just graft` after the change.


### Live review: prefer Signalsmith; complete the profile palette (2026-10-27)

The owner's saved engine reviews prefer Signalsmith for all four recordings:
high has better masking/quality, low notes WORLD warble, Wasichu finds both mask
but Signalsmith cleaner, and mid remains hard to mask despite better Signalsmith
quality. The explicit live test also strongly favors Signalsmith; retain WORLD
as an experimental reference rather than pursuing its quality further now.

Owner noticed the live palette lacked lower-pitch/stronger resonance. Its earlier
asymmetry reflected recorded preferences, not a technical limitation. Add the
Signalsmith-auditioned −2 semitones/×.80 profile alongside lower mild and both higher
profiles. Focused new-setting inventory: **reuse** the existing parameter map,
select and exact Worker initialization path; **extend** the fake-mic regression
with actual lower/stronger streaming and exact parameter assertions in both engines; **leave**
DSP code, buffering, published comparisons, saved review identities and production
paths. README/self-hosting remain accurate; contributor/DSP docs updated. Advisor
consulted for this focused setting change. Signalsmith is the candidate to pursue;
mid-voice masking and real phone performance remain unresolved.

Advisor agreed with the bounded addition and requested an explicit WORLD start/process
check, since previous stronger-round parity covered Signalsmith. The shared live
regression now exercises −2/×.80 through both engines without claiming prior WORLD
parity or improved WORLD quality.

Profile checkpoint: `just precommit` and full `just smoke` exited 0. The live
regression verifies −2/×.80 initialization and actual streaming through both
engines, including stop-on-setting-change and the existing teardown/fault cases.
The new option completes the four-profile live palette without altering previous
comparison artifacts or review contexts.

Owner suggests a future product flow with a few modification choices and an
explicit unrecorded microphone audition, since voices respond differently.
Treat this as product direction to explore, not authorization to integrate it
into calls yet. A small Signalsmith preset palette is the current candidate;
engine names/math need not appear in the product. The mid-voice result remains
a reason to allow honest rejection of every preset and avoid implying universal
masking or recognition resistance. Live preview would remain optional, explicit,
and fully stopped when leaving it. Current work stays in the dev lab.

### Gentler pitch and one output-prefill experiment (2026-10-27)

Owner finds ±2 pitch too dramatic and approved one-variable gentler listening
plus a bounded buffering trial. Owner clarified the first-release gate: **browser
and TUI together**, not browser-first. Keep native integration/unsafe-boundary
and packaging decisions open before production; this work remains the browser
lab, with shared Signalsmith presets and native/WASM parity as release requirements.

Feature/setting mini-pass inventory: **reuse** the compact comparison, pause/loop
player, immutable public samples, exact-context auto-save and spectral core;
**extract** a shared deterministic actual-worklet fixture from the existing smoke
script for the timing experiment; **merge** the third comparison's lifecycle and
review-context dispatch into the existing bounded comparison-ID map rather than
adding more duplicated owners; **leave** native DSP/input partitioning, Rust/TUI,
server call policy and production UI untouched. A small report loader verifies
source freshness before enabling the shorter local option. Contributor/privacy/
DSP docs updated; README/self-hosting product/operator claims remain accurate.
Strong advisor reviewed the design and warned that zero_pitch must not share the
existing none/reject-round ID; these are distinct in data, UI and validation.

Gentler pitch compares Original, current ±2, half ±1, and no pitch shift while
holding each source's preferred resonance fixed. All 15 native/browser checks
pass; Current PCM matches the reviewed source. All four voices and tone have
complete four-way level matching, immutable artifact/preference identity and an
exact live-settings handoff. Mid remains unresolved. Live profiles now have a
separate current/half/zero pitch choice; zero still processes resonance.

The buffering trial changes **only** Signalsmith output prefill 160→80 ms, leaving
80 ms batches and all queue limits unchanged. The shared fixture passed exact
callback PCM, startup silence and complete tail in both configurations. Each then
completed 60 s with contiguous playback counters and zero terminal faults, using
bounded queues and no minute-long PCM retention. Initial sample-coordinate delay
was 240→160 ms; minimum post-quantum output was 80→0 ms and maximum 160→80 ms. Zero
available after a quantum is less margin, not a recorded underflow. Both peaked
at 80 ms unacknowledged input and kept 32 MiB WASM capacity. Hardware/network delay,
real phone performance and native TUI buffering remain unmeasured.

The 160 ms prefill remains default. The 80 ms option is Signalsmith-only, accepts
only the two tested values, and stops/restarts capture on changes. Eligibility
requires completed exact-PCM and sustained gates for both configurations plus
matching bridge/worker/adapter/vendor/fixture hashes; stale or failed results do
not enable it. Existing terminal-failure/no-original-fallback behavior remains.

Advisor implementation review tightened that evidence: verify actual vendor
files and the served worker/worklet bundle bytes as well as source hashes,
including the probe itself and build configuration. The supported recipe checks
vendor pins and rebuilds before measuring. Setup and playback share an outer
deadline, late callbacks are guarded, and context closure has a bounded wait;
these checks apply to the shared exact-PCM fixture too. Re-run the finalized
probe after builds before accepting shorter-buffer eligibility.

Finalized probe repeated both exact-PCM gates and independent 60 s runs with
the same 240→160 ms sample-coordinate delay, 80→0 ms minimum output margin,
80 ms maximum pending input, unchanged 32 MiB WASM capacity and no terminal faults.
Freshness checks accept this build. Strong advisor rechecked the provenance and
deadline fixes with no remaining blocker. Browser/TUI joint release remains a
gate; this result makes no claim about native integration or phone performance.

Verification checkpoint: `just precommit` and full `just smoke` passed, including
gentle preferences/live handoff, both real worklet streams, all three live pitch
strengths and existing failure/teardown cases. Real-file audit passed 155/155
listening pairs plus 25/25 masking, 15/15 engine and 20/20 gentler comparison
clips without writing reviews. Desktop/mobile and dark live-preview screenshots
were inspected; the live shorter option reported 160 ms and stopped all tracks.
The running :4000 lab returns HTTP 200 and Tidewave confirms fresh buffer evidence.
No production call, TUI, protocol or native helper behavior changed this round.

### Provisional first options and future DSP experiments (2026-10-27)

Owner's latest listening feedback: stronger resonance is useful alone and with
the half shift (one semitone); weak resonance leaves the original voice too
detectable. Full pitch plus stronger resonance sounds like an overt documentary
disguise. Carry forward two Signalsmith candidate styles: stronger resonance
alone, and stronger resonance plus a one-semitone pitch shift. These are
provisional listening choices, not validated privacy guarantees or frozen
direction/scale values for every voice. Keep the earlier mid-voice concern open.

Before product integration, compare these two across the public voices and live
microphone, then run a small native TUI integration experiment against identical
browser settings/fixtures. Validate actual call audio, resource use, delay,
teardown and failure behavior in both clients before the joint first release.
Present accessible sound descriptions and an optional local audition; separate
pitch movement from resonance so zero pitch has no misleading direction label.

Additional techniques should follow the existing small experiment path: add one
candidate to the lab, render the same complete source set, compare with these
baselines using saved listening feedback, and measure streaming/resource behavior.
Promote a useful candidate only after browser/native agreement and call checks;
keep unsuccessful experiments as evidence without adding product choices.
Reuse the current harness and explicit preset settings; no general plugin
framework or growing product control panel is needed to test the next technique.

### Native-core cadence feasibility experiment (2026-10-27)

Owner approved starting the native feasibility check. Inventory/advisor outcome:
**reuse** the unchanged pinned Signalsmith core, exact public fixture bytes,
browser adapter and parity runner; **link** a small standalone C++ cadence probe
to that core; **leave** Rust dependencies/unsafe policy, helper protocol, devices,
AEC, codec, call flow and product settings unchanged. An FFI crate or subprocess
driver inside Rust would choose an integration boundary before this evidence is
available; neither is needed to measure native-core cadence. This is explicitly
not a completed TUI integration. Contributor/DSP docs and the voice-crate README
distinguish this experiment from existing Rust production processors. README,
self-hosting and privacy product/operator claims still describe unchanged calls.

`just voice-dsp-native` checks `(pitch, resonance)` of `(0, .8)`, `(-1, .8)`,
`(0, 1.25)`, `(+1, 1.25)`: two proposed styles in both directions, not four new
product promises. Native 960-sample ingress aggregates into unchanged 3,840-sample
core calls; aligned output uses the existing 7,680-sample prefill and is delivered
in 960-sample slices. Absolute 20 ms deadlines expose slow computation rather
than moving the source schedule. Fixed queues throw on overflow/starvation; stop
discards pending audio. The finite path alone flushes the complete original tail.

Before measurement, 20/20 speech/tone browser comparisons passed (maximum relative
RMS error below 1e-9); 9/12 silence/impulse diagnostics meet the strict tolerance.
Three impulse cases remain outside it and are retained as unresolved evidence.
All 32 finite native fixtures match their ASan/UBSan builds; sanitizer findings
are fatal. An EOF regression checks parent-pipe ownership, and a one-second
sanitized cadence run exercises the bounded output path. Offline gate tests
reject late/incomplete runs, changed buffer limits and discontinuous delivery.

Strong advisor reviewed scheduling, tail handling, bounds, ownership and scope;
required binding the actual paced input, fatal UBSan handling, complete compiler
arguments and labeling frame delivery separately from audible playback. These
were fixed and re-reviewed with no remaining experiment blocker. The report
fingerprints code, executable, browser modules, compiler commands, pinned source
commits and timed input before/after measurement. RSS is whole-process high-water
usage including fixture/driver/statistics, not an isolated engine allocation.

The owner retains final style/direction choices and acceptable added delay.
Native-core success still requires a safe Rust/C++ boundary, packaging and both
clients' real call/teardown/failure tests before the joint browser/TUI release.

Native cadence outcome on this Apple Silicon Mac: all four independent 60 s runs
passed with zero starvation, overflow or missed 20 ms release/delivery periods.
Per-frame compute p95 was 1.40–1.75 ms; worst observed frame 4.09 ms. Whole-process
peak RSS was 4.45–4.48 MiB, versus roughly 3.2 MiB high-water before core creation.
The core/queue delivery delay remained 240 ms with default prefill; device/call
latency is additional. The experiment executable is 116,152 bytes (46,395 gzip),
linked only with macOS libc++ and libSystem; this is not a packaged TUI size claim.
Current evidence removes an obvious native-core resource/cadence concern, not
the remaining Rust integration and platform/call validation work.

`results/native-cadence.json` and `native-cadence-browser.json` retain the raw
measurements/provenance and boundary failures. The generated visual summary at
`tmp/voice-dsp/native/report.html` was checked at desktop/mobile widths (the wide
table scrolls within its container). Offline harness tests passed 50/50, including
14 new cadence-gate cases. No production helper/protocol/call behavior changed;
the next bounded experiment is an isolated safe Rust/native bridge.

### Owned Rust bridge and internal TUI call slice (2026-10-27)

Owner approved building the bridge and starting product integration. Mini-pass
inventory: **extract** the C++ ownership boundary into a third workspace crate
`randos_voice_native`, keeping the helper's unsafe ban and existing Rust/WASM
crate intact; **link** unchanged pinned MIT headers statically with existing
build dependency cc, avoiding downloads or a sidecar; **merge** legacy/native
selection in the worker's `Voice` path, rejecting accidental stacking; **leave**
server policy, channel/Port protocol, product controls, browser production audio
and call health timers unchanged for this first slice. There is no third media
worker. Style direction/labels, acceptable added delay and public controls remain
owner decisions before joint browser/TUI release; internal masking defaults off.

Strong advisor approved the narrow owned-context approach and reviewed unsafe
lifetimes, Send/non-Sync, exception containment, fixed queues and failure paths.
Native C++ state is per owner with no globals, constructors/process catch all
exceptions behind a noexcept ABI, and only `voice-native/src/ffi.rs` permits
unsafe. Rust slice checks protect pointer lengths/lifetimes; Drop frees once.
Send is justified by moving the existing session onto its worker; Cell prevents
Sync. The safety audit and dependency/license rationale live in
`voice-native/README.md`. All crates inherit workspace lints.

The advisor caught a privacy-sensitive ordering issue: gating after buffered DSP
could replay preconnection/muted speech after reconnect/unmute. Native input now
requires existing connected/unmuted flags. Gate closure immediately resets core,
partial batch and output queue, even between frames; opening discards capture
ring and resampler history before re-priming. Capture/AEC continue draining and
RTP sends silence during mute/startup. No new server/client health policy is
introduced. Initialization/processing failures use the existing call-error path;
Stop drops state without tail flush. Unit sentinel tests exercise all styles,
repeated eligibility changes and short mute transitions without a capture frame.

A second advisor finding aligned live gain with the browser: fixed ×.25 input
headroom belongs outside the raw core, with out-of-range output producing a
sticky error and silence rather than clipping or dry fallback. Transient and
deliberate overload tests cover both behaviors. Independent-instance/reset,
invalid-input and finite-finish tests guard the safe API. Fatal ASan/UBSan ABI
tests cover output bounds, distinct owners, destruction and sticky errors, and
the subprocess is owned by stdin EOF. Native checks include these and byte/pin
verification of vendored headers. New local research command
`just voice-bridge-check` verifies both raw and causal Rust rendering against
saved browser PCM: 40/40 speech/tone comparisons pass; six boundary rows retain
the same three known impulse differences in both modes.

Actual local WebRTC/Opus tests exercise resonance-only and resonance-plus-pitch,
continuing RTP/silence while muted, processed frequency and useful audio after
unmuting. Device-free capture tests verify queued/partial frames and 44.1 kHz
resampler overlap are discarded on reopening. Default unmasked/legacy behavior
is preserved. `CallConfig::masking` is internal only, with no environment, Port
or UI switch. README/contributor/operator/privacy/call-flow docs were checked and
updated; release archives now retain both upstream MIT notices. Linux builds need
C++17 and runtime libstdc++; Phoenix-only deploys remain unchanged.

The 10,560-sample returned-frame prefix and 240 ms end-of-capture delivery
timestamp describe different coordinates of the same buffering, not additive
delays. Browser production integration, optional local product audition, public
style controls, Linux qualification and real-device/AEC/cross-client call checks
remain before release. This slice does not claim that a usable masking option
has already shipped to either client.

Final checkpoint: `just precommit`, `just voice-bridge-check`, full `just smoke`,
`just tui-smoke` and `just tui-release` exited 0. Post-headroom real-call tests
passed; final ABI hardening checks finite/representable output before f32
conversion and exercises extreme finite input under sanitizers. Native checks,
parity, terminal smoke and packaged-archive checks were repeated after that fix.
The archive runs its helper and contains both MIT notices. The context graph
was refreshed. The next product slice is public style selection/local audition
and browser production wiring, with both clients qualified before release.


### Joint browser/TUI product integration (2026-10-27)

The two owner-approved candidate families are selectable in both clients:
Changed tone (strong resonance alone) and Changed tone + gentle pitch (one
semitone), each with Fuller/Brighter direction. Labels remain provisional until
product listening. Fresh sessions start Off; choices live only in RAM and freeze
per call. Browser preview and TUI `b` / `p` monitoring require explicit action,
warn about headphones/delay, and stop before calls, on changes and on exit.

Focused feature/setting/Port quality inventory and advisor outcome:

| Item | Decision | Reason |
| --- | --- | --- |
| Browser adapter and bounded bridge | Extract/reuse | Lab and production share audited mechanics; production disables fixture capture |
| Native processor and helper Voice owner | Reuse | One owner per call/audition; no third media worker or callback allocation |
| Browser production assets | Link | Same-origin digested worker/worklet, embedded pinned WASM and upstream licenses |
| Helper Port | Extend/document | Optional masking plus explicit capability check prevents old helpers silently sending dry audio |
| Participant channel and call health | Leave | Local voice choices never enter signaling; server remains timing authority |
| Persistence | Leave absent | No voice setting in cookies, localStorage, TUI config or server state |
| README, contributor, operator, privacy, call flow docs | Update/link | Public controls, resource behavior and build requirements now differ |

Advisor required cancellation ownership before awaits, current PC/ICE gating,
early microphone-loss listeners and additive delay accounting; all addressed.
Every gate closure discards queued speech. Reopening uses fresh DSP/source state;
errors stop the call instead of falling back to raw audio. Browser attaches one
stable processed track from the start. The conservative prefill adds roughly
220 ms at frame cadence, subject to device and transport delay; it is not a
whole-call latency guarantee. Shorter-buffer results must be regenerated when
shared mechanics change. Three known native/browser impulse discrepancies stay
open; complete cached speech/tone parity does not prove privacy or phone speed.

Release decisions still belong to the owner: final labels/default preferences,
acceptability of delay on actual hardware, and whether both styles should ship.
There is no deployment authorization in this checkpoint. Local product listening
comes next; the lab and prior reviews remain dev-only.


Validation at this checkpoint: full `just precommit`, `just smoke` and
`just tui-smoke` passed, including masked browser/TUI calls in both offer/answer
roles and masked TURN recovery. `just voice-bridge-check` passed all 40
speech/tone comparisons while reporting the six diagnostic rows for the three
known impulse cases. `mix assets.deploy` passed; digested/minified worker retains
all upstream notices (about 113 KiB worker plus 5 KiB worklet, before compression).
`just tui-release` built and checked the macOS archive with both MIT notices.
Desktop/light and mobile/dark controls were visually checked with no horizontal
overflow. Tidewave runtime evaluation on the local development server responds.
Linux CI, Safari and physical-microphone/low-end-device masking qualification
are not established by these local checks.


### Compact product controls and keyboard help (2026-10-28)

Focused user-visible-feature mini-pass: **reuse** the TUI's contextual shortcut
lists for full help and derive a shorter footer; **leave** participant model,
protocol, timing and audio behavior unchanged; **keep** help ownership/scrolling
in App's local presentation state. Help wraps by terminal cell width, consumes
paste/keys, clamps after resize and closes on server connection/status changes.
The join-link prompt keeps literal question marks. The voice panel has its own
help context. Advisor reviewed scope and these ownership/resize requirements.
His two final small-terminal findings were fixed: composite exit keys remain
visible, and underlying voice popups cannot cover help navigation.

Homepage: **merge** voice settings into the existing conversation card as a
collapsed disclosure; **remove** the intervening grid wrapper that broke mobile
ordering; **leave** the existing standalone voice form/hook/IDs and audio owner
in place. The owner then chose a centered single-column layout with thin
horizontal progress pills above the setup card. The larger sidebar and its
visible descriptions are removed; descriptions remain available to assistive
technology, and the active pill has aria-current. Hearing-language chips now
start collapsed, retaining the selected-language summary. Closing voice
controls stops active or pending audition;
the collapsed summary shows the chosen style. README and contributor guidance
updated; self-hosting has no new commands, settings or operator requirements.
These are UI changes authorized by the owner; neither choice persistence nor
call policy changes. Desktop/mobile visual inspection and existing integration
suites cover the resulting layout and media cleanup.


### Desktop voice controls and explicit locale selection (2026-10-28)

Owner requested horizontal desktop expansion and explicit TUI language choice.
Focused mini-pass: **reuse** native details, separate forms, VoiceSettings owner,
locale availability and App.apply_model/Connection.set_locale/settings path;
**leave** signaling, audio processing and server call policy unchanged. CSS
`:has()` progressively enhances the open idle/join card into two columns, with
logical borders and unchanged DOM order; mobile and unsupported browsers stack.
Chevron direction matches each layout. Invite has distinct gray-disabled and
teal-enabled fills. The local-preview delay sentence now describes hearing
oneself, rather than an unspecified playback delay.

Language picker cursor belongs to the existing pure Tui.Model, is excluded from
saved settings, and changes the real locale only on Enter. App gives it keyboard
ownership over media shortcuts; paste is ignored, help is contextual, and
connection/status changes cancel pending choices. Native List selection keeps
its cursor visible across resize; names use channel-provided endonyms with code
fallback. Advisor reviewed scope, RTL borders, modal precedence and cancellation.
The final review caught a Paragraph-only popup reordering clause: Lists now
reuse the existing RTL item/title treatment, with a selected-row regression
for a short non-reordering terminal.
README, contributor guidance and the dated translation plan link describe the
new controls; no new hosting configuration, protocol fields or privacy claims.


Owner's follow-up label choice: masking styles are now **Tone** and
**Tone + Pitch** in both clients; preset values and Off are unchanged. Interface
language remains saved only on explicit picker confirmation.


### Multilingual popup physical redraw (2026-10-28)

Reproduced owner-reported leftover `BN)` / `दी` in VHS after l then Esc.
Native TestBackend draws the correct logical frame and missed this physical
cursor-width mismatch. **Leave** native endonyms, locale persistence and audio
unchanged; **extract/reuse** reply_with_redraw for multilingual overlay transitions;
**patch** the existing ExRatatui renderer at its screen/backbuffer boundary.
Advisor rejected raw ANSI erase and queued blank frames: they desynchronize the
retained cells or get coalesced away. A colored popup experiment erased text but
left a border fragment; reverted. The pinned dependency patch requests
physical clear plus cache reset in the same serialized draw, preserving requests
through coalescing. UI colors remain unchanged.

Build consequence: the renderer NIF is now source-built with explicit build-only
Rustler, locked native dependencies and integrity guard; archive carries its MIT
license and prefetch avoids unpatched binaries. README/development/self-hosting
checked: no runtime/operator setting changes, but TUI contributors need the
pinned Rust compiler already used for the media helper. Before release qualify
Linux/macOS archives plus Safari/browser masking, and conduct short real calls
in all client pairings; no additional DSP or recognition-attack experiments are
release gates. After that, resume small lab comparisons while retaining these
baseline styles.


Renderer follow-up validation includes atomic-clear/backbuffer tests plus real
VHS pixel equality on popup dismissal. Dependency guard is in precommit and the
weekly advisory job. Source audit fixed the upstream pulldown-cmark advisory by
pinning 0.13.5; upstream bincode/yaml-rust maintenance notices remain warnings,
with vulnerabilities still fatal. Clear or draw failure retains the pending
redraw request. The TUI archive is checked after building the patched NIF.


Owner's final presentation tweaks: Find a rando and Invite someone share equal
button sizing, appear side by side from the small-screen breakpoint upward,
and stack on phones. Enabled buttons share the slight hover lift and focus ring;
disabled buttons stay still. Preview copy keeps the recording/upload statement and
omits the delay sentence in both clients; processing and latency are unchanged.
Existing component/hook ownership, call actions and operator guidance stay valid.


Homepage masking refinement: Fuller/Brighter appears only after selecting Tone
or Tone + Pitch. Off hides/disables that control and lets Style fill the row;
re-enabling preserves the selected tone. This reuses the existing hook's state
synchronization and changes no DSP, call, persistence or operator behavior.


Masking summary now includes both style and tone (Tone + Fuller/Brighter, or
Tone + Pitch + Fuller/Brighter); Off stays Off. The translated summary wraps on
narrow panels so its direction remains readable. Presets are unchanged: both
resonance directions use the strong magnitude, optionally with ±1 semitone.


Voice controls presentation: an authored waveform uses the existing icon/mask
pipeline (no runtime fetch or dependency); compact teal headphone information
and muted red recognition warning keep the established palette. Both are static
notes, not live alerts. Microphone status uses monospace and Off no longer adds
an instruction to choose a changed voice. Existing IDs, labels and audio-owner
lifecycle are reused; processing, controls, persistence and hosting stay unchanged.


### Focused pass: preview continuity and homepage shortcuts (2026-10-28)

Triggered by a new user-visible control. Inventory: leave the existing call
masking factory and its fail-closed ownership unchanged; extract an explicit
original-preview branch because Off is an owner-approved listening choice;
retain the microphone while replacing separately versioned preview pipelines;
link keyboard actions to existing buttons so validation and cleanup stay shared.
The advisor reviewed this ownership split and input guards. Owner decisions:
Off during preview keeps playing original; initial shortcuts cover Find, Invite,
Preview and Mute. Help has a visible button and native dialog, actions are opt-in
in page memory, and form fields suppress keys. README/development describe the
changes; self-hosting has no new setting, service or resource requirement.

Advisor outcome: no blocking findings in dual-generation preview ownership or
keyboard input guards. The browser regression exercises continuous raw capture,
explicit Off monitoring at matched gain, latest settings after pending permission,
retired worker faults, microphone loss and queued cleanup. Repeated baseline
unmasked and masked ICE failures were isolated to host mDNS resolution; the
hermetic Chrome launcher disables candidate mDNS (already used by the TUI bridge
harness). Advisor confirmed relay-only policy and recovery assertions remain
valid; production browser behavior is unchanged.


### Focused pass: expanded homepage shortcuts (2026-10-28)

Inventory/advisor outcome: leave consent validation, native disclosure and media
ownership in their existing controls; extend HomeShortcuts by clicking them or
cycling enabled options with one change event. No new media state or policy.
Owner-approved additions are A acknowledgment, B voice disclosure, P/M preview,
and S/T modification choices. Panel-only actions cannot alter hidden settings;
M prioritizes call mute. Help includes Esc and omits prose about expected form
keyboard behavior. README/development updated; self-hosting needs no changes.


### Focused pass: continuous TUI voice audition (2026-10-28)

Triggered by a new local Port command and user-visible behavior. Inventory:
leave capture/playback device ownership in Loopback; extend its existing worker
with coalesced masking updates; retain the pure State effect boundary; distinguish
silent meter and audible audition modes. The advisor required a separate
live-audition capability so old helpers cannot pretend to apply changes. Local
Port docs and both encoders/parsers are updated; participant signaling and call
obligations do not change. The owner requested parity with continuous browser
preview, including explicit Off monitoring. Stop/Esc/call transitions retain
cleanup. Old local output is allowed to drain, with a bounded queue and brief
re-priming, rather than adding a callback reset mechanism. README/development
updated; self-hosting adds no service or setting.


Owner refinement: homepage help is now an inline TUI-style keycap panel beneath
the main card. Showing it enables letter shortcuts; `?` or Esc hides/disables
them. Removed the separate enable checkbox and native dialog. The existing
input guards remain; actions work while the panel is visible and DOM hints
follow validation, disclosure and call updates without stealing focus.
Advisor found stale old helper events/replies could affect a restarted TUI
preview. Local audition generations now scope start/update replies and all
loopback events, including cross-mode meter replies; dedicated regressions cover
those races. Playback remains a documented bounded local drain.


TUI microphone meter correction: its stop hint reads the audio mode, showing
`p` for voice audition and `t` for the silent mic test. The existing render
regression checks both. No key bindings, media lifecycle or operator changes.


Shortcut-bar layout refinement: align its width/edges with conversation-card,
including the desktop voice expansion, and remove automatic scrolling. Showing
help reveals it in place without moving the viewport or focus. Browser checks
cover both card widths and unchanged scroll position.


### Focused pass: compact homepage navigation (2026-10-28)

Inventory/advisor outcome: extend the shared layout with a home-only variant,
leave navigation/locale/theme controls and stable IDs shared, and retain the
normal branded header elsewhere. Home has one hero brand, a desktop inline-end
rail with a matching content inset, and a mobile toolbar. Logical spacing mirrors
in RTL; locale hiding during calls is retained. Advisor called for overlap,
zoom/narrow-width and locale-menu bounds checks and an accessible label after
removing the shortcut bar's visible title/dot. Voice notes are subdued, with the
recognition caveat unchanged and the shorter headphones recommendation. Owner
approved these presentation changes; media behavior and shortcut activation are
unchanged. README/development checked; self-hosting has no new setting/service.

Advisor follow-up caught the fixed locale menu overflowing short viewports.
At short desktop heights navigation returns to normal flow; the home locale
menu is bounded to available viewport height. Browser regression includes a
1200×400 open-menu check alongside desktop/mobile and RTL bounds.


### Homepage laptop-fit refinement (2026-10-28)

Owner refinements restore horizontal navigation while keeping the hero high;
remove rail-only sizing/inset CSS, compact page gaps and shortcut padding, and
move the philosophy line from hero to the right-aligned home footer. Escape is
visibly described as Hide shortcuts beside the outer toggle, freeing the panel's
top for key hints. Hidden Close is focus-safe and uses preventScroll. X clicks
the existing Stop looking control only while available, with no new queue policy.
Advisor reviewed toolbar/RTL overlap, footer wrapping, Close focus ownership and
viewport-based fit. Browser regressions cover 1366×768 with masking closed/open,
existing mobile/RTL/menu bounds and X canceling search. README/development updated;
self-hosting has no new requirement.


Homepage letter shortcuts now accept lowercase and uppercase, including
Shift+letter and Caps Lock. Existing Ctrl/Command/Alt, composition, repeat,
editable-field and availability guards remain. Browser checks exercise shifted
preview/acknowledgment actions, uppercase without Shift, lowercase, and protected
modifier combinations. No bindings, UI controls or media policy changed.


### Focused pass: site shortcuts and legend design (2026-10-28)

Owner requested About/Status/language keys and external UI advice to contain the
legend's growth. UI review recommends three compact columns with short labels.
Outcome: Conversation (A/F/I/X), Voice (B/P/S/T, M during calls), Site (O/R/L).
P becomes the single preview key; duplicate V and preview-M aliases are removed.
Inventory/advisor outcome: reuse existing links, locale form and media button;
leave call/queue policy on existing owners. Language menu owns letters and its
first Escape, focuses the current choice, and keeps arrow movement separate from
submission. In-call hidden language control remains unavailable. About/Status
retain the same availability as their visible links; navigate through the
normal hook teardown. Tests cover real locale POST, active/pending preview
cleanup on navigation and unchanged laptop fit. README/development updated;
self-hosting adds no settings/services. No owner decision remains pending.

Native locale submission exposed a pre-existing preview forwarding issue:
cleanup can resolve during the original native submit's microtask checkpoint,
when re-entry is ignored. Shared forwarding now schedules a new task after
cleanup and verifies hook/target ownership. The zero-delay scheduling boundary
is client DOM work, not server call-health policy. Real locale POST and original
preview→Invite tests cover the behavior. Hidden locale disclosures also cannot
capture Escape after their control disappears during a call.

Follow-up advisor guards: deduplicate pending forwards, keep interception active
while cleanup is pending, and invalidate the prior intent when preview restarts.
Deferred activation checks session identity, hook/target ownership and submitter
membership before using its temporary bypass. Regressions hold context closure
to exercise repeated submits and restart-before-navigation explicitly.


### Focused pass: local shortcut preference (2026-10-28)

Owner requested an ever-opened local flag to restore shortcuts after About,
Status or interface-language changes. Leave all action/visibility ownership in
HomeShortcuts; add a guarded localStorage boolean, plus RAM fallback for the
same page runtime if storage fails. Exactly `1` restores; opening latches it;
Escape hides only this visit. Restore through setOpen without focus, scroll or
microphone activation. Advisor reviewed storage-failure and restoration bounds.
README/development/privacy now describe this local-only display preference;
self-hosting adds no service/configuration. Browser tests exercise real reload,
LiveView return, active restored keys and zero microphone capture on restore.
The v1 masking scope remains the existing presets. The owner subsequently
confirmed a successful real Mac–iPad browser call; a real TUI call remains
a separate release check.


### Focused pass: browser in-call shortcuts (2026-10-28)

Owner confirmed the real Mac–iPad masked call works, then requested End and
Next shortcuts. Leave HomeShortcuts as the sole key dispatcher; add E/N entries
that click the existing buttons, preserving call policy, cleanup and all key
guards. Keep them in the contextual Conversation group (its home-only rows
hide during calls); no additional layout group is needed. Advisor endorsed
existing button routing and requested invitation, visibility and laptop-fit
coverage. Browser regressions exercise real end/next transitions, both cases,
hidden/modifier/repeat gates, invitation Next absence and microphone cleanup.
README/development updated; self-hosting is unchanged because this adds no
operator setting or service. No owner decision remains pending.

### First voice-masking release: translation gate (2026-10-28)

Owner explicitly requires updated translations before the joint browser/TUI
release. Catalog extraction alone does not satisfy this gate: translate new and
changed public strings in both clients, review the results (including masking
styles, privacy caveats and keyboard help), and check translated layouts before
cutting the release. Run the site's and TUI's incremental translation updates
once the English copy is settled and the owner authorizes the local model run.


### Pre-packaging full pass for v0.10.0 (2026-10-28)

Native CI follow-up (2026-10-29): **fix** the renderer source inventory, which
included an upstream `erl_crash.dump` excluded by Git. A local ignored copy hid
the mismatch. Preserve its provenance as an explicitly excluded upstream file,
reject crash dumps in the source inventory, and validate against a clean Git
export. The strong advisor approved this focused correction; runtime behavior
and the seven-file renderer patch are unchanged. Repeat CI before tagging.

A second Linux CI finding exposed test-worker shutdown: detached
`std::cin.get()` holds a stdio lock while glibc's normal exit needs it. A minimal
GCC reproduction reaches the end of main but hangs; a raw pipe read exits
normally. **Fix** the watchdog in the sanitizer and experimental native probe
using POSIX reads (retry EINTR, exit on owner EOF/error). Preserve normal main
return/destructors and fatal sanitizer exit checks, plus the 15-second deadline.
The strong advisor approved both focused changes; product DSP is unchanged.

The repeated Linux WORLD fixture starvation triggered a focused timing review.
The adapter's output spans and drain are contiguous in an isolated check;
compute overload versus scheduling remains unproven. **Add** numeric fault
diagnostics (audio/wall clocks, queue counters and compute totals) before
changing any buffering, deadline or pass criterion. No PCM enters diagnostics.

Owner approved separating WORLD research performance from release qualification
(2026-10-29): Signalsmith remains strict at the actual 48 kHz callback rate.
WORLD retains the real bridge/offline-reference PCM, span, complete-tail and
bounded-queue assertions under a deliberately slowed fixture clock. Its
separate 48 kHz run may report only a diagnosed sustained-compute starvation
as experimental overload; all other errors and teardown failures remain fatal.
CI measured roughly 94 ms per 80 ms WORLD output hop. A larger buffer would
postpone that sustained overload. The strong advisor reviewed this separation;
no WORLD algorithm, production buffering or privacy behavior changes.

Clean-checkout CI then exposed a live-preview test depending on ignored
comparison WAVs. **Extract** the identical generated WAV helper from the engine
and gentler-pitch UI tests, and reuse it for live-preview's prepared comparison
handoff. **Leave** real DSP/microphone/failure/cleanup paths unchanged. The
advisor approved this test-isolation correction; all three tests pass with
unmocked prepared audio unavailable. README/self-hosting need no change because
this adds no product behavior or operator setting.

Owner authorized preparation through the point immediately before pushing and
tagging the release. Proposed inventory and advisor outcome: **leave** the
shared DSP/FFI bridge, bounded media queues, server-owned call policy and
existing button/Port routing; their failure gates and tests justify no broad
refactor. **Link** release notes and validation evidence to the current product
scope. **Fix** stale native/renderer comments, exclude development certificates
from Docker context, and qualify fresh production output rather than reused
dev assets. README, development, self-hosting, protocol and privacy descriptions
were checked. The advisor found no demonstrated raw-audio fallback.

The TUI version is prepared as 0.10.0. Release notes live in
`docs/releases/v0.10.0.md`; the tag workflow uses the matching notes file when
present. Packaging includes both Signalsmith notices and the patched renderer
license. A clean staged production artifact is checked for lab modules, lab
bundles and development credentials. Direct Mix builds need the same clean-tree
care, now described in self-hosting.

The dependency audit surfaced Bandit 1.13.1 and development-only Tidewave 0.9.1
advisories. Update to Bandit 1.14.1 and Tidewave 0.9.2 inside existing constraints;
retain WebSock adapter 0.6.0 to keep this remediation focused. Rebuild and rerun
call/recovery checks against that lockfile.

Dependabot disposition: apply #14's webpki-roots 1.0.11 trust-store patch and
#16's independent Tailwind 0.5.2 downloader fix locally. #15 and #16's Hex
renderer changes are superseded by the current path dependency; their green
CI covers the older dependency arrangement. Keep the patched 0.17.1 renderer
for this release. Follow up by rebasing the seven-file patch onto 0.18, updating
provenance/native lock, and repeating physical redraw and both-platform package
checks. #10 requires its isolated voice-model comparison after translation
models stop. Remote merges/PR cleanup are deferred while the release tree is
unpublished; do not restore an unpatched Hex renderer to clear those PRs.

Release validation in progress: incremental translations for both catalogs,
model checks/picks and translated layouts; final precommit/browser/TUI smokes;
macOS and Ubuntu 24.04 x86_64 archives; clean production artifact inspection.
The TUI recovery scenario now covers both original and masked audio, with
different styles on each peer and non-silent received audio. Owner approval
is still required before release push/tag/publication.


Packaging follow-up: repeated Mix release assembly retained obsolete app and
dependency directories (including old TUI versions and Bandit 1.13.1). Remove
only the owned assembled TUI release before assembly, retain compiler caches,
and reject duplicate app versions in the unpacked archive. The advisor endorsed
this targeted fix; a seeded obsolete directory was absent from the rebuilt
macOS archive, whose CLI/helper checks passed. Fresh production assembly also
contains only Bandit 1.14.1 and excludes Tidewave, labs and development keys.
Docker context also excludes local archives and graph caches. Production TURN
checks passed after the webpki-roots update.


Release environment checks: the actual production Docker image passes the
voice-product browser suite; dev lab and Tidewave paths return 404, and the
image contains no development credentials. The Ubuntu 24.04 x86_64 archive
passes CLI/helper checks and loads its source-built renderer in a fresh runtime.
Local cross-architecture validation uses Clang and Erlang's documented
`+JMsingle true` QEMU workaround only in disposable images; shipped defaults
are unchanged. A temporary VM swap file allowed the unmodified release profile
to compile and was disabled/removed afterwards. Native GitHub Linux CI remains
the final platform check after the authorized push and before tagging.

The advisor approved caching both Cargo workspaces (root and renderer) in CI
and release jobs, retaining standard toolchain/lockfile keys. First translation
passes completed for both catalogs; all 40 website desktop/mobile layouts and
120 TUI locale/layout cases passed. Visual QA caught Fuller being treated as
a name. Add translator usage comments and do one context-only incremental retry
for ambiguous timbre/preview labels; keep the established model picks and any
English fallback rather than hand-filling a rejected translation.


Final maintenance outcome: the original #10 dependency set resolved but failed
TorchAudio import against Torch 2.8. TorchAudio 2.11 requires Torch 2.11 or newer.
With Torch 2.11 pinned, the isolated current-protocol passthrough comparison
(20 speakers, 60 trials, cached weights) preserved both EERs, both identification
scores and WER exactly. The compatible model updates and compact evidence in
`tools/voice-eval/results/dependency-check.json` are included; all 50 offline
harness tests passed. This establishes equivalence only for the tested setting.
The advisor confirmed the dependency scope. The remaining release sequence,
translation fallbacks and PR dispositions are in `docs/releases/v0.10.0-readiness.md`.


### Post-release guidance and conversation preferences (2026-10-29)

Owner requested a current AGENTS guide and cross-tab language preferences for
the browser session, plus a speaking-language cycle shortcut. **Link** detailed
setup/workflows from a shorter root guide; preserve generated usage-rules/Trail
content exactly. The old guide exceeded Codex's default 32 KiB instruction
budget. **Move** machine-local code-intelligence setup to development docs.
**Leave** release checks, product/privacy boundaries and protocol ownership intact;
use strong review for substantive risk, cheaper bounded work when delegation helps.
The strong advisor reviewed the guide and this scope.

**Add** C/c through the existing select/change shortcut path and one language-only
session-cookie hook. **Leave** form validation and invitations server-owned,
without a new endpoint, call policy or protocol obligation. Restore once on form
mount, synchronously update controls and send one existing preference event.
Only language changes save; a stale tab's age checkbox cannot overwrite another
tab's preference. Session cookies may be restored by a browser; the owner does
not require guaranteed restart deletion or persistence. No microphone, masking,
age acknowledgment or participant ID is stored. README/development/privacy are
updated; self-hosting needs no change because there is no operator setting.

The next lab work should first address the advisor's demonstrated runtime
worklet-failure cleanup gap and misleading feedback when an already-saved review
is cleared. Preserve append-only review history; agree on withdrawal semantics
before changing saved-review meaning. No broad product DSP/FFI refactor is justified
by the completed release review. Add an experiment registration checklist before
extending the next DSP comparison; current provenance machinery remains useful.


### Lab review withdrawal and runtime preview cleanup (2026-10-29)

Owner chose withdrawal when all review fields are cleared. **Extend** the
existing append-only record with optional `withdrawn: true` only for empty
ratings and literal empty notes; normal records remain compatible. **Leave**
user history intact. The latest append for the full exact context determines
current judgment, and a withdrawal suppresses prior entries until reactivation.
The browser persists a submission marker before sending, so an empty edit made
while the first save is in flight still resumes as a withdrawal after reload.
Signature/status checks share canonical payload construction; failed withdrawals
remain visible and retry. No new reader abstraction, database or ordering policy
is added; cross-page request ordering remains best effort.

**Merge** legacy and DSP-preview failure ownership in the lab controller, and
**fix** the missing legacy runtime `processorerror` handler. Close capture and
context before reporting, including Original monitoring, and ignore retired
errors. The strong advisor approved the focused design and race coverage.
README/development/privacy describe the feedback contract; self-hosting and the
public README need no additional changes for these dev-only fixes. Product DSP,
Participant/Port contracts, masking presets and production bundles are unchanged.

The implementation review reproduced one further confirmation race: restoring
an exact earlier answer while withdrawal is pending, then reloading, could trust
an obsolete saved signature. Invalidate that signature before each new POST;
restore it only on acknowledgment. The regression requires a reactivation POST
after reload. Conservative retries may append another valid revision; they do
not silently claim a stale answer is current.
