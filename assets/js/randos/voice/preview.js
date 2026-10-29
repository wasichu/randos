import {createMaskingStream} from './masking'

// Off is an explicit original-voice audition, never a processor-failure fallback.
// Its gain matches the DSP input level. Neither branch owns the raw microphone.
export function createPreviewStream(raw, masking, onFailure, signal) {
  if (masking) return createMaskingStream(raw, masking, onFailure, signal)
  if (signal?.aborted) throw new DOMException('Stopped', 'AbortError')
  const context = new AudioContext({latencyHint: 'interactive'})
  let source, gain, destination, closed = false, rejectReady, timer
  let closing = Promise.resolve()
  const close = () => {
    if (closed) return closing
    closed = true
    clearTimeout(timer)
    rejectReady?.(new DOMException('Stopped', 'AbortError'))
    signal?.removeEventListener('abort', close)
    source?.disconnect(); gain?.disconnect()
    for (const track of destination?.stream.getTracks() ?? []) track.stop()
    closing = context.close().catch(() => {})
    return closing
  }
  try {
    destination = context.createMediaStreamDestination()
    for (const track of destination.stream.getTracks()) track.enabled = false
    source = context.createMediaStreamSource(raw)
    gain = context.createGain(); gain.gain.value = 0.25
    source.connect(gain); gain.connect(destination)
  } catch (error) { void close(); throw error }
  signal?.addEventListener('abort', close, {once: true})
  const ready = new Promise((resolve, reject) => {
    rejectReady = reject
    timer = setTimeout(() => { reject(Error('Preview audio setup timed out')); void close() }, 15000)
    context.resume().then(() => {
      if (closed) return
      clearTimeout(timer); rejectReady = null; resolve()
    }).catch(error => { reject(error); void close() })
  })
  return {
    stream: destination.stream, ready, close,
    setEligible(eligible) {
      if (!closed) for (const track of destination.stream.getTracks()) track.enabled = eligible
    },
  }
}
