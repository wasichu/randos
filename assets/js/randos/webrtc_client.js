import {
  captureLocalAudio,
  remoteStreamFromTrackEvent,
  setStreamMuted,
  stopStream,
} from "./media"
import {serializeIceCandidate, serializeSessionDescription} from "./signaling"
import {logDebug, logEvent, logWarning} from "./logging"

const DISCONNECTED_GRACE_MS = 5000
const TEARDOWN_SIGNALS = new Set(["peer_disconnected", "connection_failed"])

export const WebRTCClientState = Object.freeze({
  NOT_STARTED: "not_started",
  REQUESTING_MICROPHONE: "requesting_microphone",
  MICROPHONE_DENIED: "microphone_denied",
  CREATING_PEER_CONNECTION: "creating_peer_connection",
  WAITING_FOR_OFFER: "waiting_for_offer",
  OFFER_SENT: "offer_sent",
  ANSWER_SENT: "answer_sent",
  ICE_CHECKING: "ice_checking",
  CONNECTED: "connected",
  FAILED: "failed",
  CLOSED: "closed",
})

export class WebRTCClient {
  constructor({role, iceServers, pushSignal, onStateChange, onLocalStream, onRemoteStream}) {
    this.role = role
    this.iceServers = iceServers
    this.pushSignal = pushSignal
    this.onStateChange = onStateChange
    this.onLocalStream = onLocalStream
    this.onRemoteStream = onRemoteStream
    this.peerConnection = null
    this.localStream = null
    this.remoteStream = null
    this.state = WebRTCClientState.NOT_STARTED
    // Signals are handled strictly in order, and only after start() settles.
    this.ready = Promise.resolve()
    this.signalChain = Promise.resolve()
    this.pendingIceCandidates = []
    this.disconnectedTimeout = null
    this.connectionEstablishedSent = false
    this.cleaned = false
  }

  start() {
    this.ready = this.startConnection()
    return this.ready
  }

  async startConnection() {
    if (this.peerConnection || this.cleaned) return

    logEvent("webrtc.start", {role: this.role, iceServerCount: this.iceServers.length})
    const stream = await this.captureLocalAudio()

    // The call may have ended while the mic prompt was open; never keep a
    // microphone the user no longer has a call for.
    if (this.cleaned) {
      stopStream(stream)
      return
    }

    this.localStream = stream
    this.onLocalStream?.(stream)

    this.setState(WebRTCClientState.CREATING_PEER_CONNECTION)
    this.peerConnection = new RTCPeerConnection({iceServers: this.iceServers})
    this.peerConnection.onicecandidate = event => this.handleLocalIceCandidate(event)
    this.peerConnection.oniceconnectionstatechange = () =>
      this.handleConnectionState("ice_connection_state", this.peerConnection?.iceConnectionState)
    this.peerConnection.onconnectionstatechange = () =>
      this.handleConnectionState("connection_state", this.peerConnection?.connectionState)
    this.peerConnection.ontrack = event => this.handleRemoteTrack(event)

    for (const track of this.localStream.getAudioTracks()) {
      this.peerConnection.addTrack(track, this.localStream)
    }

    if (this.role === "offerer") {
      const offer = await this.peerConnection.createOffer()
      if (this.cleaned) return
      await this.peerConnection.setLocalDescription(offer)
      if (this.cleaned) return
      this.pushSignal("offer", {sdp: serializeSessionDescription(this.peerConnection.localDescription)})
      this.setState(WebRTCClientState.OFFER_SENT)
      logEvent("webrtc.offer_sent")
    } else {
      this.setState(WebRTCClientState.WAITING_FOR_OFFER)
      logEvent("webrtc.waiting_for_offer")
    }
  }

  async captureLocalAudio() {
    this.setState(WebRTCClientState.REQUESTING_MICROPHONE)
    logEvent("media.microphone_request")

    try {
      const stream = await captureLocalAudio()
      logEvent("media.microphone_ready")
      return stream
    } catch (error) {
      if (this.cleaned) return null

      this.setState(WebRTCClientState.MICROPHONE_DENIED)
      logWarning("media.microphone_failed", {reason: error.message})
      throw error
    }
  }

  setMuted(muted) {
    setStreamMuted(this.localStream, muted)
    logEvent("media.microphone_muted", {muted})
  }

  // Returns a promise for this signal's handling (rejecting if it fails) while
  // keeping the chain alive for the signals after it.
  receiveSignal(signal) {
    if (this.cleaned) return Promise.resolve()

    // Teardown signals act immediately rather than waiting their turn.
    if (TEARDOWN_SIGNALS.has(signal.type)) {
      this.close()
      return Promise.resolve()
    }

    const handled = this.signalChain.then(async () => {
      await this.ready.catch(() => {})
      if (this.cleaned || !this.peerConnection) return

      logDebug("signaling.received", {type: signal.type})
      await this.handleSignal(signal)
    })

    this.signalChain = handled.catch(() => {})
    return handled
  }

  async handleSignal(signal) {
    switch (signal.type) {
      case "offer":
        return this.receiveOffer(signal.payload.sdp)
      case "answer":
        return this.receiveAnswer(signal.payload.sdp)
      case "ice_candidate":
        return this.receiveIceCandidate(signal.payload.candidate)
    }
  }

  async receiveOffer(offer) {
    await this.peerConnection.setRemoteDescription(new RTCSessionDescription(offer))
    await this.flushPendingIceCandidates()

    const answer = await this.peerConnection.createAnswer()
    await this.peerConnection.setLocalDescription(answer)
    this.pushSignal("answer", {sdp: serializeSessionDescription(this.peerConnection.localDescription)})
    this.setState(WebRTCClientState.ANSWER_SENT)
    logEvent("webrtc.answer_sent")
  }

  async receiveAnswer(answer) {
    await this.peerConnection.setRemoteDescription(new RTCSessionDescription(answer))
    await this.flushPendingIceCandidates()
    logEvent("webrtc.answer_received")
  }

  async receiveIceCandidate(candidate) {
    if (!candidate) return

    if (!this.peerConnection.remoteDescription) {
      this.pendingIceCandidates.push(candidate)
      return
    }

    await this.peerConnection.addIceCandidate(new RTCIceCandidate(candidate))
    logDebug("webrtc.ice_candidate_added")
  }

  close() {
    if (this.cleaned) return

    this.teardown()
    this.setState(WebRTCClientState.CLOSED)
    logEvent("webrtc.closed")
  }

  failConnection(payload) {
    if (this.cleaned) return

    this.pushSignal("connection_failed", payload)
    this.teardown()
    // Keep the more specific state if the mic was the problem.
    if (this.state !== WebRTCClientState.MICROPHONE_DENIED) {
      this.setState(WebRTCClientState.FAILED)
    }
    logWarning("webrtc.failed", payload)
  }

  // The one place media and the peer connection are released. Idempotent.
  teardown() {
    if (this.cleaned) return

    this.cleaned = true
    this.clearDisconnectedTimeout()
    stopStream(this.localStream)
    this.localStream = null

    if (this.peerConnection) {
      this.peerConnection.onicecandidate = null
      this.peerConnection.oniceconnectionstatechange = null
      this.peerConnection.onconnectionstatechange = null
      this.peerConnection.ontrack = null
      this.peerConnection.close()
      this.peerConnection = null
    }

    this.remoteStream = null
    this.pendingIceCandidates = []
    this.onLocalStream?.(null)
    this.onRemoteStream?.(null)
    logEvent("cleanup.webrtc_client")
  }

  async flushPendingIceCandidates() {
    const candidates = this.pendingIceCandidates
    this.pendingIceCandidates = []

    for (const candidate of candidates) {
      await this.peerConnection.addIceCandidate(new RTCIceCandidate(candidate))
    }
  }

  handleLocalIceCandidate(event) {
    if (event.candidate) {
      this.pushSignal("ice_candidate", {candidate: serializeIceCandidate(event.candidate)})
      logDebug("webrtc.ice_candidate_sent")
    }
  }

  handleRemoteTrack(event) {
    this.remoteStream = remoteStreamFromTrackEvent(event, this.remoteStream)
    this.onRemoteStream?.(this.remoteStream)
    logEvent("media.remote_track")
  }

  // Both iceConnectionState and connectionState feed this; `source` names
  // which one in any payload sent to the server.
  handleConnectionState(source, state) {
    logDebug("webrtc.connection_state", {source, state})

    switch (state) {
      case "new":
        this.setState(WebRTCClientState.CREATING_PEER_CONNECTION)
        break
      case "checking":
      case "connecting":
        this.setState(WebRTCClientState.ICE_CHECKING)
        break
      case "connected":
      case "completed":
        this.markConnected(source, state)
        break
      case "disconnected":
        this.setState(WebRTCClientState.ICE_CHECKING)
        this.scheduleDisconnectedFailure({[source]: state})
        break
      case "failed":
        this.failConnection({[source]: state})
        break
    }
  }

  markConnected(source, state) {
    this.clearDisconnectedTimeout()

    if (!this.connectionEstablishedSent) {
      this.pushSignal("connection_established", {[source]: state})
      this.connectionEstablishedSent = true
    }

    this.setState(WebRTCClientState.CONNECTED)
    logEvent("webrtc.connected", {source, state})
  }

  scheduleDisconnectedFailure(payload) {
    if (this.disconnectedTimeout || this.cleaned) return

    logWarning("webrtc.disconnected", payload)
    this.disconnectedTimeout = window.setTimeout(() => {
      this.disconnectedTimeout = null
      this.failConnection({...payload, reason: "disconnected_timeout"})
    }, DISCONNECTED_GRACE_MS)
  }

  clearDisconnectedTimeout() {
    if (!this.disconnectedTimeout) return

    window.clearTimeout(this.disconnectedTimeout)
    this.disconnectedTimeout = null
  }

  setState(state) {
    if (this.state === state) return

    this.state = state
    this.onStateChange?.(state)
    logDebug("webrtc.state", {state})
  }
}
