# Randos Waveform Center-Out Animation Polish

The audio visualization is working, but the waveform activity feels visually weighted toward the left side of the canvas.

Polish the waveform rendering so activity feels centered in the canvas.

## Goal

When speech causes the waveform to animate, the visual energy should appear around the middle of the canvas rather than mostly near the left edge.

This is a rendering-only change.

## Requirements

Keep the existing separate canvases for local and remote audio.

Each canvas should still draw its own waveform.

Change the drawing approach so the waveform is visually centered horizontally.

Preferred approach:

- treat the center of the canvas as the visual origin
- draw samples outward from the center toward both the left and right sides
- mirror or distribute sample data so speech activity appears centered
- keep the waveform vertically centered as it currently is

Conceptually:

```js
const centerX = canvas.width / 2
const centerY = canvas.height / 2
```

Then draw part of the waveform to the right of `centerX` and a corresponding part to the left of `centerX`.

Alternative acceptable approach:

- keep the time-domain waveform, but rotate/reindex the buffer so recent activity is centered rather than starting at the left edge

## Visual Style

Keep the animation:

- smooth
- calm
- subtle
- readable
- mobile friendly

Use distinct colors for:

- local audio
- remote rando audio

Avoid:

- aggressive equalizer bars
- flashing
- nightclub styling
- overly complex visuals

## Constraints

Do not change:

- WebRTC signaling
- media capture
- remote audio playback
- call lifecycle
- extension behavior
- cleanup behavior

Only change waveform drawing/presentation.

## Done Criteria

When someone speaks, the waveform activity feels visually centered in the canvas instead of weighted toward the left side.
