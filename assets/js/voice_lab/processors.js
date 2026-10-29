// Development-only candidates extend the lab, not the call registry.
import {VOICE_PROCESSORS, createVoiceNode} from "../randos/voice/seam"

export const LAB_PROCESSORS = Object.freeze({
  ...VOICE_PROCESSORS,
  ...Object.fromEntries([
    ["gentle_current_pitch", "Gentler · current pitch"],
    ["gentle_half_pitch", "Gentler · half pitch"],
    ["gentle_zero_pitch", "Gentler · resonance only"],
  ].map(([name,label])=>[name,{label,preRendered:true,note:"Signalsmith pitch-strength audition with fixed resonances. Compare all four versions in Gentler pitch; no pitch shift still retains resonance processing."}])),
  ...Object.fromEntries([
    ["preferred_spectral", "Preferred · Signalsmith"],
    ["preferred_world", "Preferred · WORLD"],
  ].map(([name,label])=>[name,{label,preRendered:true,note:"The preferred-settings engine comparison. Compare both engines in the Engine comparison tab, or select their profiles in Try your voice."}])),
  ...Object.fromEntries([
    ["spectral_more_pitch", "Signalsmith · more pitch"],
    ["spectral_more_resonance", "Signalsmith · more resonance"],
    ["spectral_opposing", "Signalsmith · opposing directions"],
  ].map(([name,label]) => [name,{label,preRendered:true,note:"Stronger Signalsmith audition. Use the Masking round tab to compare Original, Current and all three candidates together, and save a preference."}])),
  ...Object.fromEntries([
    ["browser_world", "Browser DSP · WORLD pitch + resonance"],
    ["browser_spectral", "Browser DSP · Signalsmith pitch + resonance"],
    ["browser_time", "Browser DSP · McAdams + delay-line pitch"],
  ].map(([name,label]) => [name,{label,preRendered:true,note:"Actual browser Worker output, with native waveform checks and a one-minute paced test. No trained weights. Compare against the raw original; call integration remains untested."}])),
  ...Object.fromEntries([40, 80, 160].map(size => [`world_chunk_${size}`, {
    label: `WORLD · ${size} ms chunks vs whole recording`, preRendered: true,
    note: "Compare whole-recording WORLD with a short-window version at the same pitch/resonance settings. Listen for clicks, warbling and changed consonants. This tests one reset-synthesis wrapper; it does not establish browser streaming feasibility.",
  }])),
  ...Object.fromEntries([
    ["world_control", "WORLD · unchanged resynthesis control"],
    ["world_pitch", "WORLD · pitch only"],
    ["world_formants", "WORLD · pitch + resonances"],
    ["world_texture", "WORLD · pitch + resonances + breathiness"],
  ].map(([name, label]) => [name, {label, preRendered: true, note: "Model-free DSP for all four public recordings. Start with the unchanged resynthesis control, then compare pitch, resonances and voice texture. No trained weights; these are prepared listening samples. Live processing has not been implemented."}])),
  ...Object.fromEntries([
    ["quality_pitch", "Sound check · pitch only"],
    ["quality_resonance", "Sound check · resonance only"],
    ["quality_both", "Sound check · pitch + resonance"],
    ["quality_tvtsyn", "Sound check · TVTSyn reference"],
  ].map(([name, label]) => [name, {label, preRendered: true, note: "Prepared for all four public recordings. Pitch goes down 2 semitones for high/mid voice and up 2 for low voice/Wasichu; resonance changes use McAdams 0.9. Compare roughness, clarity and how different the voice sounds at matched average signal levels."}])),
  mcadams: {
    label: "McAdams (experimental)",
    sampleRate: 48000,
    tailSamples: 1022,
    note: "Known-recording matching still recognizes speakers. Try the Recovery test tab for an approximate reversal. Lower coefficients can clip; 0.7 did in our test. Try 0.9, then 0.7; 1.0 is the bandwidth/resampling control. Adds about 21 ms of delay.",
  },
  seed_vc_v2: {
    label: "Seed-VC v2", preRendered: true,
    note: "Pre-rendered model experiment, using its saved average-voice/style settings. Loads prepared WAVs only. Listen for changes in words, accent and pronunciation. Live microphone processing is not available for this option.",
  },
  tvtsyn_browser: {
    label: "TVTSyn · browser WASM", preRendered: true,
    note: "Pre-rendered output from the actual browser WASM probe for all four recordings, using the mid-voice reader as its target. Mid voice is a target-voice control. Loads WAVs only; no model weights load here. Live microphone processing is not available for this option.",
  },
  tvtsyn_native: {label: "TVTSyn · four-sample comparison", preRendered: true, note: "Prepared native ONNX output with the same model and target as the browser probe. The mid-voice sample is a same-target control, not a disguise test. No inference runs when playing these WAVs."},
  tvtsyn_int8: {label: "TVTSyn · INT8 experiment", preRendered: true, note: "Native ONNX output after dynamic INT8 quantization of MatMul/Gemm weights: 199 MB instead of 360 MB. The strict browser/native waveform check failed, so this variant is not browser-qualified. Mid voice is a same-target control."},
  hybrid_down_2: {label: "DSP preset · α 0.9, pitch −2", preRendered: true, note: "Fixed DSP experiment: McAdams α=0.9, then pitch −2 semitones with 40 ms slices. Includes a 100 ms tail to retain delayed speech. No privacy claim."},
  hybrid_up_2: {label: "DSP preset · α 0.9, pitch +2", preRendered: true, note: "Fixed DSP experiment: McAdams α=0.9, then pitch +2 semitones with 40 ms slices. Includes a 100 ms tail to retain delayed speech. No privacy claim."},
  hybrid_mild: {label: "DSP preset · α 0.85, pitch −1", preRendered: true, note: "Fixed DSP experiment: McAdams α=0.85, then pitch −1 semitone with 40 ms slices. Includes a 100 ms tail to retain delayed speech. No privacy claim."},
})

export async function createLabVoiceNode(context, name) {
  if (LAB_PROCESSORS[name]?.preRendered) throw new Error("This option plays a pre-rendered model experiment")
  if (name !== "mcadams") return createVoiceNode(context, name)
  if (context.sampleRate !== 48000) throw new Error("McAdams requires 48 kHz audio")
  await context.audioWorklet.addModule("/assets/js/voice_lab/mcadams.js")
  return new AudioWorkletNode(context, "randos-lab-mcadams", {
    numberOfInputs: 1,
    numberOfOutputs: 1,
    outputChannelCount: [1],
    channelCount: 1,
    channelCountMode: "explicit",
  })
}
