# randos — current architecture and roadmap

Verified against the v0.10.1 source (following published `f81f03d`), the local
width/source auditions, documentation split, native latency reduction and owner
TUI listening check on
2026-10-31. This file describes current ownership
and active work; update the Verified line when either changes. The complete
[previous roadmap and decision history](2026-10-31-roadmap-history.md) is preserved
as evidence, including plans that were superseded.

## Product and shipped state

The [product requirements](../../README.md) are authoritative: anonymous,
audio-only language practice; no accounts, recording, server-side audio,
persistent social graph, tracking, ads, paid features or video. Live participant
and call state stays in processes. Aggregate status files are a separate,
privacy-filtered exception described in [privacy](../privacy.md), not a user database.

Browser and standalone TUI calls, invitations, translations, reconnect/recovery,
and local Signalsmith voice masking are shipped. Masking is a modest, pleasant
voice disguise, not strong anonymity: prioritize naturalness, intelligibility,
expression, low latency and conversational comfort. Known-recording and recovery
attacks document limitations; their scores do not decide whether a mask is useful.

## Current architecture

| Owner | Responsibility |
| --- | --- |
| Pure `Randos.Participant` | One person's flow, returning state and effects |
| `RandosWeb.ParticipantShell` | Executes effects for LiveView and the public participant channel |
| `HomeLive` / `HomeComponents`, `ParticipantChannel` | Transport/UI shells; render shared server policy |
| `Matchmaking.Matchmaker` | Oldest-compatible queue, recent-pair exclusion and hashed-token invitations |
| `Calls.CallCoordinator` (`:gen_statem`) | Per-call lifecycle, health/recovery, monitoring, votes and signal relay |
| `Calls.Lifecycle` / `Calls.Call` | Pure call rules, public state and timing constants |
| `Randos.Signaling`, `RandosWeb.IceServers` | Signal validation/filtering and per-call TURN configuration; never audio |
| Browser media / Rust TUI helper | Local devices, WebRTC transport, echo cancellation and capture lifecycle |
| Signalsmith WASM / `voice-native` | Same pinned DSP core/settings, owned locally by each media path |
| `RandosWeb.Status.snapshot/0` | Shared JSON-safe status; merge counters before small-count privacy filtering |

Production calls require the relay by default; the server filters direct
addresses. `RANDOS_ALLOW_DIRECT_CALLS=true` is an explicit operator exception,
not the default architecture. The server does not decrypt/process call media.
Matchmaking is node-local: scaling it across nodes requires a deliberate design.

Masking starts off, stays local and freezes the selected profile for a call.
The browser owns a Worker/AudioWorklet and stable processed track. The TUI's Rust
helper uses the safe owned Signalsmith bridge after echo cancellation and before
Opus. Mute/disconnection/Stop purge queued speech; failure withholds/stops capture
rather than sending an unmodified fallback. Preview is explicit, never uploaded
or recorded. Lab processors and model bundles remain development-only.

## Authoritative documents

| Question | Current source |
| --- | --- |
| Product scope | [README](../../README.md) |
| Call/transport architecture | [Call flow](call_flow.md) |
| Messages and client obligations | [Participant channel](participant_channel.md) |
| Privacy and published aggregates | [Privacy](../privacy.md) |
| Relay/operations and deployment | [Self-hosting](../self-hosting.md), [coturn README](../../infra/coturn/README.md) |
| TUI usage/configuration | [TUI README](../../clients/tui/README.md) |
| Native media and Port contract | [Helper README](../../clients/tui/native/README.md) |
| Native Signalsmith boundary | [voice-native README](../../voice-native/README.md) |
| Rust DSP/research core | [voice README](../../voice/README.md) |
| Translation procedure | [Catalog guide](../../priv/gettext/README.md), [translation tooling](../../tools/translate/README.md) |
| Setup, MCP, checks, releases | [Development](../development.md), [agent guide](../../AGENTS.md) |
| Lab experiments and evidence | Relevant [voice DSP](../../tools/voice-dsp/README.md), [FARGAN](../../tools/voice-fargan/README.md), [evaluation](../../tools/voice-eval/README.md) guides and fingerprinted reports |

Protocol and Port details have one owner; do not copy their message schemas or
policy constants here. Dated designs, audits and research files in this directory
explain decisions and evidence, not a second current contract.

## Current experiment

Two independent **Resonance width** and **Voice-source shape** auditions are in
`/dev/voice-lab`, with all four public voices and the test tone. Each compares
Original, Signalsmith, matched reconstruction and two variants, with autosaved
exact-context notes. Run `just voice-dsp-texture`; the [DSP guide](../../tools/voice-dsp/README.md)
owns algorithms, numerical controls, limitations and reproduction commands.
These prepared native/Python results are not streaming or product qualification.

Listening outcome: the owner found both resonance width and voice-source shape
too subtle, without a significant difference or improvement over Signalsmith.
The exact overall note and report/build fingerprints are preserved in
`tools/voice-dsp/results/texture-listening.json`; no per-voice ratings are inferred.
Park these implementations/settings rather than promote or combine them. The
comparison views and recordings stay available as evidence. This does not rule
out every possible bandwidth or source-shaping method.

Signalsmith remains the shipping reference. FARGAN's browser resource screen
passed, but the owner heard robotic high-voice sound and slightly preferred
Signalsmith overall. Recommend parking FARGAN integration; preserve its reports,
recordings and reviews. Other rejected/previous rounds remain evidence, not active
implementation plans. No new technique is combined or promoted before listening.

## Active work

1. Signalsmith remains the baseline; the two width/source auditions are parked
   following owner feedback. Choose a distinct, explicit hypothesis before the
   next experiment; no further parameter sweep is scheduled.
2. The owner reports the updated TUI sounds good. The subjective listening check
   is recorded in `tools/voice-dsp/results/latency-listening.json`; preview versus
   a real TUI↔browser call and device details were not specified, so do not infer
   acoustic or cross-device measurements. The owner has authorized v0.10.1
   publication after normal release qualification; follow [the release process](../development.md#releases).

## Recent verified engineering work

- Documentation now separates current authority from history. The complete
  previous roadmap body is preserved verbatim (210,683 bytes); all 73 former
  headings have forwarding targets, and all 23 old Open items have a disposition.
  Existing contracts keep their paths. This lane changed documentation only.
- Native Signalsmith prefill is one 80 ms batch rather than two. Additional
  frame offset is **140 ms**, down from 220 ms; nominal first delivery is
  **160 ms** after capture starts, down from 240 ms. No DSP/window/style change.
  Exact aligned PCM/tails match for four styles and five sources. Independent
  capture pacing, controlled stalls, sticky failure/reset checks and the real
  helper Port confirm the software-path result; codec/device estimates are
  reported separately. Small late-frame-count differences under stalls are
  scheduling variation, not proof that either queue fixes an OS stall.
- Browser prefill stays unchanged: a 12 ms injected Worker stall starved the
  shorter option; the current buffer survived 45 ms (both failed at 100 ms).
  Unlike the native sender, its AudioWorklet consumes independently.
- Focused quality decisions: **extract/reuse** the existing native alignment
  constant in the renderer, **leave** core/FFI/array bounds and browser defaults
  unchanged, **link** the [latency evidence](../../tools/voice-dsp/README.md) rather
  than duplicate experiment procedures. Strong advisor reviewed the distinction.
  No API, protocol obligation or new user setting. No new recognition-model run:
  buffer-only changes preserve the transformed PCM, so existing attack evidence
  is unchanged and does not gate this comfort improvement.

## Deferred decisions and maintenance

- Drop the recorded `RUSTSEC-2026-0387` exception when the native dependency
  chain permits it; [current advisory policy](../../clients/tui/native/deny.toml)
  owns the exception, not dated dependency-version claims.
- Multi-node matchmaking and regional relays require a separate design and
  evidence of need; current ownership does not assume production is always one node.
- Echo cancellation is enabled; additional noise suppression/automatic gain
  needs listening and actual-call evidence before choosing a default.
- Revisit vendor/upstream workarounds and coturn follow-ups at their relevant
  milestones; see [vendor provenance](../../vendor/README.md) and the dated
  [coturn audit](coturn_audit.md).
- Historical translation issues and test-timing findings are evidence for the
  next relevant change, not permission to rerun models or mask timing failures.

No push, tag, deploy, publication or external message is implied by this roadmap.

## History and compatibility links

The snapshot retains **all** former roadmap text. Its old Open items section
mixes completed, superseded and deferred work; the classification at the top of
the snapshot points to current owners. Older links below forward to their exact
historical sections, which must not be treated as current specifications.

<details>
<summary>Former roadmap headings</summary>

<p><a id="randos-roadmap" href="2026-10-31-roadmap-history.md#randos-roadmap">Archived: randos roadmap</a></p>
<p><a id="goals" href="2026-10-31-roadmap-history.md#goals">Archived: Goals</a></p>
<p><a id="status" href="2026-10-31-roadmap-history.md#status">Archived: Status</a></p>
<p><a id="how-it-fits-together" href="2026-10-31-roadmap-history.md#how-it-fits-together">Archived: How it fits together</a></p>
<p><a id="phase-4-tui" href="2026-10-31-roadmap-history.md#phase-4-tui">Archived: Phase 4: TUI</a></p>
<p><a id="41-local-dev-monitor-done" href="2026-10-31-roadmap-history.md#41-local-dev-monitor-done">Archived: 4.1 Local dev monitor (done)</a></p>
<p><a id="42-text-only-participant-client-done" href="2026-10-31-roadmap-history.md#42-text-only-participant-client-done">Archived: 4.2 Text-only participant client (done)</a></p>
<p><a id="43-audio-done-stages-0-to-3" href="2026-10-31-roadmap-history.md#43-audio-done-stages-0-to-3">Archived: 4.3 Audio (done: Stages 0 to 3)</a></p>
<p><a id="44-distribution-done-2026-10-21-v010-released" href="2026-10-31-roadmap-history.md#44-distribution-done-2026-10-21-v010-released">Archived: 4.4 Distribution (done 2026-10-21: v0.1.0 released)</a></p>
<p><a id="45-homebrew-custom-tap-done-2026-10-21-v010-is-installable" href="2026-10-31-roadmap-history.md#45-homebrew-custom-tap-done-2026-10-21-v010-is-installable">Archived: 4.5 Homebrew (custom tap) (done 2026-10-21: v0.1.0 is installable)</a></p>
<p><a id="phase-6-ui-translations-after-the-first-release-alongside-phase-5" href="2026-10-31-roadmap-history.md#phase-6-ui-translations-after-the-first-release-alongside-phase-5">Archived: Phase 6: UI translations (after the first release; alongside Phase 5)</a></p>
<p><a id="phase-5-voice-anonymization" href="2026-10-31-roadmap-history.md#phase-5-voice-anonymization">Archived: Phase 5: Voice anonymization</a></p>
<p><a id="plan-refresh-2026-10-24" href="2026-10-31-roadmap-history.md#plan-refresh-2026-10-24">Archived: Plan refresh (2026-10-24)</a></p>
<p><a id="voice-lab-usability-review-2026-10-24" href="2026-10-31-roadmap-history.md#voice-lab-usability-review-2026-10-24">Archived: Voice lab usability review (2026-10-24)</a></p>
<p><a id="first-formant-experiment-and-benchmark-corrections-2026-10-24" href="2026-10-31-roadmap-history.md#first-formant-experiment-and-benchmark-corrections-2026-10-24">Archived: First formant experiment and benchmark corrections (2026-10-24)</a></p>
<p><a id="listening-access-and-revised-evaluation-goals-2026-10-24" href="2026-10-31-roadmap-history.md#listening-access-and-revised-evaluation-goals-2026-10-24">Archived: Listening access and revised evaluation goals (2026-10-24)</a></p>
<p><a id="approximate-recovery-and-back-to-back-listening-2026-10-24" href="2026-10-31-roadmap-history.md#approximate-recovery-and-back-to-back-listening-2026-10-24">Archived: Approximate recovery and back-to-back listening (2026-10-24)</a></p>
<p><a id="in-lab-listening-reviews-2026-10-24" href="2026-10-31-roadmap-history.md#in-lab-listening-reviews-2026-10-24">Archived: In-lab listening reviews (2026-10-24)</a></p>
<p><a id="recovery-sequence-playback-2026-10-24" href="2026-10-31-roadmap-history.md#recovery-sequence-playback-2026-10-24">Archived: Recovery sequence playback (2026-10-24)</a></p>
<p><a id="brief-pauses-between-comparison-clips-2026-10-24" href="2026-10-31-roadmap-history.md#brief-pauses-between-comparison-clips-2026-10-24">Archived: Brief pauses between comparison clips (2026-10-24)</a></p>
<p><a id="first-pretrained-model-listening-probe-2026-10-24" href="2026-10-31-roadmap-history.md#first-pretrained-model-listening-probe-2026-10-24">Archived: First pretrained-model listening probe (2026-10-24)</a></p>
<p><a id="browser-feasibility-checkpoint-2026-10-24" href="2026-10-31-roadmap-history.md#browser-feasibility-checkpoint-2026-10-24">Archived: Browser feasibility checkpoint (2026-10-24)</a></p>
<p><a id="unified-listening-and-resourcerecognition-follow-up-2026-10-25" href="2026-10-31-roadmap-history.md#unified-listening-and-resourcerecognition-follow-up-2026-10-25">Archived: Unified listening and resource/recognition follow-up (2026-10-25)</a></p>
<p><a id="focused-quality-pass-voice-lab-controls-and-live-preview-2026-10-24" href="2026-10-31-roadmap-history.md#focused-quality-pass-voice-lab-controls-and-live-preview-2026-10-24">Archived: Focused quality pass: voice-lab controls and live preview (2026-10-24)</a></p>
<p><a id="decisions-2026-10-19" href="2026-10-31-roadmap-history.md#decisions-2026-10-19">Archived: Decisions (2026-10-19)</a></p>
<p><a id="plan" href="2026-10-31-roadmap-history.md#plan">Archived: Plan</a></p>
<p><a id="one-call-policy-for-both-clients-done-2026-10-20" href="2026-10-31-roadmap-history.md#one-call-policy-for-both-clients-done-2026-10-20">Archived: One call policy for both clients (done 2026-10-20)</a></p>
<p><a id="dry-pass-over-phase-43-stage-1-done-2026-10-20" href="2026-10-31-roadmap-history.md#dry-pass-over-phase-43-stage-1-done-2026-10-20">Archived: DRY pass over Phase 4.3 Stage 1 (done 2026-10-20)</a></p>
<p><a id="quality-pass-at-the-end-of-phase-43-stage-1-done-2026-10-20" href="2026-10-31-roadmap-history.md#quality-pass-at-the-end-of-phase-43-stage-1-done-2026-10-20">Archived: Quality pass at the end of Phase 4.3 Stage 1 (done 2026-10-20)</a></p>
<p><a id="quality-pass-before-packaging-done-2026-10-21" href="2026-10-31-roadmap-history.md#quality-pass-before-packaging-done-2026-10-21">Archived: Quality pass before packaging (done 2026-10-21)</a></p>
<p><a id="quality-pass-at-the-start-of-the-voice-lab-done-2026-10-21" href="2026-10-31-roadmap-history.md#quality-pass-at-the-start-of-the-voice-lab-done-2026-10-21">Archived: Quality pass at the start of the voice lab (done 2026-10-21)</a></p>
<p><a id="quality-pass-before-the-voice-lab-third-done-2026-10-24" href="2026-10-31-roadmap-history.md#quality-pass-before-the-voice-lab-third-done-2026-10-24">Archived: Quality pass before the voice lab, third (done 2026-10-24)</a></p>
<p><a id="quality-pass-before-the-voice-lab-second-done-2026-10-23" href="2026-10-31-roadmap-history.md#quality-pass-before-the-voice-lab-second-done-2026-10-23">Archived: Quality pass before the voice lab, second (done 2026-10-23)</a></p>
<p><a id="tidewave-startup-wiring-2026-10-24" href="2026-10-31-roadmap-history.md#tidewave-startup-wiring-2026-10-24">Archived: Tidewave startup wiring (2026-10-24)</a></p>
<p><a id="open-items" href="2026-10-31-roadmap-history.md#open-items">Archived: Open items</a></p>
<p><a id="decisions" href="2026-10-31-roadmap-history.md#decisions">Archived: Decisions</a></p>
<p><a id="voice-masking-goal-reset-and-sound-quality-check-2026-10-25" href="2026-10-31-roadmap-history.md#voice-masking-goal-reset-and-sound-quality-check-2026-10-25">Archived: Voice masking goal reset and sound quality check (2026-10-25)</a></p>
<p><a id="sound-check-coverage-fix-and-listening-direction-2026-10-25" href="2026-10-31-roadmap-history.md#sound-check-coverage-fix-and-listening-direction-2026-10-25">Archived: Sound-check coverage fix and listening direction (2026-10-25)</a></p>
<p><a id="model-free-dsp-auditions-and-complete-listening-matrix-2026-10-25" href="2026-10-31-roadmap-history.md#model-free-dsp-auditions-and-complete-listening-matrix-2026-10-25">Archived: Model-free DSP auditions and complete listening matrix (2026-10-25)</a></p>
<p><a id="include-the-generated-tone-in-every-modification-2026-10-25" href="2026-10-31-roadmap-history.md#include-the-generated-tone-in-every-modification-2026-10-25">Archived: Include the generated tone in every modification (2026-10-25)</a></p>
<p><a id="listening-feedback-and-automatic-review-saves-2026-10-25" href="2026-10-31-roadmap-history.md#listening-feedback-and-automatic-review-saves-2026-10-25">Archived: Listening feedback and automatic review saves (2026-10-25)</a></p>
<p><a id="world-short-window-feasibility-screen-2026-10-25" href="2026-10-31-roadmap-history.md#world-short-window-feasibility-screen-2026-10-25">Archived: WORLD short-window feasibility screen (2026-10-25)</a></p>
<p><a id="browser-dsp-adapters-and-three-way-listening-checkpoint-2026-10-26" href="2026-10-31-roadmap-history.md#browser-dsp-adapters-and-three-way-listening-checkpoint-2026-10-26">Archived: Browser DSP adapters and three-way listening checkpoint (2026-10-26)</a></p>
<p><a id="stronger-signalsmith-round-and-compact-preference-view-2026-10-26" href="2026-10-31-roadmap-history.md#stronger-signalsmith-round-and-compact-preference-view-2026-10-26">Archived: Stronger Signalsmith round and compact preference view (2026-10-26)</a></p>
<p><a id="preferred-engine-comparison-and-live-dsp-preview-2026-10-27" href="2026-10-31-roadmap-history.md#preferred-engine-comparison-and-live-dsp-preview-2026-10-27">Archived: Preferred engine comparison and live DSP preview (2026-10-27)</a></p>
<p><a id="live-review-prefer-signalsmith-complete-the-profile-palette-2026-10-27" href="2026-10-31-roadmap-history.md#live-review-prefer-signalsmith-complete-the-profile-palette-2026-10-27">Archived: Live review: prefer Signalsmith; complete the profile palette (2026-10-27)</a></p>
<p><a id="gentler-pitch-and-one-output-prefill-experiment-2026-10-27" href="2026-10-31-roadmap-history.md#gentler-pitch-and-one-output-prefill-experiment-2026-10-27">Archived: Gentler pitch and one output-prefill experiment (2026-10-27)</a></p>
<p><a id="provisional-first-options-and-future-dsp-experiments-2026-10-27" href="2026-10-31-roadmap-history.md#provisional-first-options-and-future-dsp-experiments-2026-10-27">Archived: Provisional first options and future DSP experiments (2026-10-27)</a></p>
<p><a id="native-core-cadence-feasibility-experiment-2026-10-27" href="2026-10-31-roadmap-history.md#native-core-cadence-feasibility-experiment-2026-10-27">Archived: Native-core cadence feasibility experiment (2026-10-27)</a></p>
<p><a id="owned-rust-bridge-and-internal-tui-call-slice-2026-10-27" href="2026-10-31-roadmap-history.md#owned-rust-bridge-and-internal-tui-call-slice-2026-10-27">Archived: Owned Rust bridge and internal TUI call slice (2026-10-27)</a></p>
<p><a id="joint-browsertui-product-integration-2026-10-27" href="2026-10-31-roadmap-history.md#joint-browsertui-product-integration-2026-10-27">Archived: Joint browser/TUI product integration (2026-10-27)</a></p>
<p><a id="compact-product-controls-and-keyboard-help-2026-10-28" href="2026-10-31-roadmap-history.md#compact-product-controls-and-keyboard-help-2026-10-28">Archived: Compact product controls and keyboard help (2026-10-28)</a></p>
<p><a id="desktop-voice-controls-and-explicit-locale-selection-2026-10-28" href="2026-10-31-roadmap-history.md#desktop-voice-controls-and-explicit-locale-selection-2026-10-28">Archived: Desktop voice controls and explicit locale selection (2026-10-28)</a></p>
<p><a id="multilingual-popup-physical-redraw-2026-10-28" href="2026-10-31-roadmap-history.md#multilingual-popup-physical-redraw-2026-10-28">Archived: Multilingual popup physical redraw (2026-10-28)</a></p>
<p><a id="focused-pass-preview-continuity-and-homepage-shortcuts-2026-10-28" href="2026-10-31-roadmap-history.md#focused-pass-preview-continuity-and-homepage-shortcuts-2026-10-28">Archived: Focused pass: preview continuity and homepage shortcuts (2026-10-28)</a></p>
<p><a id="focused-pass-expanded-homepage-shortcuts-2026-10-28" href="2026-10-31-roadmap-history.md#focused-pass-expanded-homepage-shortcuts-2026-10-28">Archived: Focused pass: expanded homepage shortcuts (2026-10-28)</a></p>
<p><a id="focused-pass-continuous-tui-voice-audition-2026-10-28" href="2026-10-31-roadmap-history.md#focused-pass-continuous-tui-voice-audition-2026-10-28">Archived: Focused pass: continuous TUI voice audition (2026-10-28)</a></p>
<p><a id="focused-pass-compact-homepage-navigation-2026-10-28" href="2026-10-31-roadmap-history.md#focused-pass-compact-homepage-navigation-2026-10-28">Archived: Focused pass: compact homepage navigation (2026-10-28)</a></p>
<p><a id="homepage-laptop-fit-refinement-2026-10-28" href="2026-10-31-roadmap-history.md#homepage-laptop-fit-refinement-2026-10-28">Archived: Homepage laptop-fit refinement (2026-10-28)</a></p>
<p><a id="focused-pass-site-shortcuts-and-legend-design-2026-10-28" href="2026-10-31-roadmap-history.md#focused-pass-site-shortcuts-and-legend-design-2026-10-28">Archived: Focused pass: site shortcuts and legend design (2026-10-28)</a></p>
<p><a id="focused-pass-local-shortcut-preference-2026-10-28" href="2026-10-31-roadmap-history.md#focused-pass-local-shortcut-preference-2026-10-28">Archived: Focused pass: local shortcut preference (2026-10-28)</a></p>
<p><a id="focused-pass-browser-in-call-shortcuts-2026-10-28" href="2026-10-31-roadmap-history.md#focused-pass-browser-in-call-shortcuts-2026-10-28">Archived: Focused pass: browser in-call shortcuts (2026-10-28)</a></p>
<p><a id="first-voice-masking-release-translation-gate-2026-10-28" href="2026-10-31-roadmap-history.md#first-voice-masking-release-translation-gate-2026-10-28">Archived: First voice-masking release: translation gate (2026-10-28)</a></p>
<p><a id="pre-packaging-full-pass-for-v0100-2026-10-28" href="2026-10-31-roadmap-history.md#pre-packaging-full-pass-for-v0100-2026-10-28">Archived: Pre-packaging full pass for v0.10.0 (2026-10-28)</a></p>
<p><a id="post-release-guidance-and-conversation-preferences-2026-10-29" href="2026-10-31-roadmap-history.md#post-release-guidance-and-conversation-preferences-2026-10-29">Archived: Post-release guidance and conversation preferences (2026-10-29)</a></p>
<p><a id="lab-review-withdrawal-and-runtime-preview-cleanup-2026-10-29" href="2026-10-31-roadmap-history.md#lab-review-withdrawal-and-runtime-preview-cleanup-2026-10-29">Archived: Lab review withdrawal and runtime preview cleanup (2026-10-29)</a></p>
<p><a id="selective-resonance-listening-screen-2026-10-29" href="2026-10-31-roadmap-history.md#selective-resonance-listening-screen-2026-10-29">Archived: Selective resonance listening screen (2026-10-29)</a></p>
<p><a id="fargan-first-quality-gate-and-focused-lab-navigation-2026-10-30" href="2026-10-31-roadmap-history.md#fargan-first-quality-gate-and-focused-lab-navigation-2026-10-30">Archived: FARGAN first quality gate and focused lab navigation (2026-10-30)</a></p>
<p><a id="fargan-isolated-feature-edits-2026-10-30" href="2026-10-31-roadmap-history.md#fargan-isolated-feature-edits-2026-10-30">Archived: FARGAN isolated feature edits (2026-10-30)</a></p>
<p><a id="final-combined-fargan-probe-2026-10-30" href="2026-10-31-roadmap-history.md#final-combined-fargan-probe-2026-10-30">Archived: Final combined FARGAN probe (2026-10-30)</a></p>
<p><a id="fargan-browser-feasibility-gate-2026-10-30" href="2026-10-31-roadmap-history.md#fargan-browser-feasibility-gate-2026-10-30">Archived: FARGAN browser feasibility gate (2026-10-30)</a></p>
<p><a id="independent-width-and-estimated-source-auditions-2026-10-31" href="2026-10-31-roadmap-history.md#independent-width-and-estimated-source-auditions-2026-10-31">Archived: Independent width and estimated-source auditions (2026-10-31)</a></p>
<p><a id="authorized-follow-ups-after-these-auditions" href="2026-10-31-roadmap-history.md#authorized-follow-ups-after-these-auditions">Archived: Authorized follow-ups after these auditions</a></p>

</details>
