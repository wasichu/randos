export const serializeSessionDescription = description => {
  if (!description) return null
  if (typeof description.toJSON === "function") return description.toJSON()

  return {type: description.type, sdp: description.sdp}
}

export const serializeIceCandidate = candidate => {
  if (!candidate) return null
  if (typeof candidate.toJSON === "function") return candidate.toJSON()

  return {
    candidate: candidate.candidate,
    sdpMid: candidate.sdpMid,
    sdpMLineIndex: candidate.sdpMLineIndex,
    usernameFragment: candidate.usernameFragment,
  }
}
