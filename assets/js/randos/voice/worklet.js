// AudioWorklet side of the voice processors: runs the Rust code in
// voice/ (compiled to randos_voice.wasm by `just voice-wasm`) on each
// 128-sample block. Each variant is its own small entry file that calls
// registerVoiceProcessor, because the browser loads every worklet module by
// URL (audioWorklet.addModule). The .wasm is embedded in the bundle
// (esbuild's binary loader), so a worklet never fetches anything.

import wasm from "./randos_voice.wasm"

// Compiled once per worklet scope; each node gets its own instance (and so
// its own processor state and memory).
const module = new WebAssembly.Module(wasm)

// `variant`: the Rust `Variant::from_id` id. `parameterDescriptors`, in the
// order the Rust `Processor::set_param` indexes them, become the node's
// AudioParams, and the voice lab builds its sliders from them.
export function registerVoiceProcessor(name, variant, parameterDescriptors) {
  class VoiceProcessor extends AudioWorkletProcessor {
    static get parameterDescriptors() {
      return parameterDescriptors
    }

    constructor() {
      super()
      this.exports = new WebAssembly.Instance(module, {}).exports
      this.ok = this.exports.voice_new(variant, sampleRate, 128) === 1
      this.views = null
    }

    // Views onto the instance's buffers, made again only if its memory grew.
    buffers() {
      const memory = this.exports.memory.buffer
      if (this.views?.memory !== memory) {
        this.views = {
          memory,
          input: new Float32Array(memory, this.exports.voice_input(), 128),
          output: new Float32Array(memory, this.exports.voice_output(), 128),
        }
      }
      return this.views
    }

    process(inputs, outputs, parameters) {
      const output = outputs[0]?.[0]
      if (!output) return true

      const input = inputs[0]?.[0]
      if (!input || !this.ok) {
        output.fill(0)
        return true
      }

      for (let index = 0; index < parameterDescriptors.length; index++) {
        this.exports.voice_set_param(index, parameters[parameterDescriptors[index].name][0])
      }

      const {input: wasmInput, output: wasmOutput} = this.buffers()
      wasmInput.set(input)
      this.exports.voice_process(input.length)
      output.set(wasmOutput.subarray(0, output.length))
      // Any other output channels repeat the first (the call is mono).
      for (let channel = 1; channel < outputs[0].length; channel++) outputs[0][channel].set(output)
      return true
    }
  }

  registerProcessor(name, VoiceProcessor)
}
