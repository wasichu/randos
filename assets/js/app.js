// If you want to use Phoenix channels, run `mix help phx.gen.channel`
// to get started and then uncomment the line below.
// import "./user_socket.js"

// You can include dependencies in two ways.
//
// The simplest option is to put them in assets/vendor and
// import them using relative paths:
//
//     import "../vendor/some-package.js"
//
// Alternatively, you can `npm install some-package --prefix assets` and import
// them using a path starting with the package name:
//
//     import "some-package"
//
// If you have dependencies that try to import CSS, esbuild will generate a separate `app.css` file.
// To load it, simply add a second `<link>` to your `root.html.heex` file.

// Include phoenix_html to handle method=PUT/DELETE in forms and buttons.
import "phoenix_html"
// Establish Phoenix Socket and LiveView configuration.
import {Socket} from "phoenix"
import {LiveSocket} from "phoenix_live_view"
import {hooks as colocatedHooks} from "phoenix-colocated/randos"
import topbar from "../vendor/topbar"
import {RandosWebRTCPeer, WebRTCPeerState} from "./webrtc_peer"

const csrfToken = document.querySelector("meta[name='csrf-token']").getAttribute("content")
const Hooks = {
  CallCountdown: {
    mounted() {
      this.tick = () => {
        const deadline = Number(this.el.dataset.deadlineUnixMs)
        const remainingMs = Math.max(deadline - Date.now(), 0)
        const totalSeconds = Math.ceil(remainingMs / 1000)
        const minutes = Math.floor(totalSeconds / 60)
        const seconds = totalSeconds % 60
        const value = this.el.querySelector("[data-countdown-value]")
          || this.el.querySelector("#call-countdown-value")
          || this.el.querySelector("#extension-countdown-value")

        if (value) {
          if (this.el.dataset.countdownMode === "seconds") {
            value.textContent = `Decision closes in ${totalSeconds}s`
          } else {
            value.textContent = `${minutes}:${seconds.toString().padStart(2, "0")} remaining`
          }
        }

        this.el.dataset.underMinute = totalSeconds < 60 ? "true" : "false"
      }

      this.tick()
      this.interval = window.setInterval(this.tick, 1000)
    },

    updated() {
      this.tick()
    },

    destroyed() {
      this.cleanup()
    },

    disconnected() {
      this.cleanup()
    },

    cleanup() {
      if (this.interval) {
        window.clearInterval(this.interval)
        this.interval = null
      }
    },
  },
  WebRTCAudio: {
    mounted() {
      this.statusEl = this.el.querySelector("[data-webrtc-status]")
      this.microphoneEl = this.el.querySelector("[data-microphone-status]")
      this.muteButton = this.el.querySelector("[data-webrtc-mute]")
      this.muteLabel = this.el.querySelector("[data-mute-label]")
      this.remoteAudio = this.el.querySelector("[data-remote-audio]")
      this.muted = false
      this.handleBeforeUnload = () => this.cleanup({notify: true})
      this.handleMute = () => this.toggleMute()
      this.handleEvent("randos:signal", signal => this.peer?.receiveSignal(signal))
      window.addEventListener("pagehide", this.handleBeforeUnload)
      this.muteButton?.addEventListener("click", this.handleMute)

      if (!window.RTCPeerConnection) {
        this.pushEvent("signal", {
          type: "connection_failed",
          payload: {reason: "rtc_peer_connection_unavailable"},
        })
        this.setState(WebRTCPeerState.FAILED)
        return
      }

      this.peer = new RandosWebRTCPeer({
        role: this.el.dataset.webrtcRole,
        pushSignal: (type, payload) => this.pushEvent("signal", {type, payload}),
        onStateChange: state => this.setState(state),
        onLocalStream: stream => this.setLocalStream(stream),
        onRemoteStream: stream => this.setRemoteStream(stream),
      })

      this.peer.start().catch(error => {
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
      window.removeEventListener("pagehide", this.handleBeforeUnload)
      this.muteButton?.removeEventListener("click", this.handleMute)

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

    setLocalStream(stream) {
      if (this.muteButton) {
        this.muteButton.disabled = !stream
      }

      if (stream && this.microphoneEl) {
        this.microphoneEl.textContent = "microphone ready"
      }
    },

    setRemoteStream(stream) {
      if (!this.remoteAudio) return

      this.remoteAudio.srcObject = stream

      if (stream) {
        this.remoteAudio.play().catch(() => {
          this.setState(WebRTCPeerState.ICE_CHECKING)
        })
      }
    },

    setState(state) {
      this.el.dataset.webrtcState = state

      if (this.statusEl) {
        this.statusEl.textContent = state.replaceAll("_", " ")
      }

      if (this.microphoneEl) {
        if (state === WebRTCPeerState.REQUESTING_MICROPHONE) {
          this.microphoneEl.textContent = "requesting microphone"
        } else if (state === WebRTCPeerState.MICROPHONE_DENIED) {
          this.microphoneEl.textContent = "microphone unavailable"
        }
      }
    },
  },
}

const liveSocket = new LiveSocket("/live", Socket, {
  longPollFallbackMs: 2500,
  params: {_csrf_token: csrfToken},
  hooks: {...colocatedHooks, ...Hooks},
})

// Show progress bar on live navigation and form submits
topbar.config({barColors: {0: "#29d"}, shadowColor: "rgba(0, 0, 0, .3)"})
window.addEventListener("phx:page-loading-start", _info => topbar.show(300))
window.addEventListener("phx:page-loading-stop", _info => topbar.hide())

// connect if there are any LiveViews on the page
liveSocket.connect()

// expose liveSocket on window for web console debug logs and latency simulation:
// >> liveSocket.enableDebug()
// >> liveSocket.enableLatencySim(1000)  // enabled for duration of browser session
// >> liveSocket.disableLatencySim()
window.liveSocket = liveSocket

// The lines below enable quality of life phoenix_live_reload
// development features:
//
//     1. stream server logs to the browser console
//     2. click on elements to jump to their definitions in your code editor
//
if (process.env.NODE_ENV === "development") {
  window.addEventListener("phx:live_reload:attached", ({detail: reloader}) => {
    // Enable server log streaming to client.
    // Disable with reloader.disableServerLogs()
    reloader.enableServerLogs()

    // Open configured PLUG_EDITOR at file:line of the clicked element's HEEx component
    //
    //   * click with "c" key pressed to open at caller location
    //   * click with "d" key pressed to open at function component definition location
    let keyDown
    window.addEventListener("keydown", e => keyDown = e.key)
    window.addEventListener("keyup", e => keyDown = null)
    window.addEventListener("click", e => {
      if(keyDown === "c"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtCaller(e.target)
      } else if(keyDown === "d"){
        e.preventDefault()
        e.stopImmediatePropagation()
        reloader.openEditorAtDef(e.target)
      }
    }, true)

    window.liveReloader = reloader
  })
}
