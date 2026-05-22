import {
  captureLocalAudio,
  remoteStreamFromTrackEvent,
  setStreamMuted,
  stopStream,
} from "./media"
import {serializeIceCandidate, serializeSessionDescription} from "./signaling"
import {logDebug, logEvent, logWarning} from "./logging"

const ICE_SERVERS = [{urls: "stun:stun.l.google.com:19302"}]

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
  constructor({role, pushSignal, onStateChange, onLocalStream, onRemoteStream}) {
    this.role = role
    this.pushSignal = pushSignal
    this.onStateChange = onStateChange
    this.onLocalStream = onLocalStream
    this.onRemoteStream = onRemoteStream
    this.peerConnection = null
    this.localStream = null
    this.remoteStream = null
    this.state = WebRTCClientState.NOT_STARTED
    this.pendingSignals = []
    this.pendingIceCandidates = []
    this.cleaned = false
  }

  async start() {
    if (this.peerConnection || this.cleaned) return

    logEvent("webrtc.start", {role: this.role})
    await this.captureLocalAudio()

    this.setState(WebRTCClientState.CREATING_PEER_CONNECTION)
    this.peerConnection = new RTCPeerConnection({iceServers: ICE_SERVERS})
    this.peerConnection.onicecandidate = event => this.handleLocalIceCandidate(event)
    this.peerConnection.oniceconnectionstatechange = () => this.handleIceConnectionState()
    this.peerConnection.onconnectionstatechange = () => this.handleConnectionState()
    this.peerConnection.ontrack = event => this.handleRemoteTrack(event)

    for (const track of this.localStream.getAudioTracks()) {
      this.peerConnection.addTrack(track, this.localStream)
    }

    if (this.role === "offerer") {
      const offer = await this.peerConnection.createOffer()
      await this.peerConnection.setLocalDescription(offer)
      this.pushSignal("offer", {sdp: serializeSessionDescription(this.peerConnection.localDescription)})
      this.setState(WebRTCClientState.OFFER_SENT)
      logEvent("webrtc.offer_sent")
    } else {
      this.setState(WebRTCClientState.WAITING_FOR_OFFER)
      logEvent("webrtc.waiting_for_offer")
    }

    await this.flushPendingSignals()
  }

  async captureLocalAudio() {
    this.setState(WebRTCClientState.REQUESTING_MICROPHONE)
    logEvent("media.microphone_request")

    try {
      this.localStream = await captureLocalAudio()
      this.onLocalStream?.(this.localStream)
      logEvent("media.microphone_ready")
    } catch (error) {
      this.setState(WebRTCClientState.MICROPHONE_DENIED)
      logWarning("media.microphone_failed", {reason: error.message})
      throw error
    }
  }

  setMuted(muted) {
    setStreamMuted(this.localStream, muted)
    logEvent("media.microphone_muted", {muted})
  }

  async receiveSignal(signal) {
    if (this.state === WebRTCClientState.CLOSED) return

    if (!this.peerConnection) {
      this.pendingSignals.push(signal)
      logDebug("signaling.queued", {type: signal.type})
      return
    }

    logDebug("signaling.received", {type: signal.type})

    switch (signal.type) {
      case "offer":
        await this.receiveOffer(signal.payload.sdp)
        break
      case "answer":
        await this.receiveAnswer(signal.payload.sdp)
        break
      case "ice_candidate":
        await this.receiveIceCandidate(signal.payload.candidate)
        break
      case "hangup":
      case "peer_disconnected":
      case "connection_failed":
        this.close()
        break
    }
  }

  async flushPendingSignals() {
    const signals = this.pendingSignals
    this.pendingSignals = []

    for (const signal of signals) {
      await this.receiveSignal(signal)
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

    this.cleanupMedia()
    this.setState(WebRTCClientState.CLOSED)
    logEvent("webrtc.closed")
  }

  failConnection(payload) {
    if (this.state === WebRTCClientState.FAILED || this.state === WebRTCClientState.CLOSED) return

    this.pushSignal("connection_failed", payload)
    this.cleanupMedia()
    this.setState(WebRTCClientState.FAILED)
    logWarning("webrtc.failed", payload)
  }

  cleanupMedia() {
    if (this.cleaned) return

    this.cleaned = true
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
    this.pendingSignals = []
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

  handleIceConnectionState() {
    const iceState = this.peerConnection?.iceConnectionState
    logDebug("webrtc.ice_state", {state: iceState})

    if (iceState === "checking") {
      this.setState(WebRTCClientState.ICE_CHECKING)
    } else if (iceState === "connected" || iceState === "completed") {
      this.pushSignal("connection_established", {ice_connection_state: iceState})
      this.setState(WebRTCClientState.CONNECTED)
      logEvent("webrtc.connected", {iceState})
    } else if (iceState === "failed" || iceState === "disconnected") {
      this.failConnection({ice_connection_state: iceState})
    } else if (iceState === "closed") {
      this.setState(WebRTCClientState.CLOSED)
    }
  }

  handleConnectionState() {
    const connectionState = this.peerConnection?.connectionState
    logDebug("webrtc.connection_state", {state: connectionState})

    if (connectionState === "connected") {
      this.setState(WebRTCClientState.CONNECTED)
    } else if (connectionState === "failed" || connectionState === "disconnected") {
      this.failConnection({connection_state: connectionState})
    } else if (connectionState === "closed") {
      this.setState(WebRTCClientState.CLOSED)
    }
  }

  setState(state) {
    if (this.state === state) return

    this.state = state
    this.onStateChange?.(state)
    logDebug("webrtc.state", {state})
  }
}
