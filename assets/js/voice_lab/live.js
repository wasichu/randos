// Headphone monitoring only: no recording, buffers for later playback, or
// network audio. close() is available immediately, including during a mic
// permission prompt. A late permission grant is closed before connecting output.
import {captureLocalAudio} from "../randos/media"
import {LAB_PROCESSORS, createLabVoiceNode} from "./processors"

export function createLivePreview({processor, params, modified, onEnded, onFailure}) {
  const sampleRate = LAB_PROCESSORS[processor]?.sampleRate
  const context = new AudioContext({latencyHint: "interactive", ...(sampleRate ? {sampleRate} : {})})
  const settings = {...params}
  let closed = false
  let stream = null
  let source = null
  let voice = null

  function close() {
    if (closed) return
    closed = true
    source?.disconnect()
    voice?.disconnect()
    for (const track of stream?.getTracks() ?? []) track.stop()
    context.close().catch(() => {})
  }

  function route() {
    if (closed || !source || !voice) return
    source.disconnect()
    source.connect(modified ? voice : context.destination)
  }

  const ready = (async () => {
    try {
      await context.resume()
      if (closed) return false
      stream = await captureLocalAudio()
      if (closed) {
        for (const track of stream.getTracks()) track.stop()
        return false
      }
      for (const track of stream.getAudioTracks()) {
        track.addEventListener("ended", () => {
          if (closed) return
          close()
          onEnded()
        }, {once: true})
      }
      voice = await createLabVoiceNode(context, processor)
      voice.onprocessorerror = () => {
        if (closed) return
        close()
        onFailure(new Error("The audio processor stopped"))
      }
      if (closed) return false
      for (const [name, value] of Object.entries(settings)) voice.parameters.get(name)?.setValueAtTime(value, context.currentTime)
      source = context.createMediaStreamSource(stream)
      voice.connect(context.destination)
      route()
      return true
    } catch (error) {
      const cancelled = closed
      close()
      if (cancelled) return false
      throw error
    }
  })()

  return {
    ready,
    close,
    setModified(value) {
      modified = value
      route()
    },
  }
}
