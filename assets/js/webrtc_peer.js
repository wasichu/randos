const ICE_SERVERS = [{urls: "stun:stun.l.google.com:19302"}]

const serializeSessionDescription = description => {
  if (!description) return null
  if (typeof description.toJSON === "function") return description.toJSON()

  return {type: description.type, sdp: description.sdp}
}

const serializeIceCandidate = candidate => {
  if (!candidate) return null
  if (typeof candidate.toJSON === "function") return candidate.toJSON()

  return {
    candidate: candidate.candidate,
    sdpMid: candidate.sdpMid,
    sdpMLineIndex: candidate.sdpMLineIndex,
    usernameFragment: candidate.usernameFragment,
  }
}

export const WebRTCPeerState = Object.freeze({
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

export class RandosWebRTCPeer {
  constructor({role, pushSignal, onStateChange, onLocalStream, onRemoteStream}) {
    this.role = role
    this.pushSignal = pushSignal
    this.onStateChange = onStateChange
    this.onLocalStream = onLocalStream
    this.onRemoteStream = onRemoteStream
    this.peerConnection = null
    this.localStream = null
    this.remoteStream = null
    this.state = WebRTCPeerState.NOT_STARTED
    this.pendingIceCandidates = []
  }

  async start() {
    if (this.peerConnection) return

    await this.captureLocalAudio()

    this.setState(WebRTCPeerState.CREATING_PEER_CONNECTION)
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
      this.setState(WebRTCPeerState.OFFER_SENT)
    } else {
      this.setState(WebRTCPeerState.WAITING_FOR_OFFER)
    }
  }

  async captureLocalAudio() {
    if (!navigator.mediaDevices?.getUserMedia) {
      this.setState(WebRTCPeerState.MICROPHONE_DENIED)
      throw new Error("microphone_capture_unavailable")
    }

    this.setState(WebRTCPeerState.REQUESTING_MICROPHONE)

    try {
      this.localStream = await navigator.mediaDevices.getUserMedia({
        audio: {
          echoCancellation: true,
          noiseSuppression: true,
          autoGainControl: true,
        },
        video: false,
      })
      this.onLocalStream?.(this.localStream)
    } catch (error) {
      this.setState(WebRTCPeerState.MICROPHONE_DENIED)
      throw error
    }
  }

  setMuted(muted) {
    for (const track of this.localStream?.getAudioTracks() || []) {
      track.enabled = !muted
    }
  }

  async receiveSignal(signal) {
    if (!this.peerConnection || this.state === WebRTCPeerState.CLOSED) return

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

  async receiveOffer(offer) {
    await this.peerConnection.setRemoteDescription(new RTCSessionDescription(offer))
    await this.flushPendingIceCandidates()

    const answer = await this.peerConnection.createAnswer()
    await this.peerConnection.setLocalDescription(answer)
    this.pushSignal("answer", {sdp: serializeSessionDescription(this.peerConnection.localDescription)})
    this.setState(WebRTCPeerState.ANSWER_SENT)
  }

  async receiveAnswer(answer) {
    await this.peerConnection.setRemoteDescription(new RTCSessionDescription(answer))
    await this.flushPendingIceCandidates()
  }

  async receiveIceCandidate(candidate) {
    if (!candidate) return

    if (!this.peerConnection.remoteDescription) {
      this.pendingIceCandidates.push(candidate)
      return
    }

    await this.peerConnection.addIceCandidate(new RTCIceCandidate(candidate))
  }

  close() {
    this.cleanupMedia()
    this.setState(WebRTCPeerState.CLOSED)
  }

  failConnection(payload) {
    if (this.state === WebRTCPeerState.FAILED || this.state === WebRTCPeerState.CLOSED) return

    this.pushSignal("connection_failed", payload)
    this.cleanupMedia()
    this.setState(WebRTCPeerState.FAILED)
  }

  cleanupMedia() {
    if (this.localStream) {
      for (const track of this.localStream.getTracks()) {
        track.stop()
      }

      this.localStream = null
    }

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
    }
  }

  handleRemoteTrack(event) {
    if (event.streams[0]) {
      this.remoteStream = event.streams[0]
    } else {
      this.remoteStream ||= new MediaStream()
      this.remoteStream.addTrack(event.track)
    }

    this.onRemoteStream?.(this.remoteStream)
  }

  handleIceConnectionState() {
    const iceState = this.peerConnection?.iceConnectionState

    if (iceState === "checking") {
      this.setState(WebRTCPeerState.ICE_CHECKING)
    } else if (iceState === "connected" || iceState === "completed") {
      this.pushSignal("connection_established", {ice_connection_state: iceState})
      this.setState(WebRTCPeerState.CONNECTED)
    } else if (iceState === "failed" || iceState === "disconnected") {
      this.failConnection({ice_connection_state: iceState})
    } else if (iceState === "closed") {
      this.setState(WebRTCPeerState.CLOSED)
    }
  }

  handleConnectionState() {
    const connectionState = this.peerConnection?.connectionState

    if (connectionState === "connected") {
      this.setState(WebRTCPeerState.CONNECTED)
    } else if (connectionState === "failed" || connectionState === "disconnected") {
      this.failConnection({connection_state: connectionState})
    } else if (connectionState === "closed") {
      this.setState(WebRTCPeerState.CLOSED)
    }
  }

  setState(state) {
    if (this.state === state) return

    this.state = state
    this.onStateChange?.(state)
  }
}
