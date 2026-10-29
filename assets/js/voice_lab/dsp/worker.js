// Dev-only CPU DSP. PCM stays between this Worker and the AudioWorklet.
import worldFactory from '../../../vendor/voice_dsp/world.mjs'
import worldBytes from '../../../vendor/voice_dsp/world.wasm'
import spectralFactory from '../../../vendor/voice_dsp/spectral.mjs'
import spectralBytes from '../../../vendor/voice_dsp/spectral.wasm'
import {createDspAdapter} from './adapter'

let adapter = null, link = null, received = 0, emitted = 0
const factories = {world: () => worldFactory({wasmBinary: worldBytes}), spectral: () => spectralFactory({wasmBinary: spectralBytes})}
function fail(error) {
  link?.postMessage({type: 'fault', message: error.message || String(error)})
  postMessage({type: 'fault', message: error.message || String(error)})
  adapter?.close()
  link?.close()
  self.close()
}
onmessage = async ({data}) => {
  try {
    if (data.type !== 'init' || adapter || !factories[data.engine]) throw Error('Invalid DSP initialization')
    link = data.port
    adapter = createDspAdapter({
      name: data.engine, module: await factories[data.engine](), pitch: data.pitch, scale: data.scale,
      emit(start, samples) {
        if (start !== emitted || !samples.every(value => Number.isFinite(value) && Math.abs(value) <= 1)) throw Error('DSP produced invalid, clipped or non-contiguous audio')
        emitted += samples.length
        const pcm = Float32Array.from(samples)
        link.postMessage({type: 'output', start, pcm}, [pcm.buffer])
      },
    })
    link.onmessage = ({data: message}) => {
      try {
        if (message.type === 'block') {
          if (message.start !== received || message.pcm.length !== 3840) throw Error('Missing input audio span')
          received += message.pcm.length
          const began = performance.now()
          adapter.push(message.pcm)
          link.postMessage({type: 'credit', memory: adapter.memory(), received, buffer: message.pcm.buffer, computeMs: performance.now() - began}, [message.pcm.buffer])
        } else if (message.type === 'finish') {
          // Only finite fixture tests drain. Live Stop terminates, never flushes speech.
          if (message.total !== received) throw Error('Invalid finite end marker')
          adapter.finish(received)
          if (emitted !== received) throw Error('Incomplete DSP tail')
          link.postMessage({type: 'end', total: received})
          adapter.close()
        } else throw Error('Unknown DSP message')
      } catch (error) { fail(error) }
    }
    link.start()
    postMessage({type: 'ready', memory: adapter.memory(), adapterDelaySamples: adapter.delay})
  } catch (error) { fail(error) }
}
