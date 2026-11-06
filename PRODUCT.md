# Product

<!-- impeccable:product-schema 1 -->

This record captures the product direction confirmed by the owner on
2026-11-06. [README.md](README.md) remains the authoritative product
requirements; protocol, privacy and operational details belong in their
linked guides. This file does not replace those contracts.

## Platform

web

The website works in desktop and mobile browsers. A separate terminal client
participates in the same calls and must retain the same server policy. The
terminal client is not a native mobile application.

## Users

Adults, 18 or older, who want short voice conversations for language practice.
Crosstalk, language exchange, listening practice and casual conversation are
equally supported. Do not prioritize a proficiency level or force these uses
into separate modes without a new product decision.

## Product Purpose

Make it easy to meet, talk briefly and leave without building an online
identity. Success means enabling the conversation and preserving participants'
ability to leave; engagement loops, progress scores and time spent are not
product goals.

## Positioning

randos is free conversational infrastructure for the language-learning
community: a calm doorway, with short, anonymous, audio-only calls and no
accounts, profiles or persistent social graph. People can speak different
languages to each other, speak the same language, or just listen.

## Operating Context

- Choose languages you are happy to speak and hear, acknowledge the 18+ notice,
  and find a compatible stranger. Calls are unmoderated.
- Calls are time-bounded, with mutual continuation. Either participant can
  leave at any time. The [call-flow contract](docs/architecture/call_flow.md)
  owns lifecycle behavior and timing.
- One-time invitations let someone bring a person they know. Browser and
  terminal clients can call and invite each other.
- Microphone access is needed to speak. Headphones are recommended for the
  optional local voice preview.
- The browser and terminal expose connection status, language choices, mute,
  call exit and local voice masking. Recovery and call policy come from the
  server, consistently across clients.

## Capabilities and Constraints

- No accounts, profiles, recording, server-side audio access, persistent
  social graph, ads, tracking, paid features or video.
- No feeds, followers, streaks, ratings, scores or forced progress loops.
- Live participant and call state stays in processes; there is no user
  database. Privacy-filtered aggregate call counts are the documented
  persistence exception, not a history of individuals.
- Audio uses WebRTC encryption between clients. Production defaults to
  relay-only calls, with direct-address filtering. Preserve the qualifications
  and operator exceptions in [docs/privacy.md](docs/privacy.md) and
  [docs/self-hosting.md](docs/self-hosting.md); avoid broader privacy promises.
- Voice masking runs locally, starts off in a fresh session and offers a
  changed voice rather than guaranteed anonymity. Preview is explicit and
  never recorded or uploaded. Masking failure must withhold capture rather
  than send an unmodified fallback.
- First-party assets are served from the same origin. No runtime third-party
  scripts, styles, fonts or analytics.
- The interface supports the repository's established translation pipeline
  and English fallback. Machine translations have known coverage limitations.

## Brand Commitments

The name is **randos**. Preserve the plain, calm, low-pressure voice in the
README: "a doorway, not a platform." The existing logo is
[priv/static/images/logo.svg](priv/static/images/logo.svg). Follow the
repository's established interface constraints when designing; init does not
establish or replace a visual system.

## Evidence on Hand

- [README.md](README.md): public product description, workflows and constraints.
- [docs/assets/](docs/assets/): committed browser and terminal screenshots,
  including browser light and dark themes.
- [docs/privacy.md](docs/privacy.md): scoped privacy claims, retention and
  implementation evidence.
- [docs/architecture/refactor_plan.md](docs/architecture/refactor_plan.md):
  current shipped state and links to release, listening and latency evidence.

No testimonials, audience research or adoption metrics were established in
this init interview. Do not invent them or present internal audio experiments
as general claims of anonymity.

## Product Principles

1. Make entering, understanding and leaving a conversation straightforward.
2. Treat crosstalk, exchange, listening and casual conversation as equal uses.
3. Preserve ephemerality and minimize what the service learns or retains.
4. Keep call policy consistent across browser and terminal clients.
5. Favor conversational comfort over gamification or pressure to stay.

## Accessibility & Inclusion

Keep the interface usable on desktop and mobile, with keyboard access and
clear connection, microphone and call states. Preserve translated interfaces
and the terminal client's established RTL and display-width handling. Audio-only
participation includes listening; do not introduce video or assume everyone
will speak. No additional formal accessibility standard was selected during
this interview.
