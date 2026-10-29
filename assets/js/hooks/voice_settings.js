import {label} from '../randos/labels'
import {captureLocalAudio, stopStream} from '../randos/media'
import {createPreviewStream} from '../randos/voice/preview'
import {getChoice, setChoice, selectedMasking, ownAudition} from '../randos/voice/masking_choices'

export const VoiceSettings = {
  mounted() {
    this.labels = JSON.parse(this.el.dataset.labels)
    this.family = this.el.querySelector('#voice-family')
    this.tone = this.el.querySelector('#voice-tone')
    this.button = this.el.querySelector('#voice-preview')
    this.status = this.el.querySelector('#voice-preview-status')
    this.buttonLabel = this.button.querySelector('[data-voice-preview-label]')
    this.token = 0; this.open = false; this.raw = null; this.pipe = null; this.pending = Promise.resolve()
    this.abort = null; this.destroyedFlag = false; this.generation = 0
    const choice = getChoice(); this.family.value = choice.family; this.tone.value = choice.tone
    this.sync = () => {
      setChoice(this.family.value, this.tone.value)
      this.button.disabled = false
      this.tone.disabled = this.family.value === 'off'
      this.el.querySelector('#voice-tone-choice').hidden = this.family.value === 'off'
      this.form.classList.toggle('sm:grid-cols-2', this.family.value !== 'off')
      const style = this.family.selectedOptions[0].textContent
      this.el.querySelector('#voice-choice-label').textContent = this.family.value === 'off' ? style :
        label(this.labels, 'choice', '%{style} + %{tone}', {style, tone: this.tone.selectedOptions[0].textContent})
      if (this.open && this.raw) void this.rebuild(this.token)
    }
    this.family.addEventListener('change', this.sync); this.tone.addEventListener('change', this.sync)
    this.click = () => this.open ? void this.stop() : void this.start()
    this.button.addEventListener('click', this.click)
    this.form = this.el.querySelector('form'); this.prevent = event => event.preventDefault()
    this.form.addEventListener('submit', this.prevent)
    this.unregister = ownAudition(() => this.stop())
    this.pagehide = () => void this.stop()
    window.addEventListener('pagehide', this.pagehide)
    // Stop synchronously, then let LiveView queue/join only after cleanup.
    this.forwarding = new WeakSet()
    this.forwardIntent = null
    this.forwardAfterStop = (target, activate) => {
      if (this.forwardIntent) return
      const intent = {}; this.forwardIntent = intent
      const cleanup = this.stop(), token = this.token
      void cleanup.then(() => {
        // Native form/click activation rejects re-entry, including during a
        // microtask checkpoint. Resume in a new task after cleanup settles.
        setTimeout(() => {
          if (this.forwardIntent !== intent) return
          this.forwardIntent = null
          if (this.destroyedFlag || token !== this.token || !target.isConnected) return
          this.forwarding.add(target)
          try { activate() } finally { this.forwarding.delete(target) }
        }, 0)
      })
    }
    this.beforeSubmit = event => {
      const target = event.target
      if (target === this.form || this.forwarding.has(target) || (!this.open && !this.forwardIntent)) return
      event.preventDefault(); event.stopImmediatePropagation()
      const submitter = event.submitter
      this.forwardAfterStop(target, () => {
        if (submitter && submitter.form !== target) return
        if (submitter) target.requestSubmit(submitter)
        else target.requestSubmit()
      })
    }
    this.beforeClick = event => {
      const target = event.target.closest('[phx-click="invite"]')
      if (!target || this.forwarding.has(target) || (!this.open && !this.forwardIntent)) return
      event.preventDefault(); event.stopImmediatePropagation()
      this.forwardAfterStop(target, () => target.click())
    }
    document.addEventListener('submit', this.beforeSubmit, true)
    document.addEventListener('click', this.beforeClick, true)
    this.toggle = () => { if (!this.el.open) void this.stop() }
    this.el.addEventListener('toggle', this.toggle)
    this.sync()
  },
  async start() {
    if (this.destroyedFlag || this.open) return
    this.forwardIntent = null
    const token = ++this.token; this.open = true
    this.buttonLabel.textContent = this.labels.stop; this.button.disabled = false
    this.button.querySelector('[data-voice-preview-play]').hidden = true
    this.button.querySelector('[data-voice-preview-stop]').hidden = false
    this.status.textContent = this.labels.opening
    await this.pending
    if (token !== this.token || !this.open || this.destroyedFlag) return
    this.buttonLabel.textContent = this.labels.stop; this.button.disabled = false
    this.status.textContent = this.labels.opening
    try {
      const raw = await captureLocalAudio()
      if (!this.open || token !== this.token || this.destroyedFlag) { stopStream(raw); return }
      this.raw = raw
      for (const track of raw.getAudioTracks()) {
        track.addEventListener('ended', () => this.failed(token), {once: true})
        if (track.readyState === 'ended') throw new Error('Microphone ended during setup')
      }
      await this.rebuild(token)
    } catch (_) { if (token === this.token) this.failed(token) }
  },
  async rebuild(token) {
    const generation = ++this.generation
    const current = () => token === this.token && generation === this.generation && this.open && !this.destroyedFlag
    const raw = this.raw
    this.disposeProcessor()
    await this.pending
    if (!current()) return
    const abort = new AbortController(); this.abort = abort
    try {
      const pipe = createPreviewStream(raw, selectedMasking(), () => { if (current()) this.failed(token) }, abort.signal)
      this.pipe = pipe
      await pipe.ready
      if (!current()) { await pipe.close(); return }
      pipe.setEligible(true)
      // Explicit headphone monitoring only; this connection never enters a call.
      const audio = new Audio(); this.audio = audio; audio.srcObject = pipe.stream
      await audio.play()
      if (current()) this.status.textContent = this.labels.active
    } catch (_) { if (current()) this.failed(token) }
  },
  disposeProcessor() {
    this.abort?.abort(); this.abort = null
    this.audio?.pause(); if (this.audio) this.audio.srcObject = null; this.audio = null
    const pipe = this.pipe; this.pipe = null
    this.pending = Promise.all([this.pending, pipe?.close()]).then(() => {})
    return this.pending
  },
  failed(token) {
    if (token !== this.token || !this.open) return
    const stopped = this.token + 1
    void this.stop().then(() => { if (!this.destroyedFlag && this.token === stopped) this.status.textContent = this.labels.failed })
  },
  stop() {
    this.token++; this.open = false
    this.generation++
    this.disposeProcessor()
    stopStream(this.raw); this.raw = null
    this.buttonLabel.textContent = this.labels.hear
    this.button.querySelector('[data-voice-preview-play]').hidden = false
    this.button.querySelector('[data-voice-preview-stop]').hidden = true
    this.status.textContent = this.labels.stopped
    return this.pending
  },
  destroyed() {
    this.destroyedFlag = true; void this.stop(); this.unregister()
    this.el.removeEventListener('toggle', this.toggle)
    this.family.removeEventListener('change', this.sync); this.tone.removeEventListener('change', this.sync)
    this.button.removeEventListener('click', this.click); this.form.removeEventListener('submit', this.prevent)
    window.removeEventListener('pagehide', this.pagehide)
    document.removeEventListener('submit', this.beforeSubmit, true)
    document.removeEventListener('click', this.beforeClick, true)
  },
}
