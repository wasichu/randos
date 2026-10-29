// A bounded five-way audition; all playback joins the lab's single owner.
import {createRecoveryPlayback} from './recovery_playback'

export function setupMaskingRound({id = "round", sources, sourceIds, stopOthers, reviewChanged, tryLive}) {
  const root = document.getElementById(`voice-lab-${id}`)
  if (!root) return null
  const report = JSON.parse(root.dataset.round)
  const countWord = ({3:'three',4:'four',5:'five'})[report.variants.length]
  const allLabel = `Play all ${countWord}`
  const select = root.querySelector(`#voice-lab-${id}-source`)
  const status = root.querySelector(`#voice-lab-${id}-status`)
  const all = root.querySelector(`#voice-lab-${id}-all`)
  const stopButton = root.querySelector(`#voice-lab-${id}-stop`)
  const loop = root.querySelector(`#voice-lab-${id}-loop`)
  const rows = [...root.querySelectorAll('[data-round-row]')]
  const variants = report.variants.map(item => item.id)
  let current = null, buffers = null, abort = null, revision = 0, intent = 0, player = null, playing = null, activeKey = null
  for (const source of sources) select.append(new Option(source.label, source.key))

  function highlight(key) {
    activeKey = key
    for (const row of rows) {
      const active = row.dataset.roundRow === key
      row.dataset.active = String(active)
      const button = row.querySelector('[data-round-play]')
      button.setAttribute('aria-pressed', String(active))
      button.setAttribute('aria-label', `${active ? 'Stop' : 'Play'} ${report.variants.find(item => item.id === row.dataset.roundRow).label}`)
      button.querySelector('[data-play-icon]').hidden = active
      button.querySelector('[data-stop-icon]').hidden = !active
    }
  }
  function stop(message = '') {
    intent++
    player?.close()
    player = null
    playing = null
    stopButton.disabled = true
    all.setAttribute('aria-pressed', 'false')
    all.querySelector('[data-play-icon]').hidden = false
    all.querySelector('[data-stop-icon]').hidden = true
    all.querySelector('[data-play-label]').textContent = allLabel
    root.dataset.playing = ''
    highlight(null)
    if (status.dataset.state === 'playing' || status.dataset.state === 'starting') {
      status.dataset.state = buffers ? 'ready' : 'loading'
      status.textContent = message || `Stopped. Choose another version or play all ${countWord}.`
    }
  }
  function draw(canvas, buffer, peak) {
    const context = canvas.getContext('2d'), x = buffer.getChannelData(0)
    context.clearRect(0, 0, canvas.width, canvas.height)
    context.strokeStyle = document.documentElement.dataset.theme === 'dark' ? '#5eead4' : '#0f766e'
    const scale = 15 / Math.max(peak, 1e-9)
    context.beginPath()
    for (let i = 0; i < canvas.width; i++) {
      const lo = Math.floor(i * x.length / canvas.width), hi = Math.floor((i + 1) * x.length / canvas.width)
      let low = 0, high = 0
      for (let j = lo; j < hi; j++) { low = Math.min(low, x[j]); high = Math.max(high, x[j]) }
      context.moveTo(i + .5, 16 - high * scale)
      context.lineTo(i + .5, 16 - low * scale)
    }
    context.stroke()
  }
  async function prepare() {
    stop()
    abort?.abort()
    const controller = new AbortController(), version = ++revision
    abort = controller
    current = null
    buffers = null
    for (const button of root.querySelectorAll(`[data-round-play], #voice-lab-${id}-all, [data-round-live]`)) button.disabled = true
    for (const row of rows) {
      row.querySelector('[data-round-description]').textContent = ''
      const canvas = row.querySelector('canvas')
      canvas.getContext('2d').clearRect(0, 0, canvas.width, canvas.height)
    }
    root.querySelector('[data-round-note]').hidden = true
    status.dataset.state = 'loading'
    status.textContent = `Preparing all ${countWord} versions…`
    reviewChanged()
    try {
      const item = report.cases[select.value]
      if (!item || item.context.source_id !== sourceIds[select.value]) throw Error('This source changed. Regenerate the masking round and reload.')
      const decoder = new OfflineAudioContext(1, 1, 48000)
      const loaded = await Promise.all(variants.map(async key => {
        const response = await fetch('/dev/voice-lab/models/' + encodeURIComponent(item.audio[key]), {signal: controller.signal})
        if (!response.ok) throw Error('A comparison clip is missing. Regenerate the round and reload.')
        const buffer = await decoder.decodeAudioData(await response.arrayBuffer())
        if (buffer.numberOfChannels !== 1 || buffer.sampleRate !== 48000 || buffer.length === 0) throw Error('Invalid comparison audio')
        return [key, buffer]
      }))
      if (version !== revision || !root.isConnected) return
      buffers = Object.fromEntries(loaded)
      current = item
      let previewPeak = 0
      for (const buffer of Object.values(buffers)) for (const sample of buffer.getChannelData(0)) previewPeak = Math.max(previewPeak, Math.abs(sample))
      for (const row of rows) {
        const key = row.dataset.roundRow
        row.querySelector('[data-round-description]').textContent = item.descriptions[key]
        draw(row.querySelector('canvas'), buffers[key], previewPeak)
      }
      for (const button of root.querySelectorAll(`[data-round-play], #voice-lab-${id}-all, [data-round-live]`)) button.disabled = false
      status.dataset.state = 'ready'
      const note = root.querySelector('[data-round-note]')
      note.textContent = item.note || ''
      note.hidden = !item.note
      status.textContent = (id === 'gentle' ? 'Ready. Resonance stays fixed; compare pitch movement.' : id === 'engines' ? 'Ready. Compare Original → Signalsmith → WORLD.' : (select.value === 'test_tone' ? 'Ready. The tone checks audio artifacts; judge voice masking on the speech samples.' : 'Ready. Start with Original → Current, then compare the stronger versions.'))
      reviewChanged()
    } catch (error) {
      if (version !== revision || error.name === 'AbortError' || !root.isConnected) return
      // Cancel sibling fetches after a missing clip; no partial comparison is exposed.
      controller.abort()
      status.dataset.state = 'failed'
      status.textContent = error.message
      reviewChanged()
    }
  }
  async function play(key) {
    if (!buffers) return
    if (player && (playing === key || activeKey === key)) { stop(); return }
    stopOthers()
    const version = ++intent, keys = key === 'all' ? variants : [key]
    playing = key
    root.dataset.playing = key
    status.dataset.state = 'starting'
    status.textContent = 'Preparing playback…'
    stopButton.disabled = false
    all.setAttribute('aria-pressed', String(key === 'all'))
    all.querySelector('[data-play-icon]').hidden = key === 'all'
    all.querySelector('[data-stop-icon]').hidden = key !== 'all'
    all.querySelector('[data-play-label]').textContent = key === 'all' ? 'Stop all' : allLabel
    try {
      const controller = createRecoveryPlayback({
        buffers: keys.map(id => buffers[id]), loop: loop.checked,
        onEnded: () => { if (version === intent) stop('Comparison finished.') },
        onClip: index => {
          if (version !== intent) return
          const id = keys[index]
          highlight(id)
          status.textContent = id ? `Playing: ${report.variants.find(item => item.id === id).label}` : 'Short pause…'
        },
      })
      player = controller
      if (!await controller.ready || version !== intent) return
      status.dataset.state = 'playing'
    } catch (error) {
      if (version !== intent) return
      stop()
      status.dataset.state = 'failed'
      status.textContent = `Could not play comparison: ${error.message}`
    }
  }
  select.addEventListener('change', prepare)
  all.addEventListener('click', () => play('all'))
  stopButton.addEventListener('click', () => stop())
  loop.addEventListener('change', () => player?.setLoop(loop.checked))
  for (const button of root.querySelectorAll('[data-round-play]')) button.addEventListener('click', () => play(button.dataset.roundPlay))
  for (const button of root.querySelectorAll('[data-round-live]')) button.addEventListener('click', () => { if(current){const variant=report.variants.find(item=>item.id===button.dataset.roundLive);tryLive?.(variant.engine??variant.id,current.profile,variant.pitch_strength??'current_pitch')} })
  prepare()
  return {
    stop,
    context: () => current ? {context: current.context, label: select.selectedOptions[0].textContent} : null,
    leave() { revision++; abort?.abort(); stop(); buffers = null; current = null },
  }
}
