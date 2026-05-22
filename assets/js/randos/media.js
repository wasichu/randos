export const captureLocalAudio = () => {
  if (!navigator.mediaDevices?.getUserMedia) {
    throw new Error("microphone_capture_unavailable")
  }

  return navigator.mediaDevices.getUserMedia({
    audio: {
      echoCancellation: true,
      noiseSuppression: true,
      autoGainControl: true,
    },
    video: false,
  })
}

export const stopStream = stream => {
  for (const track of stream?.getTracks() || []) {
    track.stop()
  }
}

export const setStreamMuted = (stream, muted) => {
  for (const track of stream?.getAudioTracks() || []) {
    track.enabled = !muted
  }
}

export const remoteStreamFromTrackEvent = (event, existingStream) => {
  if (event.streams[0]) return event.streams[0]

  const stream = existingStream || new MediaStream()
  stream.addTrack(event.track)
  return stream
}

export const attachRemoteAudio = (audioElement, stream) => {
  if (!audioElement) return Promise.resolve()

  audioElement.srcObject = stream
  audioElement.autoplay = true
  audioElement.muted = false
  audioElement.volume = 1

  if (!stream) return Promise.resolve()

  return audioElement.play()
}

export const audioStreamSummary = stream => {
  const tracks = stream?.getAudioTracks() || []

  if (tracks.length === 0) return "no audio tracks"

  return tracks
    .map(track => {
      const muted = track.muted ? "muted" : "unmuted"
      return `${track.readyState} ${muted}`
    })
    .join(", ")
}
