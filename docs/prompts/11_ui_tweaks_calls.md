# Randos Final UI Polish Pass

Polish the user-facing UI now that:

- real WebRTC audio works
- waveform visualization works
- timers work
- extension flow works
- matchmaking works

The app should now feel calm, intentional, and minimal.

Do not add new features.

Focus only on presentation, wording, layout, and removal of development/debug artifacts.

## Product Tone

Randos should feel:

- calm
- lightweight
- conversational
- anonymous
- emotionally neutral
- mobile friendly

Avoid:

- startup/productivity dashboard aesthetics
- gamification
- clutter
- debug text
- feature overload
- social-media styling

The app should feel closer to conversational infrastructure than a platform.

## Active Call Layout

Use a structure conceptually similar to:

```text
Current call

You
Spanish
[local waveform]

Your rando
English
[remote waveform]

Connection: connected
4:12 remaining

[Mute] [Next rando] [End]
```

## Waveform Sections

Keep the existing separate waveform canvases.

For the local user:

```text
You
Spanish
[waveform]
```

For the remote participant:

```text
Your rando
English
[waveform]
```

Do not use:

- “Speaking:”
- emoji labels
- duplicated explanatory text
- excessive status labels

The language line alone should communicate the spoken language.

## Remove Old Status UI

Remove old informational/debug sections including:

- You are speaking: ...
- They are speaking: ...
- Random calls last up to 5 minutes
- Call status: active
- Extensions: 0
- Audio-only call
- YOUR RANDO heading
- Mock time up button
- mock lifecycle controls
- debug state text
- audio playback debug bar

## Main Heading

Use:

```text
Current call
```

as the active call heading.

Use normal title casing.

## Controls

During active calls, use only:

```text
[Mute] [Next rando] [End]
```

### Mute

Keep existing mute functionality.

### Next rando

Behavior:

- end current call
- notify peer
- close WebRTC connection
- stop media tracks
- clean up audio resources
- immediately requeue user using same language preferences

### End

Behavior:

- end current call
- notify peer
- close WebRTC connection
- stop media tracks
- clean up audio resources
- return user to idle/home state

Rename any existing “Hang up” wording to “End”.

Remove the old “Stop after this call” UI entirely.

## Connection Status

Keep a small subtle connection line if available:

```text
Connection: connected
```

Keep it visually restrained.

## Countdown Timer

Keep the active call countdown timer.

Example:

```text
4:12 remaining
```

Keep it visually subtle and calm.

## Extension Pending UI

During extension_pending, show only:

```text
Time is up. Continue for another 5 minutes?
```

Buttons:

```text
[Continue] [End]
```

Do not show debug UI during extension_pending.

## Extension Count Display

Do not show extension count during active calls.

Only show extension count if a call ends because the maximum duration was reached.

Example:

```text
Conversation ended after 30 minutes and 5 extensions.
```

or:

```text
Maximum conversation length reached.
5 extensions used.
```

Do not show extension count after ordinary endings such as:

- End
- Next rando
- peer disconnect
- extension declined
- extension timeout

For ordinary endings, use simpler messaging:

```text
Conversation ended.
```

## Enable Remote Audio Button

If an “Enable remote audio” button is still necessary for browser autoplay restrictions:

- show it only conditionally when actually needed
- do not permanently display it beneath the waveform

## Mobile Layout

Maintain the current responsive behavior:

- stacked waveform sections on small screens
- side-by-side waveform sections on `sm` and wider screens

Ensure controls remain comfortable and uncluttered on mobile.

## Visual Style

Keep the UI:

- spacious
- readable
- understated
- smooth
- low stimulation

Avoid:

- flashy colors
- oversized status blocks
- excessive animation
- equalizer aesthetics
- social media mechanics

Waveforms should remain the primary “living” visual element.

## Constraints

Do not change:

- WebRTC signaling
- media capture
- waveform rendering logic
- matchmaking logic
- Ash state machine behavior
- extension lifecycle logic

Only change:

- wording
- layout
- visual hierarchy
- button labels
- spacing
- UI cleanup
- user-facing presentation
