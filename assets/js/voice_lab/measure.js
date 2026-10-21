// The voice lab's numbers: algorithmic latency from rendered clips, and
// what the seam (processLocalStream) costs a live call.

import {processLocalStream} from "../randos/voice/seam"

// RMS envelope in `frameMs` frames: pitch-independent, so a pitch-shifted
// output still lines up with its input.
function envelope(samples, rate, frameMs = 2) {
  const frame = Math.max(1, Math.round((rate * frameMs) / 1000))
  const out = new Float32Array(Math.floor(samples.length / frame))
  for (let f = 0; f < out.length; f++) {
    let sum = 0
    for (let i = f * frame; i < (f + 1) * frame; i++) sum += samples[i] * samples[i]
    out[f] = Math.sqrt(sum / frame)
  }
  return {values: out, frameMs}
}

// The lag (0..maxMs) at which `b` best matches `a`, by normalized cross-correlation.
function bestLagMs(a, b, frameMs, maxMs) {
  const mean = values => values.reduce((s, v) => s + v, 0) / values.length
  const ma = mean(a)
  const mb = mean(b)
  let best = {lag: 0, score: -Infinity}
  for (let lag = 0; lag <= Math.round(maxMs / frameMs); lag++) {
    let s = 0
    let na = 0
    let nb = 0
    for (let i = 0; i + lag < b.length && i < a.length; i++) {
      const x = a[i] - ma
      const y = b[i + lag] - mb
      s += x * y
      na += x * x
      nb += y * y
    }
    const score = s / Math.sqrt(na * nb || 1)
    if (score > best.score) best = {lag, score}
  }
  return best.lag * frameMs
}

// How much later `output` follows `input` (both AudioBuffers), in ms.
export function algorithmicLatencyMs(input, output, maxMs = 150) {
  const a = envelope(input.getChannelData(0), input.sampleRate)
  const b = envelope(output.getChannelData(0), output.sampleRate)
  return bestLagMs(a.values, b.values, a.frameMs, maxMs)
}

// What `processor` adds to a live call: a click train goes through the
// real seam (processLocalStream, as a call's mic would) and, side by side,
// straight from its stream; both are recorded in one context and lined up.
// Silent: nothing is connected to a speaker except a node writing zeros.
export async function measureSeamLatencyMs(processor, {seconds = 3} = {}) {
  const rate = 48000
  const generator = new AudioContext({sampleRate: rate})
  const recorder = new AudioContext({sampleRate: rate})
  let processed = null
  try {
    // A click every 250 ms.
    const clicks = generator.createBuffer(1, rate, rate)
    const data = clicks.getChannelData(0)
    for (let k = 0; k < 4; k++) for (let i = 0; i < 24; i++) data[k * (rate / 4) + i] = 1 - i / 24
    const source = generator.createBufferSource()
    source.buffer = clicks
    source.loop = true
    const stream = generator.createMediaStreamDestination()
    source.connect(stream)
    source.start()

    processed = await processLocalStream(stream.stream, processor)

    const merger = recorder.createChannelMerger(2)
    recorder.createMediaStreamSource(stream.stream).connect(merger, 0, 0)
    recorder.createMediaStreamSource(processed.stream).connect(merger, 0, 1)
    const tap = recorder.createScriptProcessor(4096, 2, 2)
    const direct = []
    const through = []
    tap.onaudioprocess = event => {
      direct.push(Float32Array.from(event.inputBuffer.getChannelData(0)))
      through.push(Float32Array.from(event.inputBuffer.getChannelData(1)))
      // Leave the output silent.
    }
    merger.connect(tap)
    tap.connect(recorder.destination)
    await Promise.all([generator.resume(), recorder.resume()])

    await new Promise(resolve => setTimeout(resolve, seconds * 1000))
    tap.disconnect()

    const join = chunks => {
      const all = new Float32Array(chunks.reduce((n, c) => n + c.length, 0))
      let at = 0
      for (const chunk of chunks) {
        all.set(chunk, at)
        at += chunk.length
      }
      return all
    }
    // Skip the first half second while both paths settle.
    const skip = rate / 2
    const a = envelope(join(direct).subarray(skip), rate, 0.5)
    const b = envelope(join(through).subarray(skip), rate, 0.5)
    return bestLagMs(a.values, b.values, a.frameMs, 100)
  } finally {
    processed?.close()
    generator.close().catch(() => {})
    recorder.close().catch(() => {})
  }
}
