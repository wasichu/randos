// Full published TVTSyn ONNX graph, off the UI/audio thread. Research only.
import * as ort from "onnxruntime-web/webgpu"

const clock = () => performance.timeOrigin + performance.now()
const send = (type, data = {}) => postMessage({type, ...data})
let session, schema, state, speaker, ready, run, busy = false, queue = []

function reset() {
  state?.forEach(tensor => tensor.dispose())
  state = schema.map(entry => {
    const count = entry.shape.reduce((a, b) => a * b, 1)
    const data = entry.dtype === "int64" ? new BigInt64Array(count) : new Float32Array(count)
    return new ort.Tensor(entry.dtype === "int64" ? "int64" : "float32", data, entry.shape)
  })
}

async function step(chunk) {
  const begin = clock()
  const feed = {wav_chunk: new ort.Tensor("float32", chunk, [1, 1, 1600]), speaker_embed: speaker}
  state.forEach((value, i) => { if (session.inputNames.includes(`state_${String(i).padStart(3, "0")}`)) feed[`state_${String(i).padStart(3, "0")}`] = value })
  const result = await session.run(feed)
  // Default outputs are CPU tensors; getData also makes transfer costs explicit
  // if a future runtime returns device-backed data.
  const pcm = new Float32Array(await result.y_chunk.getData())
  const next = schema.map((_, i) => result[`next_state_${String(i).padStart(3, "0")}`])
  ready = Number((await next[1].getData())[0]) !== 0
  state.forEach(tensor => tensor.dispose())
  state = next
  result.y_chunk.dispose()
  feed.wav_chunk.dispose()
  if (!pcm.every(Number.isFinite)) throw new Error("Nonfinite model output")
  return {pcm, elapsed: clock() - begin, ready}
}

function summary(values) {
  const sorted = [...values].sort((a, b) => a - b)
  return {mean: values.reduce((a, b) => a + b, 0) / values.length,
    p95: sorted[Math.ceil(sorted.length * .95) - 1], max: sorted.at(-1)}
}

async function finish() {
  // Upstream LA4 / five frames per step: flush one zero chunk, then crop to
  // received sample count. Never drop the final audio because it was delayed.
  const tail = await step(new Float32Array(1600))
  if (tail.ready) { run.emittedChunks++; if (run.retain) run.parts.push(tail.pcm) }
  if (run.emittedChunks * 1600 < run.samples) throw new Error("Failed to drain stream")
  const all = new Float32Array(run.retain ? run.samples : 0)
  let offset = 0
  for (const part of run.parts) {
    const count = Math.min(part.length, all.length - offset)
    if (count > 0) all.set(part.subarray(0, count), offset)
    offset += count
  }
  if (offset !== all.length) throw new Error("Failed to drain complete stream")
  const report = {mode: run.mode, samples: run.samples, retained_pcm: run.retain, step_ms: summary(run.times),
    first_output_ms: run.firstOutput, max_backlog_ms: run.maxBacklog,
    output_delay_ms: run.mode === "paced" && run.delays.length ? summary(run.delays) : null,
    steps_over_100ms: run.times.filter(ms => ms > 100).length,
    elapsed_ms: clock() - run.start, main_release_lateness_ms: summary(run.releaseLateness)}
  run = null
  send("complete", {report, pcm: all.buffer})
}

async function drain() {
  if (busy) return
  busy = true
  try {
    while (queue.length) {
      const item = queue.shift()
      if (item.end) { await finish(); continue }
      const output = await step(new Float32Array(item.pcm))
      run.samples += 1600
      run.processed++
      run.times.push(output.elapsed)
      run.releaseLateness.push(item.lateness ?? 0)
      if (run.mode === "paced") {
        const eligible = Math.min(600, Math.floor((clock() - run.start) / 100))
        run.maxBacklog = Math.max(run.maxBacklog, (eligible - run.processed) * 100)
      }
      if (output.ready) {
        const outputIndex = run.emittedChunks++
        if (run.retain) run.parts.push(output.pcm)
        const delay = clock() - run.start - outputIndex * 100
        run.firstOutput ??= clock() - run.start
        run.delays.push(delay)
      }
      if (run.processed % 50 === 0) send("progress", {processed: run.processed, backlog_ms: run.maxBacklog})
    }
  } finally { busy = false }
}

onmessage = async ({data}) => {
  try {
    if (data.type === "runtime") {
      ort.env.wasm.wasmPaths = "/runtime/"
      ort.env.wasm.numThreads = data.threads
      const baseline = await ort.InferenceSession.create(await (await fetch("/runtime-baseline.onnx")).arrayBuffer(), {executionProviders: ["wasm"]})
      await baseline.release()
      send("runtime_ready", {threads: data.threads})
    } else if (data.type === "init") {
      const initBegin = clock()
      ort.env.wasm.wasmPaths = "/runtime/"
      ort.env.wasm.numThreads = data.threads ?? 4
      ort.env.wasm.proxy = false
      let adapterInfo = null
      if (data.provider === "webgpu") {
        const adapter = await navigator.gpu?.requestAdapter({powerPreference: "high-performance"})
        if (!adapter) throw new Error("No WebGPU adapter available")
        const info = adapter.info
        adapterInfo = {vendor: info.vendor, architecture: info.architecture, device: info.device,
          description: info.description, isFallbackAdapter: info.isFallbackAdapter ?? adapter.isFallbackAdapter ?? null}
        ort.env.webgpu.adapter = adapter
      }
      const fetchBegin = clock()
      let [metadata, embedding, weights] = await Promise.all([
        fetch("/metadata.json").then(r => r.json()), fetch("/speaker.f32").then(r => r.arrayBuffer()),
        fetch("/model.onnx").then(r => r.arrayBuffer()),
      ])
      const assetFetchMs = clock() - fetchBegin
      schema = metadata.state_schema.entries
      if (schema.some(entry => !["float32", "int64"].includes(entry.dtype))) throw new Error("Unsupported state dtype")
      speaker = new ort.Tensor("float32", new Float32Array(embedding), [1, 704])
      const begin = clock()
      session = await ort.InferenceSession.create(weights, {executionProviders: [data.provider], graphOptimizationLevel: "all"})
      const modelBytes = weights.byteLength
      weights = null
      reset()
      send("initialized", {setup_ms: clock() - begin, total_init_ms: clock() - initBegin,
        asset_fetch_ms: assetFetchMs, model_bytes: modelBytes, provider: data.provider, adapter: adapterInfo,
        runtime: ort.env.versions, threads: ort.env.wasm.numThreads, cross_origin_isolated: self.crossOriginIsolated, state_count: schema.length,
        state_bytes: schema.reduce((sum, e) => sum + e.shape.reduce((a, b) => a * b, 1) * (e.dtype === "int64" ? 8 : 4), 0),
        note: data.provider === "webgpu" ? "WebGPU requested; unsupported graph nodes may execute on WASM. CPU-readable outputs include transfers." : "WASM CPU execution"})
    } else if (data.type === "start") {
      reset()
      run = {mode: data.mode, start: data.start, samples: 0, processed: 0, parts: [], times: [],
        retain: data.retain ?? true, emittedChunks: 0,
        delays: [], releaseLateness: [], firstOutput: null, maxBacklog: 0}
      queue = []
    } else if (data.type === "chunk" || data.type === "end") {
      queue.push(data.type === "end" ? {end: true} : data)
      await drain()
    }
  } catch (error) {
    run = null
    queue = []
    send("failed", {error: error.stack ?? String(error)})
  }
}
