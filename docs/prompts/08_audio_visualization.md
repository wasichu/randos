# Randos Step 8: Audio Visualization

Add waveform or level visualization for local and remote audio.

Goal:

The call screen should feel alive and clearly show when each person is speaking.

## Requirements

Use:

- Web Audio API
- AudioContext
- AnalyserNode
- canvas rendering or SVG rendering

Display:

- local audio visualization
- remote audio visualization

Suggested layout:

- top waveform: local voice
- bottom waveform: remote voice

## Behavior

The visualization should:

- animate smoothly
- respond to volume changes
- pause visually during extension_pending if desired
- resume if both users extend
- stop cleanly when the call ends
- handle mute state clearly
- avoid excessive CPU usage

## Constraints

Do not send audio data to the server.

Do not record audio.

Do not add server-side audio processing.

Do not persist waveform data.

Do not add scoring, gamification, metrics, ratings, or feedback prompts.

## Done Criteria

During a real WebRTC call:

- local speaking activity is visible
- remote speaking activity is visible
- visualization survives extension if both users continue
- visualization stops cleanly after hangup, extension declined, extension timeout, or disconnect
