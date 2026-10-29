// Offline native/WASM parity and timing probe. No playback or network.
// Run after `cargo build --release -p randos_voice --example render` and
// `just voice-wasm`: node tools/voice-eval/check_wasm.mjs > report.json
import assert from "node:assert/strict"
import {readFileSync} from "node:fs"
import {spawnSync} from "node:child_process"
import {createHash} from "node:crypto"
import {cpus} from "node:os"
import {fileURLToPath} from "node:url"

const root = new URL("../../", import.meta.url)
const wasm = readFileSync(new URL("assets/js/randos/voice/randos_voice.wasm", root))
const module = new WebAssembly.Module(wasm)
const binary = fileURLToPath(new URL("target/release/examples/render", root))
const block = 128, rate = 48000

function fixture(name) {
  const bytes = readFileSync(new URL(`dev/voice_lab/clips/${name}.wav`, root))
  assert.equal(bytes.toString("ascii", 0, 4), "RIFF")
  assert.equal(bytes.toString("ascii", 8, 12), "WAVE")
  let pcm, sourceRate
  for (let pos = 12; pos + 8 <= bytes.length;) {
    const size = bytes.readUInt32LE(pos + 4), start = pos + 8
    assert.ok(start + size <= bytes.length)
    const tag = bytes.toString("ascii", pos, pos + 4)
    if (tag === "fmt ") {
      assert.equal(bytes.readUInt16LE(start), 1) // PCM
      assert.equal(bytes.readUInt16LE(start + 2), 1) // mono
      assert.equal(bytes.readUInt16LE(start + 14), 16)
      sourceRate = bytes.readUInt32LE(start + 4)
    }
    if (tag === "data") pcm = bytes.subarray(start, start + size)
    pos = start + size + size % 2
  }
  assert.ok(pcm && sourceRate)
  const frames = pcm.length / 2
  // This shared linear interpolation only constructs a test fixture; it
  // isn't the benchmark resampler or the processor's anti-alias filter.
  return Float32Array.from({length: Math.floor(frames * rate / sourceRate)}, (_, i) => {
    const at = i * sourceRate / rate, lo = Math.floor(at), part = at - lo
    const a = pcm.readInt16LE(Math.min(lo, frames - 1) * 2)
    const b = pcm.readInt16LE(Math.min(lo + 1, frames - 1) * 2)
    return (a + (b - a) * part) / 32768
  })
}

function run(input, variant, value) {
  const e = new WebAssembly.Instance(module).exports
  assert.equal(e.voice_new(variant, rate, block), 1)
  e.voice_set_param(0, value)
  const from = new Float32Array(e.memory.buffer, e.voice_input(), block)
  const to = new Float32Array(e.memory.buffer, e.voice_output(), block)
  const output = new Float32Array(input.length)
  let worst = 0
  const started = performance.now()
  for (let at = 0; at < input.length; at += block) {
    const count = Math.min(block, input.length - at), before = performance.now()
    from.set(input.subarray(at, at + count))
    e.voice_process(count)
    output.set(to.subarray(0, count), at)
    worst = Math.max(worst, performance.now() - before)
  }
  return {output, worst_block_ms: worst, seconds: (performance.now() - started) / 1000}
}

const rows = []
for (const name of ["low_voice", "mid_voice", "high_voice", "mencken_wasichu"]) {
  const input = fixture(name)
  for (const [variant, id, value] of [["pitch_shift", 1, -4], ["mcadams", 2, 1], ["mcadams", 2, .7], ["mcadams", 2, .9]]) {
    const native = spawnSync(binary, ["--variant", variant, "--rate", `${rate}`, "--param", `0=${value}`], {
      input: Buffer.from(input.buffer), maxBuffer: 16 * 1024 * 1024, timeout: 30000,
    })
    assert.equal(native.status, 0, native.stderr?.toString())
    assert.equal(native.stdout.length, input.byteLength)
    const expected = new Float32Array(Uint8Array.from(native.stdout).buffer)
    run(input, id, value) // warm the compiled code before timing a fresh instance
    const measured = run(input, id, value)
    let maximum = 0, squared = 0
    measured.output.forEach((value, i) => {
      const error = Math.abs(value - expected[i])
      assert.ok(Number.isFinite(error))
      maximum = Math.max(maximum, error)
      squared += error * error
    })
    assert.ok(maximum < 1e-3, `${name}/${variant}/${value}: maximum error ${maximum}`)
    rows.push({clip: name, variant, parameter: value, maximum_error: maximum,
      rms_error: Math.sqrt(squared / input.length), native: JSON.parse(native.stderr),
      wasm: {worst_block_ms: measured.worst_block_ms, seconds: measured.seconds}})
  }
}
const unsupported = new WebAssembly.Instance(module).exports
assert.equal(unsupported.voice_new(2, 44100, block), 0)
assert.equal(unsupported.voice_new(2, NaN, block), 0)
assert.equal(unsupported.voice_new(2, Infinity, block), 0)
console.log(JSON.stringify({generated_at: new Date().toISOString(), runtime: process.version,
  cpu: cpus()[0]?.model, wasm_sha256: createHash("sha256").update(wasm).digest("hex"),
  sample_rate: rate, block_samples: block, block_budget_ms: block / rate * 1000,
  limitation: "Node WASM with buffer copies; not browser AudioWorklet scheduling or a real-time guarantee.",
  results: rows}, null, 2))
