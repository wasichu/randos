# Randos Step 1: Product Skeleton and UI State

Build the first visible version of Randos.

Randos is an anonymous, audio-only language conversation app built around low pressure human interaction.

Core principles:

- no accounts
- no profiles
- no contacts
- no followers
- no feeds
- no ads
- no gamification
- no permanent social graph
- no video ever
- audio only forever
- no recording
- no server-side audio access
- no eavesdropping
- no admin listening

Randos is closer to public conversational infrastructure than social media.

The app is about brief, calm, low pressure language conversation.

Each user chooses:

- the language they will speak
- the language they want to hear

Then the app pairs them with a compatible random person.

Example:

User A:

- speaks English
- wants to hear Spanish

User B:

- speaks Spanish
- wants to hear English

This is a compatible match.

Do not implement matchmaking or WebRTC yet.

## UI Language

Start with English only.

However, use Gettext from the beginning for user-facing UI strings.

Use stable internal language codes:

- en
- es
- fr
- de
- it
- pt

Display language names in English for now.

Example:

```elixir
[
  {"English", "en"},
  {"Spanish", "es"},
  {"French", "fr"},
  {"German", "de"},
  {"Italian", "it"},
  {"Portuguese", "pt"}
]
```

Do not confuse UI localization with conversation language preferences.

Gettext is for the app interface.

The domain model is for the languages users speak and want to hear.

## Time-Bounded Conversations

Random calls last up to 5 minutes by default.

When time is up, both users may choose whether to continue.

The call only extends if both users agree.

If either user declines or does nothing, the call ends.

No one is forced to continue.

## 18+ Acknowledgment

Before a user can search for a rando, require a simple checkbox:

```text
I am 18 or older and understand that conversations are anonymous and unmoderated.
```

The Find a rando button should be disabled until this is checked.

Do not add invasive age verification.

Do not add accounts.

Do not add identity verification.

## UI Requirements

Create a clean landing page with:

- app title: Randos
- short subtitle explaining anonymous audio language practice
- dropdown: I will speak in
- dropdown: I want them to speak in
- 18+ acknowledgment checkbox
- button: Find a rando

Initial languages:

- English
- Spanish
- French
- German
- Italian
- Portuguese

Suggested supporting copy:

```text
Short anonymous conversations for language practice.
```

Optional small copy:

```text
No accounts. No profiles. No pressure.
```

## UI State Machine

Implement explicit UI states:

- idle
- looking
- connecting
- in_call
- extension_pending

Allowed transitions:

- idle -> looking
- looking -> idle
- looking -> connecting
- connecting -> in_call
- connecting -> idle
- in_call -> extension_pending
- extension_pending -> in_call
- extension_pending -> looking
- extension_pending -> idle
- in_call -> looking
- in_call -> idle

For now, transitions can be mocked with buttons.

Centralize transition logic.

Avoid scattered ad hoc state mutations.

## Placeholder Call Screen

Create a mock call screen with:

- anonymous peer label: Your rando
- local waveform placeholder
- remote waveform placeholder
- mute button placeholder
- hang up button
- stop after this call toggle
- static label: Random calls last up to 5 minutes
- visible label: You are speaking: selected speaking language
- visible label: They are speaking: selected listening language

Create a mock extension prompt:

```text
Time is up. Continue for another 5 minutes?
```

Buttons:

- Continue
- End

No real audio yet.

No WebRTC yet.

No matchmaking yet.

## Visual Feel

The UI should feel:

- calm
- minimal
- mobile friendly
- low pressure
- non-performative

Avoid:

- dashboards
- metrics
- online user counts
- profile cards
- avatars
- ratings
- streaks
- engagement mechanics
- social media visual clutter

## Non Goals

Do not add:

- accounts
- usernames
- profiles
- contacts
- chat
- video
- persistence
- WebRTC
- audio capture
- TURN
- Membrane
- SFU
- recording
- eavesdropping
- admin listening
