import {CleanupBag} from "../randos/cleanup"
import {label, labelsFrom} from "../randos/labels"
import {attachRemoteAudio, audioStreamSummary} from "../randos/media"
import {logEvent, logWarning} from "../randos/logging"
import {AudioLevelVisualizer} from "../randos/audio_visualizer"
import {iceServersFrom, iceTransportPolicyFrom} from "../randos/ice_servers"
import {WebRTCClient, WebRTCClientState} from "../randos/webrtc_client"

// Distinguish "the mic was refused or missing" from network/peer failures so
// the server and the peer see a meaningful reason.
// Why this browser can't carry the call: an `end_call` reason (the
// documented list in participant_channel.md), so only the peer is requeued
// and this person is told why.
const startFailureReason = error => {
  switch (error?.name) {
    case "NotAllowedError":
    case "SecurityError":
      return "microphone_denied"
    case "NotFoundError":
    case "OverconstrainedError":
      return "microphone_not_found"
    default:
      return "audio_failed"
  }
}

export const WebRTCAudio = {
  mounted() {
    this.cleanupBag = new CleanupBag("webrtc-audio-hook")
    this.labels = labelsFrom(this.el)
    this.statusEl = this.el.querySelector("[data-webrtc-status]")
    this.microphoneEl = this.el.querySelector("[data-microphone-status]")
    this.muteButton = this.el.querySelector("[data-webrtc-mute]")
    this.muteLabel = this.el.querySelector("[data-mute-label]")
    this.muteIcon = this.el.querySelector("[data-mute-icon]")
    this.unmuteIcon = this.el.querySelector("[data-unmute-icon]")
    this.remoteAudio = this.el.querySelector("[data-remote-audio]")
    this.remoteAudioStatusEl = this.el.querySelector("[data-remote-audio-status]")
    this.remoteAudioPlayButton = this.el.querySelector("[data-remote-audio-play]")
    this.localVisualizer = null
    this.remoteVisualizer = null
    this.muted = false

    this.cleanupBag.addEventListener(window, "pagehide", () => this.cleanup({notify: true}))
    this.cleanupBag.addEventListener(this.muteButton, "click", () => this.toggleMute())
    this.cleanupBag.addEventListener(this.remoteAudioPlayButton, "click", () => this.playRemoteAudio())
    this.handleEvent("randos:signal", signal => this.receiveSignal(signal))

    if (!window.RTCPeerConnection) {
      this.pushEvent("end_call", {reason: "audio_unavailable"})
      this.setState(WebRTCClientState.FAILED)
      return
    }

    this.peer = new WebRTCClient({
      role: this.el.dataset.webrtcRole,
      iceServers: iceServersFrom(this.el),
      iceTransportPolicy: iceTransportPolicyFrom(this.el),
      pushSignal: (type, payload) => this.pushEvent("signal", {type, payload}),
      onStateChange: state => this.setState(state),
      onLocalStream: stream => this.setLocalStream(stream),
      onRemoteStream: stream => this.setRemoteStream(stream),
    })

    logEvent("call.webrtc_hook_mounted", {role: this.el.dataset.webrtcRole})

    this.peer
      .start()
      .catch(error => {
        const reason = startFailureReason(error)
        logEvent("call.start_failed", {reason})
        this.pushEvent("end_call", {reason})
        this.peer?.close()
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
    this.setRemoteStream(null)
    this.setLocalStream(null)
    this.stopVisualizers()
    this.cleanupBag?.cleanup()
    logEvent("cleanup.webrtc_audio_hook", {notify})
  },

  toggleMute() {
    this.muted = !this.muted
    this.peer?.setMuted(this.muted)
    this.localVisualizer?.setMuted(this.muted)
    this.el.dataset.microphoneMuted = this.muted ? "true" : "false"

    if (this.muteLabel) {
      this.muteLabel.textContent = this.muted
        ? label(this.labels, "unmute", "Unmute")
        : label(this.labels, "mute", "Mute")
    }

    if (this.muteButton) {
      this.muteButton.setAttribute("aria-pressed", this.muted ? "true" : "false")
    }

    if (this.muteIcon && this.unmuteIcon) {
      this.muteIcon.hidden = this.muted
      this.unmuteIcon.hidden = !this.muted
    }
  },

  receiveSignal(signal) {
    this.peer?.receiveSignal(signal).catch(error => this.failSignal(error))
  },

  failSignal(error) {
    logWarning("signaling.handle_failed", {reason: error.message})
    this.peer?.failConnection({reason: error.message || "signal_handling_failed"})
  },

  setLocalStream(stream) {
    this.localVisualizer?.close()
    this.localVisualizer = null

    if (this.muteButton) {
      this.muteButton.disabled = !stream
    }

    if (stream && this.microphoneEl) {
      this.microphoneEl.textContent = label(this.labels, "microphone_ready", "microphone ready")
      this.localVisualizer = new AudioLevelVisualizer({
        findCanvas: () => document.querySelector("[data-audio-visualizer='local']"),
        stream,
        tone: "local",
        muted: this.muted,
      })
      this.localVisualizer.start()
    }
  },

  setRemoteStream(stream) {
    this.remoteVisualizer?.close()
    this.remoteVisualizer = null

    if (this.remoteAudioStatusEl) {
      this.remoteAudioStatusEl.textContent = stream
        ? label(this.labels, "remote_audio_received", "remote audio received (%{summary})", {
            summary: audioStreamSummary(stream),
          })
        : label(this.labels, "waiting_for_remote_audio", "waiting for remote audio")
    }

    if (this.remoteAudioPlayButton) {
      this.remoteAudioPlayButton.hidden = !stream
    }

    if (this.remoteAudio) {
      this.remoteAudio.hidden = !stream
    }

    if (stream) {
      this.remoteVisualizer = new AudioLevelVisualizer({
        findCanvas: () => document.querySelector("[data-audio-visualizer='remote']"),
        stream,
        tone: "remote",
      })
      this.remoteVisualizer.start()
    }

    attachRemoteAudio(this.remoteAudio, stream)
      .then(() => {
        if (stream && this.remoteAudioStatusEl) {
          this.remoteAudioStatusEl.textContent = label(this.labels, "remote_audio_playing", "remote audio playing (%{summary})", {
            summary: audioStreamSummary(stream),
          })
        }
      })
      .catch(error => {
        logWarning("media.remote_audio_playback_blocked", {reason: error.message})

        if (stream && this.remoteAudioStatusEl) {
          this.remoteAudioStatusEl.textContent = label(this.labels, "remote_audio_needs_tap", "remote audio needs a tap (%{summary})", {
            summary: audioStreamSummary(stream),
          })
        }

        if (this.remoteAudioPlayButton) {
          this.remoteAudioPlayButton.hidden = !stream
        }
      })
  },

  stopVisualizers() {
    this.localVisualizer?.close()
    this.remoteVisualizer?.close()
    this.localVisualizer = null
    this.remoteVisualizer = null
  },

  playRemoteAudio() {
    attachRemoteAudio(this.remoteAudio, this.remoteAudio?.srcObject)
      .then(() => {
        if (this.remoteAudioStatusEl) {
          this.remoteAudioStatusEl.textContent = label(this.labels, "remote_audio_playing", "remote audio playing (%{summary})", {
            summary: audioStreamSummary(this.remoteAudio?.srcObject),
          })
        }
      })
      .catch(error => {
        logWarning("media.remote_audio_playback_failed", {reason: error.message})
      })
  },

  setState(state) {
    this.el.dataset.webrtcState = state

    if (this.statusEl) {
      this.statusEl.textContent = label(this.labels, `state_${state}`, state.replaceAll("_", " "))
    }

    if (this.microphoneEl) {
      if (state === WebRTCClientState.REQUESTING_MICROPHONE) {
        this.microphoneEl.textContent = label(this.labels, "requesting_microphone", "requesting microphone")
      } else if (state === WebRTCClientState.MICROPHONE_DENIED) {
        this.microphoneEl.textContent = label(this.labels, "microphone_unavailable", "microphone unavailable")
      }
    }
  },
}
