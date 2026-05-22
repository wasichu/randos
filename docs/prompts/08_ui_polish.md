# Randos Waveform Polish

The audio visualization is working and uses separate canvases for local and remote audio.

Polish the rendering without changing WebRTC or audio behavior.

## Goals

- vertically center each waveform in its own canvas
- use distinct colors for local user and remote rando
- keep the visual style calm and minimal

## Requirements

Each canvas should draw its waveform around its own vertical midpoint:

```js
const centerY = canvas.height / 2
```

The waveform should expand above and below that center line rather than appearing left-aligned, bottom-aligned, or visually lopsided.

Use separate styling for:

- local audio
- remote audio

Example:

- local: calm blue/cyan
- remote: warm violet/amber/green

Use whatever fits the existing UI best.

## Constraints

Do not change:

- WebRTC signaling
- media capture
- remote audio playback
- call lifecycle
- extension behavior
- cleanup behavior

Only polish:

- waveform rendering
- canvas sizing if needed
- visual presentation

## Style

Avoid:

- flashing
- aggressive colors
- nightclub equalizer aesthetics
- excessive animation
- visual clutter

The result should feel:

- smooth
- subtle
- readable
- mobile friendly
- calm
