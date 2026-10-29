import {captureLocalAudio} from '../../randos/media'

// An explicit headset preview. No MediaRecorder, audio fetch, socket or replay.
export function createDspPreview({engine, pitch, scale, prefillSamples = 7680, modified, onEnded, onFailure, onStats}) {
  const context = new AudioContext({sampleRate: 48000, latencyHint: 'interactive'})
  let closed = false, stream = null, source = null, node = null, worker = null, timer = null
  let cancelInit = null
  const close = () => {
    if (closed) return
    closed = true
    clearTimeout(timer)
    cancelInit?.()
    node?.port.postMessage({type: 'stop'})
    source?.disconnect()
    node?.disconnect()
    worker?.terminate()
    for (const track of stream?.getTracks() ?? []) track.stop()
    context.close().catch(() => {})
  }
  const fail = error => { if (!closed) { close(); onFailure(error) } }
  const ready = (async () => {
    try {
      if (![3840,7680].includes(prefillSamples) || (prefillSamples === 3840 && engine !== 'spectral')) throw Error('Unsupported DSP buffering experiment')
      if (context.sampleRate !== 48000) throw Error('This DSP preview requires a 48 kHz AudioContext')
      await context.resume()
      if (closed) return false
      await context.audioWorklet.addModule('/assets/js/voice_lab/dsp_bridge.js')
      if (closed) return false
      node = new AudioWorkletNode(context, 'randos-lab-dsp-bridge', {numberOfInputs: 1, numberOfOutputs: 1, outputChannelCount: [1], channelCount: 1, channelCountMode: 'explicit', processorOptions: {engine, prefillSamples}})
      node.port.onmessage = ({data}) => {
        if (closed) return
        if (data.type === 'fault') fail(Error(data.message))
        else if (data.type === 'primed' || data.type === 'stats') onStats(data)
      }
      node.onprocessorerror = () => fail(Error('The audio bridge stopped'))
      worker = new Worker('/assets/js/voice_lab/dsp_worker.js', {type: 'module'})
      worker.onerror = event => fail(Error(event.message || 'DSP worker stopped'))
      const channel = new MessageChannel()
      node.port.postMessage({type: 'link', port: channel.port1}, [channel.port1])
      const initialized = await new Promise((resolve, reject) => {
        cancelInit = () => resolve(false)
        timer = setTimeout(() => reject(Error('DSP initialization timed out')), 15000)
        worker.onmessage = ({data}) => {
          if (data.type === 'ready') { clearTimeout(timer); resolve(true) }
          else if (data.type === 'fault') reject(Error(data.message))
        }
        worker.postMessage({type: 'init', engine, pitch, scale, port: channel.port2}, [channel.port2])
      })
      cancelInit = null
      if (!initialized || closed) return false
      // Keep the same failure owner after startup; no dry fallback on engine failure.
      worker.onmessage = ({data}) => { if (data.type === 'fault') fail(Error(data.message)) }
      stream = await captureLocalAudio()
      if (closed) { for (const track of stream.getTracks()) track.stop(); return false }
      for (const track of stream.getAudioTracks()) track.addEventListener('ended', () => { if (!closed) { close(); onEnded() } }, {once: true})
      source = context.createMediaStreamSource(stream)
      node.port.postMessage({type: 'start', modified})
      source.connect(node)
      node.connect(context.destination)
      onStats({type: 'buffering'})
      return true
    } catch (error) {
      const cancelled = closed
      close()
      if (cancelled) return false
      throw error
    }
  })()
  return {ready, close, setModified(value) { modified = value; node?.port.postMessage({type: 'modified', value}) }}
}
