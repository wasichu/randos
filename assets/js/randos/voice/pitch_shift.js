// Worklet: the delay-line pitch shifter (voice/src/pitch.rs). The ranges
// match the Rust constants, which clamp anything outside them.
import {registerVoiceProcessor} from "./worklet"

registerVoiceProcessor("randos-pitch-shift", 1, [
  {name: "semitones", defaultValue: -4, minValue: -12, maxValue: 12, automationRate: "k-rate"},
  {name: "window_ms", defaultValue: 40, minValue: 10, maxValue: 100, automationRate: "k-rate"},
])
