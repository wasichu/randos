// The voice lab page (dev only; RandosDev.VoiceLabLive renders its shell).
// Renders a source through every voice processor offline, with the same
// AudioWorklet modules a call uses (voice/seam.js), then plays any of them,
// switching at the same position, beside its spectrogram and numbers.
// Nothing is recorded, stored, or uploaded: sources are bundled clips or a
// generated tone.

import {VOICE_PROCESSORS, createVoiceNode} from "../randos/voice/seam"
import {spectrogram, drawSpectrogram} from "./spectrogram"
import {algorithmicLatencyMs, measureSeamLatencyMs} from "./measure"

const RATE = 48000
const $ = id => document.getElementById(id)

const lab = {
  sources: [],
  params: {}, // processor -> {name: value}
  rendered: [], // [{key, label, buffer, ...}]
  listening: "original",
  player: null, // {context, node, startedAt, offset}
}

function setStatus(text, state) {
  const status = $("voice-lab-status")
  status.textContent = text
  status.dataset.state = state
}

// A 4 s harmonic tone gliding 110 → 220 Hz: pitch shifts are plain to see.
function testTone() {
  const length = RATE * 4
  const buffer = new AudioBuffer({length, sampleRate: RATE, numberOfChannels: 1})
  const data = buffer.getChannelData(0)
  let phase = 0
  for (let i = 0; i < length; i++) {
    phase += (2 * Math.PI * (110 * 2 ** (i / length))) / RATE
    let sample = 0
    for (let h = 1; h <= 12; h++) sample += Math.sin(h * phase) / h
    data[i] = 0.25 * sample
  }
  return buffer
}

async function loadSources(root) {
  const path = root.dataset.clipsPath
  const {clips} = await (await fetch(path)).json()
  const decoder = new OfflineAudioContext(1, 1, RATE)
  const decoded = await Promise.all(
    clips.map(async name => {
      const bytes = await (await fetch(`${path}/${name}`)).arrayBuffer()
      return {key: name, label: name.replace(/\.wav$/, "").replace(/_/g, " "), buffer: await decoder.decodeAudioData(bytes)}
    }),
  )
  return [...decoded, {key: "test_tone", label: "test tone (110 → 220 Hz glide)", buffer: testTone()}]
}

// Sliders from each processor's own parameterDescriptors (its AudioParams).
async function buildParams() {
  const container = $("voice-lab-params")
  const probe = new OfflineAudioContext(1, 128, RATE)
  for (const [name, processor] of Object.entries(VOICE_PROCESSORS)) {
    const node = await createVoiceNode(probe, name)
    lab.params[name] = {}
    for (const [param, audioParam] of node.parameters) {
      lab.params[name][param] = audioParam.defaultValue
      const id = `voice-lab-param-${name}-${param}`
      const row = document.createElement("label")
      row.className = "block space-y-1"
      row.innerHTML = `<span class="flex justify-between text-sm text-stone-700"><span></span><output class="tabular-nums"></output></span>`
      row.querySelector("span span").textContent = `${processor.label}: ${param.replace(/_/g, " ")}`
      const output = row.querySelector("output")
      const input = document.createElement("input")
      Object.assign(input, {
        id,
        type: "range",
        min: audioParam.minValue,
        max: audioParam.maxValue,
        step: (audioParam.maxValue - audioParam.minValue) / 48,
        value: audioParam.defaultValue,
        className: "w-full accent-teal-700",
      })
      input.dataset.processor = name
      input.dataset.param = param
      output.textContent = input.value
      input.addEventListener("input", () => {
        lab.params[name][param] = Number(input.value)
        output.textContent = Number(input.value).toFixed(1)
      })
      row.append(input)
      container.append(row)
    }
  }
}

async function renderThrough(name, source) {
  const context = new OfflineAudioContext(1, source.length, RATE)
  const node = await createVoiceNode(context, name)
  for (const [param, value] of Object.entries(lab.params[name])) node.parameters.get(param)?.setValueAtTime(value, 0)
  const input = context.createBufferSource()
  input.buffer = source
  input.connect(node).connect(context.destination)
  input.start()
  const started = performance.now()
  const buffer = await context.startRendering()
  const seconds = (performance.now() - started) / 1000
  return {buffer, realTimeFactor: seconds / source.duration}
}

async function render() {
  stop()
  const source = lab.sources.find(s => s.key === $("voice-lab-source").value)
  if (!source) return
  setStatus("Rendering…", "rendering")
  $("voice-lab-render").disabled = true
  try {
    lab.rendered = [{key: "original", label: "Original", description: "The source, unprocessed.", buffer: source.buffer}]
    for (const [name, processor] of Object.entries(VOICE_PROCESSORS)) {
      const {buffer, realTimeFactor} = await renderThrough(name, source.buffer)
      lab.rendered.push({
        key: name,
        label: processor.label,
        description: processor.description,
        buffer,
        realTimeFactor,
        latencyMs: algorithmicLatencyMs(source.buffer, buffer),
      })
    }
    showResults()
    $("voice-lab-play").disabled = false
    setStatus(`Rendered "${source.label}" through ${lab.rendered.length - 1} processors.`, "rendered")
  } catch (error) {
    setStatus(`Render failed: ${error.message}`, "failed")
  } finally {
    $("voice-lab-render").disabled = false
  }
}

function showResults() {
  const results = $("voice-lab-results")
  results.replaceChildren()
  for (const result of lab.rendered) {
    const card = document.createElement("article")
    card.id = `voice-lab-result-${result.key}`
    card.className = "space-y-3 rounded-lg border border-stone-200 bg-white p-5 transition"
    if (result.realTimeFactor !== undefined) {
      card.dataset.realTimeFactor = result.realTimeFactor.toFixed(4)
      card.dataset.latencyMs = String(result.latencyMs)
    }
    card.innerHTML = `
      <div class="flex flex-wrap items-baseline justify-between gap-3">
        <label class="flex items-center gap-2 font-medium">
          <input type="radio" name="voice-lab-listen" class="accent-teal-700">
          <span></span>
        </label>
        <span class="text-sm tabular-nums text-stone-600"></span>
      </div>
      <p class="text-sm text-stone-600"></p>
      <canvas class="h-40 w-full rounded-md bg-stone-950" style="image-rendering: pixelated"></canvas>`
    card.querySelector("label span").textContent = result.label
    card.querySelector("p").textContent = result.description
    card.querySelector(".tabular-nums").textContent =
      result.realTimeFactor === undefined
        ? ""
        : `CPU: ${(result.realTimeFactor * 100).toFixed(2)}% of real time · delay ≈ ${result.latencyMs} ms`
    const radio = card.querySelector("input")
    radio.value = result.key
    radio.checked = result.key === lab.listening
    radio.addEventListener("change", () => listen(result.key))
    drawSpectrogram(card.querySelector("canvas"), spectrogram(result.buffer))
    results.append(card)
  }
}

// Playback: switching keeps the position, so the same moment can be compared.
function position() {
  const player = lab.player
  if (!player) return 0
  return (player.offset + player.context.currentTime - player.startedAt) % player.node.buffer.duration
}

function playFrom(key, offset) {
  const result = lab.rendered.find(r => r.key === key)
  if (!result) return
  const context = lab.player?.context ?? new AudioContext()
  lab.player?.node.stop()
  const node = context.createBufferSource()
  node.buffer = result.buffer
  node.loop = true
  node.connect(context.destination)
  node.start(0, offset)
  lab.player = {context, node, startedAt: context.currentTime, offset}
  $("voice-lab-stop").disabled = false
}

function listen(key) {
  lab.listening = key
  if (lab.player) playFrom(key, position())
}

function stop() {
  if (!lab.player) return
  lab.player.node.stop()
  lab.player.context.close().catch(() => {})
  lab.player = null
  $("voice-lab-stop").disabled = true
}

async function measure() {
  const button = $("voice-lab-measure")
  const result = $("voice-lab-seam-result")
  button.disabled = true
  result.dataset.state = "measuring"
  result.textContent = "Measuring for 3 s…"
  try {
    const ms = await measureSeamLatencyMs("passthrough")
    result.dataset.state = "measured"
    result.dataset.latencyMs = String(ms)
    result.textContent = `Passthrough adds ≈ ${ms} ms to a call's audio (the worklet hop alone; a processor's own delay comes on top).`
  } catch (error) {
    result.dataset.state = "failed"
    result.textContent = `Measurement failed: ${error.message}`
  } finally {
    button.disabled = false
  }
}

async function start() {
  const root = $("voice-lab")
  if (!root) return
  setStatus("Loading clips…", "loading")
  lab.sources = await loadSources(root)
  const select = $("voice-lab-source")
  for (const source of lab.sources) select.append(new Option(source.label, source.key))
  await buildParams()
  $("voice-lab-render").addEventListener("click", render)
  $("voice-lab-play").addEventListener("click", () => playFrom(lab.listening, position()))
  $("voice-lab-stop").addEventListener("click", stop)
  $("voice-lab-measure").addEventListener("click", measure)
  setStatus("Pick a source and render.", "ready")
}

start().catch(error => setStatus(`The lab couldn't start: ${error.message}`, "failed"))
