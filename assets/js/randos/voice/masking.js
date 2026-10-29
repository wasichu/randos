import {MASKING_STYLES} from './masking_choices'

// Stable destination from the outset. Only a fresh, eligible DSP branch can
// feed it; raw microphone audio is never attached as a temporary fallback.
export function createMaskingStream(rawStream, masking, onFailure, signal) {
  if (!Object.hasOwn(MASKING_STYLES, masking)) throw Error('Unsupported voice style')
  if (signal?.aborted) throw new DOMException('Stopped', 'AbortError')
  const context = new AudioContext({sampleRate: 48000, latencyHint: 'interactive'})
  let destination
  try { destination = context.createMediaStreamDestination() }
  catch (error) { void context.close().catch(() => {}); throw error }
  for (const track of destination.stream.getTracks()) track.enabled = false
  let source, branch = null, generation = 0, active = false, closed = false
  let rejectReady = null, setupTimer = null
  const stopBranch = () => {
    generation++
    if (destination) for (const track of destination.stream.getTracks()) track.enabled = false
    try { source?.disconnect() } catch {}
    source = null
    if (branch) {
      clearTimeout(branch.timer)
      branch.cancel?.()
      branch.node.port.postMessage({type: 'stop'})
      branch.node.disconnect()
      branch.worker.terminate()
      branch = null
    }
  }
  const close = () => {
    if (closed) return context.state === 'closed' ? Promise.resolve() : closing
    closed = true; active = false; stopBranch()
    clearTimeout(setupTimer)
    rejectReady?.(new DOMException('Stopped', 'AbortError'))
    signal?.removeEventListener('abort', close)
    for (const track of destination?.stream.getTracks() ?? []) track.stop()
    closing = context.close().catch(() => {})
    return closing
  }
  let closing = Promise.resolve()
  signal?.addEventListener('abort', close, {once: true})
  const fail = (error, token) => {
    if (closed || generation !== token) return
    stopBranch(); active = false
    onFailure?.(error)
  }
  const ready = new Promise((resolve, reject) => {
    rejectReady = reject
    setupTimer = setTimeout(() => { reject(Error('Voice audio setup timed out')); void close() }, 15000)
    ;(async () => {
      if (context.sampleRate !== 48000) throw Error('Voice masking requires 48 kHz audio')
      await context.resume()
      if (closed) throw new DOMException('Stopped', 'AbortError')
      await context.audioWorklet.addModule(document.querySelector('meta[name="randos-voice-worklet"]')?.content || '/assets/js/randos/voice/masking_worklet.js')
      if (closed) throw new DOMException('Stopped', 'AbortError')
      clearTimeout(setupTimer); rejectReady = null; resolve()
    })().catch(error => { reject(error); void close() })
  })
  const openBranch = async token => {
    try {
      if (closed || generation !== token || !active) return
      const node = new AudioWorkletNode(context, 'randos-mask-bridge', {
        numberOfInputs: 1, numberOfOutputs: 1, outputChannelCount: [1], channelCount: 1, channelCountMode: 'explicit',
        processorOptions: {engine: 'spectral', prefillSamples: 7680},
      })
      const worker = new Worker(document.querySelector('meta[name="randos-voice-worker"]')?.content || '/assets/js/randos/voice/masking_worker.js', {type: 'module'})
      const current = {node, worker, timer: null, cancel: null}; branch = current
      const link = new MessageChannel()
      node.port.postMessage({type: 'link', port: link.port1}, [link.port1])
      const ready = await new Promise((resolve, reject) => {
        current.cancel = () => resolve(false)
        current.timer = setTimeout(() => reject(Error('Voice masking initialization timed out')), 15000)
        node.onprocessorerror = () => reject(Error('Voice audio bridge failed'))
        node.port.onmessage = ({data}) => { if (data.type === 'fault') { reject(Error(data.message)); fail(Error(data.message), token) } }
        worker.onerror = event => { reject(Error(event.message)); fail(Error(event.message), token) }
        worker.onmessage = ({data}) => {
          if (data.type === 'ready') resolve(true)
          if (data.type === 'fault') { reject(Error(data.message)); fail(Error(data.message), token) }
        }
        worker.postMessage({type: 'init', engine: 'spectral', masking, port: link.port2}, [link.port2])
      })
      clearTimeout(current.timer); current.cancel = null
      if (!ready || closed || generation !== token || !active) return
      node.onprocessorerror = () => fail(Error('Voice audio bridge failed'), token)
      node.port.postMessage({type: 'start', modified: true})
      source = context.createMediaStreamSource(rawStream)
      source.connect(node); node.connect(destination)
      for (const track of destination.stream.getTracks()) track.enabled = true
    } catch (error) { fail(error, token) }
  }
  return {
    stream: destination.stream, ready, close,
    setEligible(eligible) {
      if (closed || active === eligible) return
      active = eligible; stopBranch()
      if (eligible) {
        const token = generation
        void ready.then(() => openBranch(token), error => fail(error, token))
      }
    },
  }
}
