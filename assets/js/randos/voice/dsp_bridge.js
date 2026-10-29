// Fixed-capacity duplex bridge. No per-quantum PCM allocation or DSP inference.
const HOP = 3840, CAPACITY = HOP * 8, DEFAULT_PREFILL = HOP * 2, MAX_PENDING = HOP * 4
export class DspBridge extends AudioWorkletProcessor {
  constructor(options, allowFixtureCapture = false) {
    super()
    this.prefill = options.processorOptions?.prefillSamples ?? DEFAULT_PREFILL
    const engine = options.processorOptions?.engine ?? 'spectral'
    if (![HOP, DEFAULT_PREFILL].includes(this.prefill) || (this.prefill === HOP && engine !== 'spectral')) throw Error('Unsupported DSP playback buffering')
    this.memory = 0
    this.minBuffered = CAPACITY
    this.pool = Array.from({length: 5}, () => new Float32Array(HOP))
    this.input = this.pool.pop()
    this.fill = 0
    this.ring = new Float32Array(CAPACITY)
    this.read = 0
    this.write = 0
    this.available = 0
    this.sent = 0
    this.acknowledged = 0
    this.written = 0
    this.played = 0
    this.clock = 0
    this.maxPending = 0
    this.maxBuffered = 0
    this.computeMax = 0
    this.started = false
    this.primed = false
    this.failed = false
    this.modified = true
    this.ended = null
    this.link = null
    this.delay = null
    this.lastStats = 0
    // Test harness only: deterministic generated fixtures, never enabled by the UI.
    const testFrames = allowFixtureCapture ? options.processorOptions?.testFrames : 0
    this.testFrames = Number.isInteger(testFrames) && testFrames > 0 && testFrames <= 480000 && testFrames % HOP === 0 ? testFrames : 0
    this.testInput = this.testFrames ? new Float32Array(this.testFrames) : null
    this.testOutput = this.testFrames ? new Float32Array(this.testFrames + 48000) : null
    this.port.onmessage = ({data}) => {
      if (data.type === 'link') { this.link = data.port; this.link.onmessage = event => this.receive(event.data); this.link.start() }
      else if (data.type === 'start') { this.started = true; this.modified = data.modified }
      else if (data.type === 'modified') this.modified = data.value
      else if (data.type === 'stop') { this.started = false; this.failed = true; this.link?.close() }
    }
  }
  fault(message) {
    if (this.failed) return
    this.failed = true
    this.started = false
    this.port.postMessage({type: 'fault', message})
  }
  receive(data) {
    if (this.failed) return
    if (data.type === 'fault') { this.fault(data.message); return }
    if (data.type === 'credit') {
      if (data.received !== this.acknowledged + HOP || data.received > this.sent || data.buffer.byteLength !== HOP * 4) { this.fault('Invalid DSP credit'); return }
      this.memory = data.memory ?? this.memory
      this.acknowledged = data.received
      this.pool.push(new Float32Array(data.buffer))
      this.computeMax = Math.max(this.computeMax, data.computeMs)
    } else if (data.type === 'output') {
      if (data.start !== this.written || !data.pcm.length || this.available + data.pcm.length > CAPACITY) { this.fault('Missing audio or output buffer overflow'); return }
      for (const sample of data.pcm) {
        if (!Number.isFinite(sample) || Math.abs(sample) > 1) { this.fault('Invalid DSP output'); return }
        this.ring[this.write] = sample
        this.write = (this.write + 1) % CAPACITY
      }
      this.written += data.pcm.length
      this.available += data.pcm.length
      this.maxBuffered = Math.max(this.maxBuffered, this.available)
    } else if (data.type === 'end') this.ended = data.total
  }
  process(inputs, outputs) {
    const output = outputs[0]?.[0]
    if (!output) return true
    output.fill(0)
    if (!this.started || this.failed || !this.link) return true
    const input = inputs[0]?.[0], frameStart = this.clock, frames = output.length
    for (let i = 0; i < frames; i++) {
      const sample = (input?.[i] ?? 0) * .25
      if (!Number.isFinite(sample)) { this.fault('Invalid microphone sample'); return true }
      if (!this.testFrames || this.clock + i < this.testFrames) {
        this.input[this.fill++] = sample
        if (this.testInput) this.testInput[this.clock + i] = sample
        if (this.fill === HOP) {
          if (this.sent - this.acknowledged + HOP > MAX_PENDING) { this.fault('DSP cannot keep up: pending input limit exceeded'); return true }
          this.link.postMessage({type: 'block', start: this.sent, pcm: this.input}, [this.input.buffer])
          this.sent += HOP
          this.maxPending = Math.max(this.maxPending, this.sent - this.acknowledged)
          this.input = this.pool.pop()
          if (!this.input) { this.fault('DSP input credits exhausted'); return true }
          this.fill = 0
          if (this.testFrames && this.sent === this.testFrames) this.link.postMessage({type: 'finish', total: this.sent})
        }
      }
    }
    if (!this.primed && this.available >= this.prefill) {
      this.primed = true
      this.delay = frameStart - this.played
      this.port.postMessage({type: 'primed', delaySamples: this.delay})
    }
    if (this.primed) {
      const wanted = this.ended === null ? frames : Math.min(frames, this.ended - this.played)
      if (this.available < wanted) { this.fault('DSP playback starved after starting'); return true }
      for (let i = 0; i < wanted; i++) {
        const wet = this.ring[this.read]
        this.read = (this.read + 1) % CAPACITY
        this.available--
        this.played++
        output[i] = this.modified ? wet : (input?.[i] ?? 0) * .25
      }
      if (wanted > 0) this.minBuffered = Math.min(this.minBuffered, this.available)
    } else if (!this.modified) for (let i = 0; i < frames; i++) output[i] = (input?.[i] ?? 0) * .25
    if (this.testOutput && frameStart + frames <= this.testOutput.length) this.testOutput.set(output, frameStart)
    this.clock += frames
    if (this.clock - this.lastStats >= 48000) {
      this.lastStats = this.clock
      this.port.postMessage({type: 'stats', clockFrames: this.clock, playedSamples: this.played, memory: this.memory, minBufferedSamples: this.minBuffered, delaySamples: this.delay, pendingSamples: this.sent - this.acknowledged, bufferedSamples: this.available, maxPendingSamples: this.maxPending, maxBufferedSamples: this.maxBuffered, computeMaxMs: this.computeMax})
    }
    if (this.testFrames && this.ended !== null && this.played === this.ended) {
      this.started = false
      this.port.postMessage({type: 'test-result', input: this.testInput, output: this.testOutput, renderedFrames: this.clock, delaySamples: this.delay, maxPendingSamples: this.maxPending, maxBufferedSamples: this.maxBuffered, minBufferedSamples: this.minBuffered}, [this.testInput.buffer, this.testOutput.buffer])
    }
    return true
  }
}
