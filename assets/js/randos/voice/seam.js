// The seam between the microphone and the call (Phase 5): every call's
// local audio passes through processLocalStream before it's sent. With no
// processor (the default) the mic stream is sent as it is and nothing else
// is created. With one, the stream runs through that processor's
// AudioWorklet (the Rust code in voice/, as WASM) and the processed stream
// is what's sent, shown in the "You" waveform, and muted.
//
// The voice lab uses the same registry and the same worklets, so a lab
// winner is one setting away from a real call (RANDOS_VOICE_PROCESSOR).

// Display fields only: each processor's parameters come from its worklet's
// own parameterDescriptors (as the node's AudioParams).
export const VOICE_PROCESSORS = Object.freeze({
  passthrough: {
    module: "/assets/js/randos/voice/passthrough.js",
    node: "randos-passthrough",
    label: "Passthrough",
    description: "Copies the input: the cost of the worklet hop alone, and every comparison's baseline.",
    clients: ["browser", "tui"],
  },
  pitch_shift: {
    module: "/assets/js/randos/voice/pitch_shift.js",
    node: "randos-pitch-shift",
    label: "Pitch shift",
    description:
      "A delay-line pitch shifter: low latency (about half the window), but formants move with the pitch.",
    clients: ["browser", "tui"],
  },
})

// One AudioWorkletNode of `name` in `context` (loading its module once per context).
export async function createVoiceNode(context, name) {
  const processor = VOICE_PROCESSORS[name]
  if (!processor) throw new Error(`unknown voice processor: ${name}`)

  await context.audioWorklet.addModule(processor.module)
  return new AudioWorkletNode(context, processor.node, {
    numberOfInputs: 1,
    numberOfOutputs: 1,
    outputChannelCount: [1],
    channelCount: 1,
    channelCountMode: "explicit",
  })
}

// Returns {stream, close}: the stream to send, and the teardown for what
// processing created (it doesn't stop `rawStream`; the caller owns it).
// Throws if the processor can't start, so the call ends (audio_failed)
// rather than silently sending the unprocessed voice.
export async function processLocalStream(rawStream, name) {
  if (!name) return {stream: rawStream, close() {}}

  // At the capture rate, so the seam adds no resampling.
  const sampleRate = rawStream.getAudioTracks()[0]?.getSettings?.().sampleRate
  const context = new AudioContext({latencyHint: "interactive", ...(sampleRate ? {sampleRate} : {})})

  try {
    const node = await createVoiceNode(context, name)
    const source = context.createMediaStreamSource(rawStream)
    const destination = context.createMediaStreamDestination()
    source.connect(node).connect(destination)
    if (context.state === "suspended") await context.resume()

    return {
      stream: destination.stream,
      close() {
        source.disconnect()
        node.disconnect()
        for (const track of destination.stream.getTracks()) track.stop()
        context.close().catch(() => {})
      },
    }
  } catch (error) {
    context.close().catch(() => {})
    throw error
  }
}
