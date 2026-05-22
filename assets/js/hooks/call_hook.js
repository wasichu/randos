import {CleanupBag} from "../randos/cleanup"
import {attachRemoteAudio} from "../randos/media"
import {logEvent, logWarning} from "../randos/logging"
import {WebRTCClient, WebRTCClientState} from "../randos/webrtc_client"

export const WebRTCAudio = {
  mounted() {
    this.cleanupBag = new CleanupBag("webrtc-audio-hook")
    this.statusEl = this.el.querySelector("[data-webrtc-status]")
    this.microphoneEl = this.el.querySelector("[data-microphone-status]")
    this.muteButton = this.el.querySelector("[data-webrtc-mute]")
    this.muteLabel = this.el.querySelector("[data-mute-label]")
    this.remoteAudio = this.el.querySelector("[data-remote-audio]")
    this.remoteAudioStatusEl = this.el.querySelector("[data-remote-audio-status]")
    this.remoteAudioPlayButton = this.el.querySelector("[data-remote-audio-play]")
    this.pendingSignals = []
    this.muted = false

    this.cleanupBag.addEventListener(window, "pagehide", () => this.cleanup({notify: true}))
    this.cleanupBag.addEventListener(this.muteButton, "click", () => this.toggleMute())
    this.cleanupBag.addEventListener(this.remoteAudioPlayButton, "click", () => this.playRemoteAudio())
    this.handleEvent("randos:signal", signal => this.receiveSignal(signal))

    if (!window.RTCPeerConnection) {
      this.pushEvent("signal", {
        type: "connection_failed",
        payload: {reason: "rtc_peer_connection_unavailable"},
      })
      this.setState(WebRTCClientState.FAILED)
      return
    }

    this.peer = new WebRTCClient({
      role: this.el.dataset.webrtcRole,
      pushSignal: (type, payload) => this.pushEvent("signal", {type, payload}),
      onStateChange: state => this.setState(state),
      onLocalStream: stream => this.setLocalStream(stream),
      onRemoteStream: stream => this.setRemoteStream(stream),
    })

    logEvent("call.webrtc_hook_mounted", {role: this.el.dataset.webrtcRole})

    this.peer
      .start()
      .then(() => this.flushPendingSignals())
      .catch(error => {
        this.peer?.failConnection({
          reason: error.message || "peer_connection_start_failed",
        })
      })
  },

  destroyed() {
    this.cleanup()
  },

  disconnected() {
    this.cleanup()
  },

  cleanup({notify = false} = {}) {
    if (this.cleaned) return

    this.cleaned = true

    if (notify && this.peer) {
      this.pushEvent("signal", {
        type: "peer_disconnected",
        payload: {reason: "page_unload"},
      })
    }

    this.peer?.close()
    this.peer = null
    this.pendingSignals = []
    this.setRemoteStream(null)
    this.setLocalStream(null)
    this.cleanupBag?.cleanup()
    logEvent("cleanup.webrtc_audio_hook", {notify})
  },

  toggleMute() {
    this.muted = !this.muted
    this.peer?.setMuted(this.muted)
    this.el.dataset.microphoneMuted = this.muted ? "true" : "false"

    if (this.muteLabel) {
      this.muteLabel.textContent = this.muted ? "Unmute" : "Mute"
    }

    if (this.muteButton) {
      this.muteButton.setAttribute("aria-pressed", this.muted ? "true" : "false")
    }
  },

  receiveSignal(signal) {
    if (!this.peer) {
      this.pendingSignals.push(signal)
      return
    }

    this.peer.receiveSignal(signal)
  },

  flushPendingSignals() {
    const signals = this.pendingSignals
    this.pendingSignals = []

    for (const signal of signals) {
      this.peer?.receiveSignal(signal)
    }
  },

  setLocalStream(stream) {
    if (this.muteButton) {
      this.muteButton.disabled = !stream
    }

    if (stream && this.microphoneEl) {
      this.microphoneEl.textContent = "microphone ready"
    }
  },

  setRemoteStream(stream) {
    if (this.remoteAudioStatusEl) {
      this.remoteAudioStatusEl.textContent = stream ? "remote audio received" : "waiting for remote audio"
    }

    if (this.remoteAudioPlayButton) {
      this.remoteAudioPlayButton.hidden = !stream
    }

    attachRemoteAudio(this.remoteAudio, stream)
      .then(() => {
        if (stream && this.remoteAudioStatusEl) {
          this.remoteAudioStatusEl.textContent = "remote audio playing"
        }
      })
      .catch(error => {
        logWarning("media.remote_audio_playback_blocked", {reason: error.message})

        if (stream && this.remoteAudioStatusEl) {
          this.remoteAudioStatusEl.textContent = "remote audio needs a tap"
        }

        if (this.remoteAudioPlayButton) {
          this.remoteAudioPlayButton.hidden = !stream
        }
      })
  },

  playRemoteAudio() {
    attachRemoteAudio(this.remoteAudio, this.remoteAudio?.srcObject)
      .then(() => {
        if (this.remoteAudioStatusEl) {
          this.remoteAudioStatusEl.textContent = "remote audio playing"
        }
      })
      .catch(error => {
        logWarning("media.remote_audio_playback_failed", {reason: error.message})
      })
  },

  setState(state) {
    this.el.dataset.webrtcState = state

    if (this.statusEl) {
      this.statusEl.textContent = state.replaceAll("_", " ")
    }

    if (this.microphoneEl) {
      if (state === WebRTCClientState.REQUESTING_MICROPHONE) {
        this.microphoneEl.textContent = "requesting microphone"
      } else if (state === WebRTCClientState.MICROPHONE_DENIED) {
        this.microphoneEl.textContent = "microphone unavailable"
      }
    }
  },
}
