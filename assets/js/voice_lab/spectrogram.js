// Spectrograms for the voice lab: short-time FFT (Hann, 1024 points, hop
// 256) of an AudioBuffer's first channel, drawn as log magnitude from 0 to
// `maxHz`, where speech's pitch and its shifts show.

const SIZE = 1024
const HOP = 256

const hann = Float32Array.from({length: SIZE}, (_, i) => 0.5 - 0.5 * Math.cos((2 * Math.PI * i) / (SIZE - 1)))

// In-place radix-2 FFT of (re, im), length a power of two.
function fft(re, im) {
  const n = re.length
  for (let i = 1, j = 0; i < n; i++) {
    let bit = n >> 1
    for (; j & bit; bit >>= 1) j ^= bit
    j ^= bit
    if (i < j) {
      ;[re[i], re[j]] = [re[j], re[i]]
      ;[im[i], im[j]] = [im[j], im[i]]
    }
  }
  for (let len = 2; len <= n; len <<= 1) {
    const angle = (-2 * Math.PI) / len
    for (let i = 0; i < n; i += len) {
      for (let k = 0; k < len / 2; k++) {
        const wr = Math.cos(angle * k)
        const wi = Math.sin(angle * k)
        const ar = re[i + k + len / 2]
        const ai = im[i + k + len / 2]
        const br = ar * wr - ai * wi
        const bi = ar * wi + ai * wr
        re[i + k + len / 2] = re[i + k] - br
        im[i + k + len / 2] = im[i + k] - bi
        re[i + k] += br
        im[i + k] += bi
      }
    }
  }
}

// Columns of dB magnitudes (bins up to maxHz) over time.
export function spectrogram(buffer, maxHz = 4000) {
  const samples = buffer.getChannelData(0)
  const bins = Math.min(SIZE / 2, Math.ceil((maxHz / buffer.sampleRate) * SIZE))
  const columns = []
  const re = new Float32Array(SIZE)
  const im = new Float32Array(SIZE)
  for (let start = 0; start + SIZE <= samples.length; start += HOP) {
    for (let i = 0; i < SIZE; i++) {
      re[i] = samples[start + i] * hann[i]
      im[i] = 0
    }
    fft(re, im)
    const column = new Float32Array(bins)
    for (let b = 0; b < bins; b++) column[b] = 10 * Math.log10(re[b] * re[b] + im[b] * im[b] + 1e-12)
    columns.push(column)
  }
  return columns
}

// Draws columns into the canvas (one pixel per column and bin; CSS scales
// it), low frequencies at the bottom, the top 70 dB of the clip in teal.
export function drawSpectrogram(canvas, columns) {
  const bins = columns[0]?.length ?? 0
  canvas.width = columns.length
  canvas.height = bins
  if (!bins) return

  let top = -Infinity
  for (const column of columns) for (const value of column) top = Math.max(top, value)
  const floor = top - 70

  const context = canvas.getContext("2d")
  const image = context.createImageData(columns.length, bins)
  columns.forEach((column, x) => {
    for (let b = 0; b < bins; b++) {
      const level = Math.max(0, Math.min(1, (column[b] - floor) / 70))
      const offset = ((bins - 1 - b) * columns.length + x) * 4
      // From near-black stone to teal-300 (Tailwind's palette).
      image.data[offset] = 12 + level * (94 - 12)
      image.data[offset + 1] = 10 + level * (234 - 10)
      image.data[offset + 2] = 9 + level * (212 - 9)
      image.data[offset + 3] = 255
    }
  })
  context.putImageData(image, 0, 0)
}
