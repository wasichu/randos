import {logWarning} from "./logging"

const FFT_SIZE = 256
const BAR_COUNT = 24
const BARS_PER_SIDE = BAR_COUNT / 2
const FRAME_RATE_MS = 50
const COLORS = {
  local: "rgba(8, 145, 178, 0.72)",
  remote: "rgba(124, 58, 237, 0.62)",
  muted: "rgba(120, 113, 108, 0.42)",
}

export class AudioLevelVisualizer {
  constructor({canvas, stream, tone = "local", muted = false}) {
    this.canvas = canvas
    this.stream = stream
    this.tone = tone
    this.muted = muted
    this.animationFrame = null
    this.lastFrameAt = 0
    this.audioContext = null
    this.analyser = null
    this.source = null
    this.data = null
    this.closed = false
  }

  start() {
    if (!this.canvas || !this.stream || this.closed) return

    try {
      this.audioContext = new AudioContext()
      this.analyser = this.audioContext.createAnalyser()
      this.analyser.fftSize = FFT_SIZE
      this.analyser.smoothingTimeConstant = 0.82
      this.source = this.audioContext.createMediaStreamSource(this.stream)
      this.source.connect(this.analyser)
      this.data = new Uint8Array(this.analyser.frequencyBinCount)
      this.draw()
    } catch (error) {
      logWarning("audio_visualizer.start_failed", {reason: error.message})
      this.close()
    }
  }

  setMuted(muted) {
    this.muted = muted
  }

  close() {
    if (this.closed) return

    this.closed = true

    if (this.animationFrame) {
      cancelAnimationFrame(this.animationFrame)
      this.animationFrame = null
    }

    this.source?.disconnect()
    this.analyser?.disconnect()
    this.source = null
    this.analyser = null
    this.data = null

    if (this.audioContext && this.audioContext.state !== "closed") {
      this.audioContext.close().catch(() => {})
    }

    this.audioContext = null
    this.clear()
  }

  draw(timestamp = 0) {
    if (this.closed) return

    this.animationFrame = requestAnimationFrame(time => this.draw(time))

    if (timestamp - this.lastFrameAt < FRAME_RATE_MS) return

    this.lastFrameAt = timestamp
    this.renderBars(this.levels())
  }

  levels() {
    if (this.muted || !this.analyser || !this.data) {
      return Array.from({length: BAR_COUNT}, () => 0.04)
    }

    this.analyser.getByteFrequencyData(this.data)

    const bucketSize = Math.max(1, Math.floor(this.data.length / BAR_COUNT))

    return Array.from({length: BAR_COUNT}, (_, index) => {
      const start = index * bucketSize
      const bucket = this.data.slice(start, start + bucketSize)
      const average = bucket.reduce((sum, value) => sum + value, 0) / bucket.length
      return Math.max(0.04, average / 255)
    })
  }

  renderBars(levels) {
    const canvas = this.canvas
    const context = canvas.getContext("2d")
    const rect = canvas.getBoundingClientRect()
    const ratio = window.devicePixelRatio || 1
    const width = Math.max(1, Math.floor(rect.width * ratio))
    const height = Math.max(1, Math.floor(rect.height * ratio))

    if (canvas.width !== width || canvas.height !== height) {
      canvas.width = width
      canvas.height = height
    }

    context.clearRect(0, 0, width, height)
    context.fillStyle = this.muted ? COLORS.muted : COLORS[this.tone] || COLORS.local

    const gap = 4 * ratio
    const sideWidth = width / 2
    const barWidth = (sideWidth - gap * BARS_PER_SIDE) / BARS_PER_SIDE
    const minHeight = 5 * ratio
    const centerX = width / 2
    const centerY = height / 2

    levels.slice(0, BARS_PER_SIDE).forEach((level, index) => {
      const barHeight = Math.max(minHeight, level * height * 0.86)
      const y = centerY - barHeight / 2
      const radius = Math.min(barWidth / 2, 5 * ratio)
      const offset = gap + index * (barWidth + gap)
      const rightX = centerX + offset
      const leftX = centerX - offset - barWidth

      this.roundedRect(context, rightX, y, barWidth, barHeight, radius)
      context.fill()

      this.roundedRect(context, leftX, y, barWidth, barHeight, radius)
      context.fill()
    })
  }

  roundedRect(context, x, y, width, height, radius) {
    context.beginPath()
    context.moveTo(x + radius, y)
    context.lineTo(x + width - radius, y)
    context.quadraticCurveTo(x + width, y, x + width, y + radius)
    context.lineTo(x + width, y + height - radius)
    context.quadraticCurveTo(x + width, y + height, x + width - radius, y + height)
    context.lineTo(x + radius, y + height)
    context.quadraticCurveTo(x, y + height, x, y + height - radius)
    context.lineTo(x, y + radius)
    context.quadraticCurveTo(x, y, x + radius, y)
    context.closePath()
  }

  clear() {
    const context = this.canvas?.getContext("2d")
    if (!context) return

    context.clearRect(0, 0, this.canvas.width, this.canvas.height)
  }
}
