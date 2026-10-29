// Shared by the lab and offline diagnostic renders: 4 s, 110 → 220 Hz, 12 harmonics.
export function testToneSamples(sampleRate = 48000) {
  const length = sampleRate * 4
  const data = new Float32Array(length)
  let phase = 0
  for (let i = 0; i < length; i++) {
    phase += (2 * Math.PI * (110 * 2 ** (i / length))) / sampleRate
    let sample = 0
    for (let h = 1; h <= 12; h++) sample += Math.sin(h * phase) / h
    data[i] = 0.25 * sample
  }
  return data
}
