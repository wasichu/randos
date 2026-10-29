// Development-only wrapper around the same Rust processor the benchmark uses.
import {registerVoiceProcessor} from "../randos/voice/worklet"

registerVoiceProcessor("randos-lab-mcadams", 2, [
  {name: "alpha", defaultValue: 0.9, minValue: 0.5, maxValue: 1, automationRate: "k-rate"},
])
