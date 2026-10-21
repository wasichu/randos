// Worklet: copies its input. The seam's baseline: what a processed call
// costs before any processing (one worklet hop).
import {registerVoiceProcessor} from "./worklet"

registerVoiceProcessor("randos-passthrough", 0, [])
