// The voice lab page (dev only; RandosDev.VoiceLabLive renders its shell).
// Prepares the selected modification on demand through the same AudioWorklet
// modules a call uses (voice/seam.js). Original and modified playback share
// one timeline and one output, beside explained spectrograms and numbers.
// Bundled clips and a generated tone support replay; the separate live mic
// preview is ephemeral. Nothing is recorded, stored, or uploaded.

import {LAB_PROCESSORS, createLabVoiceNode as createVoiceNode} from "./processors"
import {spectrogram, drawSpectrogram} from "./spectrogram"
import {createDspPreview} from "./dsp/live"
import {createLivePreview} from "./live"
import {algorithmicLatencyMs, measureSeamLatencyMs} from "./measure"
import {setupMaskingRound} from "./round"
import {setupReviews} from "./review"
import {createRecoveryPlayback} from "./recovery_playback"
import {COMPARISON_PAUSE_SECONDS, joinComparisonBuffers} from "./comparison"
import {loadPreparedPair} from "./prepared"
import {testToneSamples} from "./test_tone"

const COMPARISON_IDS = ["round", "engines", "gentle", "envelope", "fargan", "fargan_mask", "fargan_combined", "bandwidth", "source_shape"]
const RATE = 48000
const $ = id => document.getElementById(id)
const processor = () => $("voice-lab-processor").value

const lab = {
  sources: [],
  params: {}, // processor -> {name: value}
  loop: false,
  modified: null,
  original: null,
  preparedModels: {},
  sourceIds: {},
  preparedAbort: null,
  preparing: null,
  revision: 0,
  startupIntent: 0,
  intent: 0,
  context: null,
  live: {controller: null, intent: 0, version: null},
  player: null, // {context, node, startedAt, offset, version}
  recoveryPlayers: [],
  recoveryPlayback: null,
  recoveryIntent: 0,
  modelPlayback: null,
  modelIntent: 0,
  reviews: null,
  round: null,
  engines: null,
  gentle: null,
}

function setStatus(text, state) {
  const status = $("voice-lab-status")
  status.textContent = text
  status.dataset.state = state
}

// A 4 s harmonic tone gliding 110 → 220 Hz: pitch shifts are plain to see.
function testTone() {
  const data = testToneSamples(RATE)
  const buffer = new AudioBuffer({length: data.length, sampleRate: RATE, numberOfChannels: 1})
  buffer.copyToChannel(data, 0)
  return buffer
}

async function loadSources(root) {
  const path = root.dataset.clipsPath
  const {clips} = await (await fetch(path)).json()
  const decoder = new OfflineAudioContext(1, 1, RATE)
  const decoded = await Promise.all(
    clips.map(async name => {
      const bytes = await (await fetch(`${path}/${name}`)).arrayBuffer()
      return {key: name, label: name === "mencken_wasichu.wav" ? "Wasichu — Mencken (2009)" : name.replace(/\.wav$/, "").replace(/_/g, " "), buffer: await decoder.decodeAudioData(bytes)}
    }),
  )
  return [...decoded, {key: "test_tone", label: "test tone (110 → 220 Hz glide)", buffer: testTone()}]
}

// Sliders from each processor's own parameterDescriptors (its AudioParams).
const PARAM_HELP = {
  alpha: {
    label: "Resonance coefficient",
    unit: "α",
    step: 0.01,
    help: "McAdams changes the angles of the resonances in a short-term vocal-tract model. Lower values make a larger, nonlinear change; this is not a pitch slider or a percentage. 1.0 skips resonance changes but still applies the bandwidth/resampling step. The benchmark tested 0.7 and 0.9: a model could still match speakers to known recordings. The Recovery test tab separately lets you hear an approximate attempt to restore the original sound.",
    format: value => `α ${Number(value).toFixed(2)}`,
  },
  semitones: {
    label: "Pitch",
    unit: "semitones",
    step: 0.5,
    help: "One semitone is one piano-key step. Negative values lower the voice; positive values raise it. Zero keeps the original pitch. Try −4, then +4, and compare with the original.",
    format: value => `${value > 0 ? "+" : ""}${Number(value).toFixed(1)} semitones`,
  },
  window_ms: {
    label: "Audio slice length",
    unit: "ms",
    step: 1,
    help: "The pitch shifter blends short, overlapping pieces of audio. This controls their length. Larger values change the texture and usually add more delay; they are not always better. Start at 40 ms and change pitch first.",
    format: value => `${Number(value).toFixed(1)} ms`,
  },
}

async function buildParams(isCurrent) {
  const container = $("voice-lab-params")
  const probe = new OfflineAudioContext(1, 128, RATE)
  for (const {value: name} of $("voice-lab-processor").options) {
    lab.params[name] = {}
    if (LAB_PROCESSORS[name]?.preRendered) continue
    const node = await createVoiceNode(probe, name)
    if (!isCurrent()) { node.disconnect(); return false }
    const parameters = [...node.parameters].sort(([a], [b]) => Number(b === "semitones") - Number(a === "semitones"))
    for (const [param, audioParam] of parameters) {
      lab.params[name][param] = Number(audioParam.defaultValue.toFixed(3))
      const help = PARAM_HELP[param]
      const id = `voice-lab-param-${name}-${param}`
      const row = document.createElement("div")
      row.className = "min-w-0 space-y-2"
      row.dataset.processor = name
      row.innerHTML = `<label class="block text-sm font-medium"></label>
        <div class="flex items-center gap-2">
          <input type="range" class="min-w-0 flex-1 accent-teal-700">
          <button type="button" data-decrease class="size-9 shrink-0 rounded-md border border-stone-300 transition hover:bg-stone-100 disabled:opacity-40">−</button>
          <input type="number" class="w-20 rounded-md border border-stone-300 bg-white px-2 py-1.5 text-sm tabular-nums text-stone-950 focus:outline-2 focus:outline-teal-700">
          <button type="button" data-increase class="size-9 shrink-0 rounded-md border border-stone-300 transition hover:bg-stone-100 disabled:opacity-40">+</button>
        </div>
        <details class="text-sm text-stone-600"><summary class="cursor-pointer"></summary><p class="mt-1"></p></details>`
      const label = row.querySelector("label")
      label.htmlFor = id
      label.textContent = `${help?.label ?? param.replace(/_/g, " ")} (${help?.unit ?? "value"})`
      const description = row.querySelector("p")
      description.id = `${id}-help`
      description.textContent = help?.help ?? "Change this setting, then play the modified sample to compare."
      row.querySelector("summary").textContent = `About ${help?.label.toLowerCase() ?? param}`
      const input = row.querySelector("input[type=range]")
      const number = row.querySelector("input[type=number]")
      const decrease = row.querySelector("[data-decrease]")
      const increase = row.querySelector("[data-increase]")
      const step = help?.step ?? (audioParam.maxValue - audioParam.minValue) / 48
      for (const control of [input, number]) {
        control.min = audioParam.minValue
        control.max = audioParam.maxValue
        control.step = step
        control.value = audioParam.defaultValue
        control.setAttribute("aria-describedby", description.id)
      }
      input.id = id
      number.id = `${id}-number`
      number.setAttribute("aria-label", `${help?.label ?? param} value in ${help?.unit ?? "units"}`)
      decrease.setAttribute("aria-label", `Decrease ${help?.label.toLowerCase() ?? param}`)
      increase.setAttribute("aria-label", `Increase ${help?.label.toLowerCase() ?? param}`)
      input.dataset.processor = name
      input.dataset.param = param
      function sync(preserveNumber = false) {
        const value = lab.params[name][param]
        input.value = value
        if (!preserveNumber) number.value = value
        input.setAttribute("aria-valuetext", help?.format(value) ?? String(value))
        decrease.disabled = value <= audioParam.minValue
        increase.disabled = value >= audioParam.maxValue
      }
      function update(value, preserveNumber = false) {
        if (!Number.isFinite(value)) { sync(); return }
        const bounded = Math.max(audioParam.minValue, Math.min(audioParam.maxValue, value))
        const next = Number((audioParam.minValue + Math.round((bounded - audioParam.minValue) / step) * step).toFixed(3))
        if (next !== lab.params[name][param]) {
          lab.params[name][param] = next
          invalidate("Settings changed. Press Play modified to hear them.")
        }
        sync(preserveNumber)
      }
      input.addEventListener("input", () => update(input.valueAsNumber))
      number.addEventListener("input", () => {
        if (number.value !== "" && number.validity.valid) update(number.valueAsNumber, true)
      })
      number.addEventListener("change", () => update(number.valueAsNumber))
      decrease.addEventListener("click", () => update(lab.params[name][param] - step))
      increase.addEventListener("click", () => update(lab.params[name][param] + step))
      sync()
      container.append(row)
    }
    node.disconnect()
  }
  if (!isCurrent()) return false
  showParams()
  return true
}

function showParams() {
  const name = processor()
  const rows = [...$("voice-lab-params").children]
  for (const row of rows) row.hidden = row.dataset.processor !== name
  const empty = !rows.some(row => !row.hidden)
  $("voice-lab-params").hidden = empty
  $("voice-lab-parameter-hint").hidden = empty
  const note = $("voice-lab-processor-note")
  note.textContent = LAB_PROCESSORS[name]?.note ?? "Changes pitch and vocal resonances together. Known-recording matching still recognizes speakers, including after shifting back. Listen separately for naturalness and how different the voice sounds."
}

function source() {
  return lab.sources.find(item => item.key === $("voice-lab-source").value)
}

function preparedCase() {
  const item = lab.preparedModels[processor()]?.[source()?.key]
  return item?.context.source_id === lab.sourceIds[source()?.key] ? item : null
}

function reference() {
  return lab.original ?? source()
}

function listenContext(sourceIds, root) {
  const item = preparedCase()
  if (LAB_PROCESSORS[processor()]?.preRendered) {
    return item ? {context: item.context, label: `${source().label} · ${LAB_PROCESSORS[processor()].label} · pre-rendered experiment`} : null
  }
  return {
    context: {view: "listen", mode: "forward", sample: source().key, source_id: sourceIds[source().key], processor: processor(), parameters: {...lab.params[processor()]}, build_id: root.dataset.reviewBuild},
    label: `${source().label} · ${LAB_PROCESSORS[processor()].label} · ${Object.entries(lab.params[processor()]).map(([key, value]) => PARAM_HELP[key]?.format(value) ?? value).join(", ")}`,
  }
}

async function renderThrough(name, inputBuffer, params) {
  const tail = LAB_PROCESSORS[name]?.tailSamples ?? 0
  const context = new OfflineAudioContext(1, inputBuffer.length + tail, RATE)
  const node = await createVoiceNode(context, name)
  for (const [param, value] of Object.entries(params)) node.parameters.get(param)?.setValueAtTime(value, 0)
  const input = context.createBufferSource()
  if (tail) {
    // Keep the source connected with trailing zeros so the causal processor
    // emits the end of the clip. Retain its audible delay for lab comparison.
    const padded = context.createBuffer(1, inputBuffer.length + tail, RATE)
    padded.copyToChannel(inputBuffer.getChannelData(0), 0)
    input.buffer = padded
  } else {
    input.buffer = inputBuffer
  }
  input.connect(node).connect(context.destination)
  input.start()
  const started = performance.now()
  const buffer = await context.startRendering()
  return {buffer, realTimeFactor: (performance.now() - started) / 1000 / inputBuffer.duration}
}

function drawResult(version, result) {
  const card = $(`voice-lab-result-${version}`)
  const canvas = card.querySelector("canvas")
  const duration = card.querySelector("[data-duration]")
  const metrics = card.querySelector("[data-metrics]")
  card.querySelector("[data-result-title]").textContent = result?.title ?? (version === "original" ? "Original" : "Modified")
  card.dataset.playbackLabel = result?.playLabel ?? version
  canvas.setAttribute("aria-label", `${result?.title ?? version} spectrogram: time left to right, frequency bottom to top`)
  delete card.dataset.realTimeFactor
  delete card.dataset.latencyMs
  card.querySelector("[data-description]").textContent = result?.description ?? (version === "original" ? "The sample exactly as it was supplied." : "The selected modification, with your settings.")
  if (!result) {
    canvas.getContext("2d").clearRect(0, 0, canvas.width, canvas.height)
    duration.textContent = LAB_PROCESSORS[processor()]?.preRendered && !preparedCase() ? "No prepared output for this sample" : "Preparing sample…"
    metrics.textContent = ""
    return
  }
  drawSpectrogram(canvas, spectrogram(result.buffer))
  duration.textContent = `${result.buffer.duration.toFixed(1)} seconds →`
  if (result.realTimeFactor !== undefined) {
    card.dataset.realTimeFactor = result.realTimeFactor.toFixed(4)
    card.dataset.latencyMs = String(result.latencyMs)
    metrics.textContent = `Render time: ${(result.realTimeFactor * 100).toFixed(2)}% of clip duration · signal delay ≈ ${result.latencyMs} ms`
  } else {
    metrics.textContent = result.metrics ?? "Unchanged reference"
  }
}

function invalidate(message) {
  stop()
  lab.preparedAbort?.abort()
  lab.preparedAbort = null
  lab.revision++
  lab.preparing = null
  lab.modified = null
  lab.original = null
  $("voice-lab-result-modified").dataset.processor = processor()
  const offline = LAB_PROCESSORS[processor()]?.preRendered
  const available = !offline || !!preparedCase()
  $("voice-lab-processor-note").textContent = preparedCase()?.note || LAB_PROCESSORS[processor()]?.note || ""
  $("voice-lab-play").disabled = !available
  $("voice-lab-play-comparison").disabled = !available
  drawResult("original", offline && available ? null : source())
  drawResult("modified", null)
  updatePlayback(null)
  setStatus(available ? message : "No prepared output for this sample and modification. Regenerate the experiment, reload, or choose another modification.", available ? "ready" : "unavailable")
  lab.reviews?.refresh()
}

// Cache only the current source/settings. A stale render may finish, but cannot
// update the current comparison or start playback after Stop or a tab change.
async function prepare() {
  if (lab.modified) return lab.modified
  if (lab.preparing) return lab.preparing
  const revision = lab.revision
  const selected = source()
  const name = processor()
  if (LAB_PROCESSORS[name]?.preRendered && !preparedCase()) return null
  const params = {...lab.params[name]}
  setStatus("Preparing the modified sample…", "rendering")
  const pending = (async () => {
    let result, original
    if (LAB_PROCESSORS[name]?.preRendered) {
      const abort = new AbortController()
      lab.preparedAbort = abort
      const pair = await loadPreparedPair(preparedCase(), abort.signal)
      result = pair.modified
      original = pair.original
    } else {
      result = await renderThrough(name, selected.buffer, params)
      result.latencyMs = algorithmicLatencyMs(selected.buffer, result.buffer)
    }
    if (revision !== lab.revision) return null
    if (original) {
      lab.original = original
      drawResult("original", original)
    }
    lab.modified = result
    drawResult("modified", result)
    updatePlayback(lab.player?.version ?? null)
    setStatus(`Prepared “${selected.label}”. Play either version to compare.`, "rendered")
    return result
  })()
  lab.preparing = pending
  try {
    return await pending
  } catch (error) {
    if (revision === lab.revision) setStatus(`Could not prepare audio: ${error.message}. Try again or play the original.`, "failed")
    return null
  } finally {
    if (lab.preparing === pending) {
      lab.preparing = null
    }
  }
}

function position(target) {
  const player = lab.player
  if (!player) return 0
  const elapsed = player.offset + player.context.currentTime - player.startedAt
  const at = lab.loop ? elapsed % player.node.buffer.duration : elapsed
  if (!player.comparisonBoundary) return at
  const duration = target === "modified" ? lab.modified.buffer.duration : reference().buffer.duration
  if (at >= player.comparisonBoundary) return Math.min(at - player.comparisonBoundary, duration)
  const originalEnd = player.comparisonBoundary - COMPARISON_PAUSE_SECONDS
  if (at >= originalEnd) return target === "modified" ? 0 : originalEnd
  return Math.min(at, duration)
}

function updatePlayback(version) {
  const root = $("voice-lab")
  if (!root) return
  root.dataset.playing = version ?? "none"
  for (const [key, id] of [["original", "voice-lab-play-original"], ["modified", "voice-lab-play"], ["comparison", "voice-lab-play-comparison"]]) {
    const button = $(id)
    button.setAttribute("aria-pressed", String(version === key))
    const original = $("voice-lab-result-original").dataset.playbackLabel ?? "original"
    const modified = $("voice-lab-result-modified").dataset.playbackLabel ?? "modified"
    const label = key === "comparison" ? `${original} → ${modified}` : key === "original" ? original : modified
    button.querySelector("[data-play-label]").textContent = `${version === key ? "Stop" : "Play"} ${label}`
    button.querySelector("[data-play-icon]").hidden = version === key
    button.querySelector("[data-stop-icon]").hidden = version !== key
  }
}

async function play(version) {
  stopRecovery()
  stopLive()
  if (lab.player?.version === version) {
    stop()
    return
  }
  const intent = ++lab.intent
  const offset = version === "comparison" ? 0 : position(version)
  lab.player?.node.stop()
  lab.player = null
  updatePlayback(null)
  // Create/resume in the click gesture, before awaiting offline preparation.
  const context = lab.context ?? new AudioContext()
  lab.context = context
  $("voice-lab-stop").disabled = false
  try {
    await context.resume()
    if (intent !== lab.intent) return
    let result
    if (LAB_PROCESSORS[processor()]?.preRendered && preparedCase()) {
      const prepared = await prepare()
      result = prepared ? (version === "original" ? reference() : prepared) : null
    } else {
      result = version === "original" ? reference() : await prepare()
    }
    if (intent !== lab.intent) return
    if (!result) {
      stop()
      return
    }
    let comparisonBoundary = null
    if (version === "comparison") {
      const original = reference().buffer
      const joined = joinComparisonBuffers(context, [original, result.buffer])
      comparisonBoundary = original.duration + COMPARISON_PAUSE_SECONDS
      result = {buffer: joined}
    }
    if (!lab.loop && offset >= result.buffer.duration) {
      stop()
      return
    }
    const start = lab.loop ? offset % result.buffer.duration : offset
    const node = context.createBufferSource()
    node.buffer = result.buffer
    node.loop = lab.loop
    node.onended = () => {
      if (lab.player?.node !== node) return
      lab.player = null
      stop()
    }
    node.connect(context.destination)
    node.start(0, start)
    lab.player = {context, node, startedAt: context.currentTime, offset: start, version, comparisonBoundary}
    updatePlayback(version)
  } catch (error) {
    if (intent !== lab.intent) return
    stop()
    setStatus(`Could not play audio: ${error.message}. Try again.`, "failed")
  }
}

function toggleLoop() {
  if (lab.player) {
    const player = lab.player
    const now = player.context.currentTime
    player.offset = (player.offset + now - player.startedAt) % player.node.buffer.duration
    player.startedAt = now
  }
  lab.loop = !lab.loop
  const button = $("voice-lab-loop")
  button.setAttribute("aria-pressed", String(lab.loop))
  button.querySelector("[data-loop-label]").textContent = lab.loop ? "Loop on" : "Loop off"
  if (lab.player) lab.player.node.loop = lab.loop
}

function stop() {
  lab.intent++
  lab.player?.node.stop()
  lab.player = null
  lab.context?.close().catch(() => {})
  lab.context = null
  const button = $("voice-lab-stop")
  if (button) button.disabled = true
  updatePlayback(null)
}

// Navigation can remove the ignored lab DOM before another global event fires.
function leave() {
  lab.startupIntent++
  lab.revision++
  lab.preparing = null
  lab.preparedAbort?.abort()
  stop()
  stopLive()
  stopRecovery()
  for (const id of COMPARISON_IDS) lab[id]?.leave()
}

const DSP_PROFILES = {
  lower_mild: {pitch: -2, scale: .9},
  lower_resonance: {pitch: -2, scale: .8},
  higher_mild: {pitch: 2, scale: 1.1},
  higher_resonance: {pitch: 2, scale: 1.25},
}
function liveDspSettings() {
  const base = DSP_PROFILES[$("voice-lab-live-profile").value]
  const factor = {current_pitch: 1, half_pitch: .5, zero_pitch: 0}[$("voice-lab-live-pitch-strength").value]
  return {pitch: factor ? base.pitch * factor : 0, scale: base.scale}
}
const dspMode = () => $("voice-lab-live-mode").value === "dsp"
function showLiveSettings() {
  const dsp = dspMode()
  $("voice-lab-live-dsp-settings").hidden = !dsp
  $("voice-lab-live-dsp-metrics").hidden = !dsp
  $("voice-lab-live-settings-link").hidden = dsp
  if (dsp) {
    $("voice-lab-live-modified").disabled = false
    const spectral = $("voice-lab-live-engine").value === "spectral"
    $("voice-lab-live-buffer-experiment").hidden = !spectral
    if (!spectral) $("voice-lab-live-buffering").value = "baseline"
    const setting = liveDspSettings()
    $("voice-lab-live-settings").textContent = `${$("voice-lab-live-engine").selectedOptions[0].textContent}: pitch ${setting.pitch > 0 ? '+' : ''}${setting.pitch} semitones, resonances ×${setting.scale.toFixed(2)}. No recording or upload.`
    return
  }
  const name = processor()
  const offline = LAB_PROCESSORS[name]?.preRendered
  $("voice-lab-live-modified").disabled = !!offline
  if (offline) {
    $("voice-lab-live-settings").textContent = "This option plays prepared public recordings only. Choose Pitch shift or McAdams in Listen & compare for a modified live microphone preview. Original microphone preview is available."
    return
  }
  const params = lab.params[name]
  if (!params) return
  const values = Object.entries(params).map(([key, value]) => PARAM_HELP[key]?.format(value) ?? `${key}: ${value}`).join(", ")
  $("voice-lab-live-settings").textContent = `Modified preview: ${LAB_PROCESSORS[name].label}, ${values}. Change these in Listen & compare before starting. ${LAB_PROCESSORS[name].note ?? ""}`
}

function updateLive(version) {
  const root = $("voice-lab")
  if (!root) return
  root.dataset.live = version ?? "none"
  for (const key of ["original", "modified"]) {
    const button = $(`voice-lab-live-${key}`)
    button.setAttribute("aria-pressed", String(key === version))
    button.querySelector("[data-live-label]").textContent = `${key === version ? "Stop" : "Hear"} ${key}`
    button.querySelector("[data-live-play-icon]").hidden = key === version
    button.querySelector("[data-live-stop-icon]").hidden = key !== version
  }
}

function stopLive(message = "Microphone off.") {
  lab.live.intent++
  lab.live.controller?.close()
  lab.live.controller = null
  lab.live.version = null
  if (!$("voice-lab")) return
  updateLive(null)
  $("voice-lab-live-stop").disabled = true
  const status = $("voice-lab-live-status")
  status.textContent = message
  status.dataset.state = "idle"
  $("voice-lab-live-dsp-metrics").textContent = ""
  delete $("voice-lab-live-dsp-metrics").dataset.delaySamples
}

async function playLive(version) {
  stopRecovery()
  stop()
  if (lab.live.controller) {
    if (lab.live.version === version) {
      stopLive()
    } else {
      lab.live.version = version
      lab.live.controller.setModified(version === "modified")
      if ($("voice-lab-live-status").dataset.state === "monitoring") {
        updateLive(version)
        $("voice-lab-live-status").textContent = `Microphone on. Listening to your ${version} voice through headphones.`
      }
    }
    return
  }
  const intent = ++lab.live.intent
  lab.live.version = version
  const status = $("voice-lab-live-status")
  status.dataset.state = "starting"
  status.textContent = "Waiting for microphone permission and preparing playback… Stop cancels this request."
  $("voice-lab-live-stop").disabled = false
  try {
    const callbacks = {
      modified: version === "modified",
      onEnded: () => stopLive("Microphone disconnected. Choose a version to try again."),
      onFailure(error) {
        if (intent !== lab.live.intent) return
        stopLive()
        status.dataset.state = "failed"
        status.textContent = `Microphone preview stopped: ${error.message}. No original-voice fallback was used.`
      },
    }
    const controller = dspMode() ? createDspPreview({
      ...callbacks, engine: $("voice-lab-live-engine").value, ...liveDspSettings(),
      prefillSamples: $("voice-lab-live-buffering").value === "short" ? 3840 : 7680,
      onStats(data) {
        if (intent !== lab.live.intent) return
        const metrics = $("voice-lab-live-dsp-metrics")
        if (data.type === "buffering") metrics.textContent = "Filling the masked playback buffer… Original monitoring is immediate; modified monitoring is delayed."
        else if (data.delaySamples !== null && data.delaySamples !== undefined) {
          metrics.textContent = `Modified audio buffering: ${(data.delaySamples / 48).toFixed(0)} ms, plus microphone/device playback delay.` + (data.maxPendingSamples !== undefined ? ` Pending input peak: ${(data.maxPendingSamples / 48).toFixed(0)} ms.` : "")
          metrics.dataset.delaySamples = String(data.delaySamples)
        }
      },
    }) : createLivePreview({
      ...callbacks,
      processor: version === "original" && LAB_PROCESSORS[processor()]?.preRendered ? "pitch_shift" : processor(),
      params: lab.params[processor()],
    })
    lab.live.controller = controller
    const ready = await controller.ready
    if (intent !== lab.live.intent || !ready) return
    updateLive(lab.live.version)
    status.dataset.state = "monitoring"
    status.textContent = `Microphone on. Listening to your ${lab.live.version} voice through headphones.`
  } catch (error) {
    if (intent !== lab.live.intent) return
    stopLive()
    status.dataset.state = "failed"
    status.textContent = error.name === "NotAllowedError"
      ? "Microphone permission was not granted. Allow it in your browser and try again."
      : `Could not start the microphone preview: ${error.message}. You can try again.`
  }
}

function showLabView(id) {
  const select = $("voice-lab-view")
  select.value = id
  select.dispatchEvent(new Event("change", {bubbles: true}))
}

function setupViews() {
  const select = $("voice-lab-view")
  select.addEventListener("change", () => {
    const id = select.value
    if (id !== "listen") stop()
    if (id !== "voice") stopLive()
    stopRecovery()
    if (id === "voice") showLiveSettings()
    lab.reviews?.refresh()
    for (const option of select.options) $("voice-lab-panel-" + option.value).hidden = option.value !== id
  })
  select.dataset.ready = "true"
}

function stopRecoverySequence(message = "") {
  lab.recoveryIntent++
  lab.recoveryPlayback?.close()
  lab.recoveryPlayback = null
  const button = $("voice-lab-recovery-play-all")
  if (!button) return
  button.setAttribute("aria-pressed", "false")
  button.querySelector("[data-play-icon]").hidden = false
  button.querySelector("[data-stop-icon]").hidden = true
  button.querySelector("[data-play-label]").textContent = "Play all: original → disguised → recovered"
  $("voice-lab-recovery-playback-status").textContent = message
  $("voice-lab-recovery-playback-status").dataset.state = "idle"
}

function stopModelSequence(message = "") {
  lab.modelIntent++
  lab.modelPlayback?.close()
  lab.modelPlayback = null
  const button = $("voice-lab-model-play-all")
  if (!button) return
  button.setAttribute("aria-pressed", "false")
  button.querySelector("[data-play-icon]").hidden = false
  button.querySelector("[data-stop-icon]").hidden = true
  button.querySelector("[data-play-label]").textContent = "Play original → converted"
  $("voice-lab-model-status").textContent = message
}

function stopRecovery() {
  for (const id of COMPARISON_IDS) lab[id]?.stop()
  stopRecoverySequence()
  stopModelSequence()
  for (const player of lab.recoveryPlayers) player.pause()
}

async function playRecoverySequence() {
  if (lab.recoveryPlayback) {
    stopRecovery()
    return
  }
  stop()
  stopLive()
  stopRecovery()
  const intent = lab.recoveryIntent
  const item = $("voice-lab-recovery").querySelector("[data-recovery-case]:not([hidden])")
  const urls = ["original", "disguised", "recovered"].map(version => item.querySelector(`[data-recovery-version=${version}] source`).src)
  const button = $("voice-lab-recovery-play-all")
  const status = $("voice-lab-recovery-playback-status")
  button.setAttribute("aria-pressed", "true")
  button.querySelector("[data-play-icon]").hidden = true
  button.querySelector("[data-stop-icon]").hidden = false
  button.querySelector("[data-play-label]").textContent = "Stop comparison"
  status.textContent = "Preparing the three recordings… Stop cancels playback."
  status.dataset.state = "loading"
  try {
    const controller = createRecoveryPlayback({
      urls, loop: $("voice-lab-recovery-loop").checked,
      onEnded: () => { if (intent === lab.recoveryIntent) stopRecoverySequence("Comparison finished.") },
    })
    lab.recoveryPlayback = controller
    if (!await controller.ready || intent !== lab.recoveryIntent) return
    status.textContent = "Playing original → disguised → recovered. Loop repeats the whole comparison."
    status.dataset.state = "playing"
  } catch (error) {
    if (intent !== lab.recoveryIntent) return
    stopRecoverySequence(`Could not play the comparison: ${error.message}`)
    status.dataset.state = "failed"
  }
}

function setupRecovery() {
  lab.recoveryPlayers = [...$("voice-lab").querySelectorAll("[data-recovery-audio]")]
  for (const player of lab.recoveryPlayers) {
    player.addEventListener("play", () => {
      stop()
      stopLive()
      stopRecoverySequence()
      stopModelSequence()
      for (const id of COMPARISON_IDS) lab[id]?.stop()
      for (const other of lab.recoveryPlayers) if (other !== player) other.pause()
    })
  }
  $("voice-lab-recovery-stop")?.addEventListener("click", stopRecovery)
  $("voice-lab-recovery-play-all")?.addEventListener("click", playRecoverySequence)
  for (const details of $("voice-lab-recovery").querySelectorAll("details")) {
    details.addEventListener("toggle", () => {
      if (!details.open) for (const player of details.querySelectorAll("audio")) player.pause()
    })
  }
  $("voice-lab-recovery-loop")?.addEventListener("change", event => {
    lab.recoveryPlayback?.setLoop(event.target.checked)
    for (const player of $("voice-lab-recovery").querySelectorAll("audio")) player.loop = event.target.checked
  })
  $("voice-lab-recovery-choice")?.addEventListener("change", event => {
    stopRecovery()
    for (const item of $("voice-lab-recovery").querySelectorAll("[data-recovery-case]")) {
      item.hidden = item.dataset.recoveryCase !== event.target.value
    }
    lab.reviews?.refresh()
  })
}

function setupModelExperiment() {
  const choice = $("voice-lab-model-choice")
  if (!choice) return
  function select() {
    stopRecovery()
    for (const item of $("voice-lab-models").querySelectorAll("[data-model-case]")) {
      item.hidden = item.dataset.modelCase !== choice.value
      if (!item.hidden) $("voice-lab-model-play-all").disabled = item.dataset.ready !== "true"
    }
    lab.reviews?.refresh()
  }
  choice.addEventListener("change", select)
  $("voice-lab-model-loop").addEventListener("change", event => {
    lab.modelPlayback?.setLoop(event.target.checked)
    for (const player of $("voice-lab-models").querySelectorAll("audio")) player.loop = event.target.checked
  })
  $("voice-lab-model-play-all").addEventListener("click", async () => {
    if (lab.modelPlayback) { stopRecovery(); return }
    stop()
    stopLive()
    stopRecovery()
    const intent = lab.modelIntent
    const item = $("voice-lab-models").querySelector("[data-model-case]:not([hidden])")
    if (item?.dataset.ready !== "true") return
    const button = $("voice-lab-model-play-all")
    const status = $("voice-lab-model-status")
    button.setAttribute("aria-pressed", "true")
    button.querySelector("[data-play-icon]").hidden = true
    button.querySelector("[data-stop-icon]").hidden = false
    button.querySelector("[data-play-label]").textContent = "Stop comparison"
    status.textContent = "Preparing original → converted… Stop cancels playback."
    try {
      const controller = createRecoveryPlayback({
        urls: [...item.querySelectorAll("audio source")].map(source => source.src),
        loop: $("voice-lab-model-loop").checked,
        onEnded: () => { if (intent === lab.modelIntent) stopModelSequence("Comparison finished.") },
      })
      lab.modelPlayback = controller
      if (!await controller.ready || intent !== lab.modelIntent) return
      status.textContent = "Playing original → converted, with a short pause between recordings."
    } catch (error) {
      if (intent === lab.modelIntent) stopModelSequence(`Could not play comparison: ${error.message}`)
    }
  })
  select()
}

async function measure() {
  const button = $("voice-lab-measure")
  const result = $("voice-lab-seam-result")
  button.disabled = true
  result.dataset.state = "measuring"
  result.textContent = "Measuring for 3 seconds…"
  try {
    const ms = await measureSeamLatencyMs("passthrough")
    result.dataset.state = "measured"
    result.dataset.latencyMs = String(ms)
    result.textContent = `The unchanged-copy processing step adds approximately ${ms} ms in this run. A voice modification adds its own delay on top.`
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
  const startupIntent = ++lab.startupIntent
  const isCurrent = () => startupIntent === lab.startupIntent && $("voice-lab") === root && root.isConnected
  window.addEventListener("pagehide", leave)
  document.addEventListener("phx:page-loading-start", leave)
  try {
    setupViews()
    setupRecovery()
    setupModelExperiment()
    lab.preparedModels = JSON.parse(root.dataset.preparedModels)
    lab.sourceIds = JSON.parse(root.dataset.reviewSources)
    setStatus("Loading samples…", "loading")
    const sources = await loadSources(root)
    if (!isCurrent()) return
    lab.sources = sources
    const select = $("voice-lab-source")
    for (const item of lab.sources) select.append(new Option(item.label, item.key))
    if (!await buildParams(isCurrent) || !isCurrent()) return
    for (const id of COMPARISON_IDS) lab[id] = setupMaskingRound({
      id, sources: lab.sources, sourceIds: lab.sourceIds,
      stopOthers: () => { stop(); stopLive(); stopRecovery() },
      reviewChanged: () => lab.reviews?.refresh(),
      tryLive(engine, profile, strength = "current_pitch") {
        stopLive()
        $("voice-lab-live-mode").value = "dsp"
        $("voice-lab-live-engine").value = engine
        $("voice-lab-live-profile").value = profile
        $("voice-lab-live-pitch-strength").value = strength
        $("voice-lab-live-buffering").value = "baseline"
        showLabView("voice")
      },
    })
    try {
      const sourceIds = JSON.parse(root.dataset.reviewSources)
      lab.reviews = setupReviews({listenContext: () => listenContext(sourceIds, root), comparisonContexts: Object.fromEntries(COMPARISON_IDS.map(id => [id, () => lab[id]?.context()]))})
    } catch {
      for (const status of root.querySelectorAll("[data-review-status]")) status.textContent = "Review forms could not start. Playback is still available; reload to retry."
    }
    $("voice-lab-processor").addEventListener("change", () => {
      stopLive()
      showParams()
      invalidate("Modification changed. Preparing its spectrogram…")
      prepare()
    })
    select.addEventListener("change", () => {
      showParams()
      invalidate("Sample changed. Preparing its modified spectrogram…")
      prepare()
    })
    $("voice-lab-play-original").addEventListener("click", () => play("original"))
    $("voice-lab-play").addEventListener("click", () => play("modified"))
    $("voice-lab-play-comparison").addEventListener("click", () => play("comparison"))
    $("voice-lab-stop").addEventListener("click", stop)
    $("voice-lab-loop").addEventListener("click", toggleLoop)
    $("voice-lab-measure").addEventListener("click", measure)
    for (const version of ["original", "modified"]) {
      const button = $(`voice-lab-live-${version}`)
      button.addEventListener("click", () => playLive(version))
      button.disabled = false
    }
    for (const id of ["voice-lab-live-mode", "voice-lab-live-engine", "voice-lab-live-profile", "voice-lab-live-pitch-strength", "voice-lab-live-buffering"]) $(id).addEventListener("change", () => {
      stopLive("Settings changed. Choose a version to restart the microphone.")
      showLiveSettings()
    })
    $("voice-lab-live-stop").addEventListener("click", () => stopLive())
    $("voice-lab-live-settings-link").addEventListener("click", () => showLabView("listen"))
    $("voice-lab-play-original").disabled = false
    $("voice-lab-play").disabled = false
    $("voice-lab-play-comparison").disabled = false
    invalidate("Preparing the first sample’s modified spectrogram…")
    prepare()
  } catch (error) {
    if (isCurrent()) setStatus(`The lab couldn't start: ${error.message}`, "failed")
  }
}

start()
