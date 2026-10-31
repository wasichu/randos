// Prepared model experiments are small immutable WAV pairs, never model
// inference. Decode both at the lab rate before exposing either half.
export async function loadPreparedPair(item, signal) {
  const decoder = new OfflineAudioContext(1, 1, 48000)
  const buffers = await Promise.all(["original", "converted"].map(async key => {
    const response = await fetch(`/dev/voice-lab/models/${encodeURIComponent(item.audio[key])}`, {signal})
    if (!response.ok) throw new Error("Prepared audio is missing. Regenerate its experiment and reload")
    return decoder.decodeAudioData(await response.arrayBuffer())
  }))
  if (item.reference_kind === "whole_world") return {
    original: {buffer: buffers[0], title: "Whole-recording WORLD", playLabel: "reference", description: "The saved full-recording pitch + resonance result, level-matched for this comparison.", metrics: "WORLD reference · average level matched"},
    modified: {buffer: buffers[1], title: "Chunked WORLD", playLabel: "chunked", description: item.description, metrics: "Chunked comparison · average level matched"},
  }
  return {
    original: {buffer: buffers[0], title: item.reference_title, description: item.reference_description || (item.level_matched ? "Original recording, matched to the comparison's average signal level." : "The original recording with the experiment's fixed listening gain."), metrics: item.level_matched ? "Average level matched · RMS" : "Prepared reference · fixed 0.25 listening gain"},
    modified: {buffer: buffers[1], description: item.description || "Saved experiment output for this recording, using its fixed settings.", metrics: item.level_matched ? "Average level matched · RMS · playback only" : "Pre-rendered experiment output · playback only"},
  }
}
