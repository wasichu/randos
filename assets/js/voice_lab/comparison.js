// A listening pause, including the loop boundary; no samples are trimmed.
export const COMPARISON_PAUSE_SECONDS = 0.25

export function joinComparisonBuffers(context, buffers) {
  const rate = buffers[0]?.sampleRate
  if (!rate || buffers.some(buffer => buffer.sampleRate !== rate || buffer.numberOfChannels !== 1)) {
    throw new Error("Comparison clips must have the same mono sample rate")
  }
  const pause = Math.round(rate * COMPARISON_PAUSE_SECONDS)
  const length = buffers.reduce((total, buffer) => total + buffer.length + pause, 0)
  const joined = context.createBuffer(1, length, rate)
  let offset = 0
  for (const buffer of buffers) {
    joined.copyToChannel(buffer.getChannelData(0), 0, offset)
    offset += buffer.length + pause
  }
  return joined
}
