// One finite comparison with listening pauses; cancellation during loading.
import {joinComparisonBuffers, COMPARISON_PAUSE_SECONDS} from "./comparison"
export function createRecoveryPlayback({urls = [], buffers: preparedBuffers = null, loop, onEnded, onClip = null}) {
  const context = new AudioContext({sampleRate: 48000})
  const abort = new AbortController()
  let closed = false
  let node = null
  let frame = null

  function close() {
    if (closed) return
    closed = true
    abort.abort()
    if (frame !== null) cancelAnimationFrame(frame)
    try { node?.stop() } catch { /* A setup failure may precede start(). */ }
    node?.disconnect()
    context.close().catch(() => {})
  }

  const ready = (async () => {
    try {
      await context.resume()
      if (closed) return false
      const buffers = preparedBuffers ?? await Promise.all(urls.map(async url => {
        const response = await fetch(url, {signal: abort.signal})
        if (!response.ok) throw new Error("A comparison recording could not be loaded. Regenerate the samples and reload.")
        const bytes = await response.arrayBuffer()
        if (closed) return null
        return context.decodeAudioData(bytes)
      }))
      if (closed) return false
      const joined = joinComparisonBuffers(context, buffers)
      node = context.createBufferSource()
      node.buffer = joined
      node.loop = loop
      node.onended = () => {
        if (closed) return
        close()
        onEnded()
      }
      node.connect(context.destination)
      const started = context.currentTime
      node.start()
      if (onClip) {
        const bounds = []
        let duration = 0, previous = null
        for (const buffer of buffers) { bounds.push({start: duration, end: duration + buffer.duration}); duration += buffer.duration + COMPARISON_PAUSE_SECONDS }
        const tick = () => {
          if (closed) return
          const elapsed = context.currentTime - started
          // Disabling looping finishes the current iteration; retain its cursor.
          const position = elapsed % duration
          const index = bounds.findIndex(span => position >= span.start && position < span.end)
          if (index !== previous) { previous = index; onClip(index) }
          frame = requestAnimationFrame(tick)
        }
        tick()
      }
      return true
    } catch (error) {
      if (closed) return false
      close()
      throw error
    }
  })()

  return {
    ready,
    close,
    setLoop(value) {
      loop = value
      if (node) node.loop = value
    },
  }
}
