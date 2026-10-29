// A throwaway same-origin site and muted Chrome. Both die with this process;
// Chrome uses the existing parent-owned CDP pipe, never a DevTools port.
import {createServer} from "node:http"
import {createReadStream, readFileSync, writeFileSync, mkdirSync, copyFileSync} from "node:fs"
import {execFileSync} from "node:child_process"
import {resolve, dirname, basename} from "node:path"
import {fileURLToPath} from "node:url"
import {createHash} from "node:crypto"
import {arch, platform, cpus, totalmem} from "node:os"
import {Browser} from "../../test/e2e/cdp.mjs"

const here = dirname(fileURLToPath(import.meta.url))
const root = resolve(here, "../.."), data = resolve(root, "tmp/voice-browser")
const preparation = JSON.parse(readFileSync(process.env.PREPARATION_FILE ? resolve(root, process.env.PREPARATION_FILE) : resolve(data, "preparation.json")))
const inputFile = process.env.INPUT_FILE ? resolve(root, process.env.INPUT_FILE) : resolve(data, "input.f32")
const modes = (process.env.MODES ?? "parity,paced").split(",")
if (modes.some(mode => !["parity", "paced"].includes(mode)) || !modes.includes("parity")) throw new Error("Probe modes must include parity and may include paced")
const runtime = resolve(here, "node_modules/onnxruntime-web/dist")
const profile = process.env.RESOURCE_PROFILE === "1"
const threads = Number(process.env.WASM_THREADS ?? 4)
const isolated = threads > 1
const outputTag = process.env.OUTPUT_TAG ?? ""
mkdirSync(resolve(data, "site"), {recursive: true})
execFileSync(resolve(here, "node_modules/.bin/esbuild"), [resolve(here, "worker.js"), "--bundle", "--format=esm", `--outfile=${data}/site/worker.js`], {stdio: "inherit"})
copyFileSync(resolve(here, "page.js"), resolve(data, "site/page.js"))
const html = '<!doctype html><meta charset="utf-8"><title>TVTSyn browser probe</title><h1>TVTSyn browser probe</h1><pre id="status">Starting local inference…</pre><script type="module" src="/page.js"></script>'
const routes = new Map([
  ["/", {body: html, type: "text/html"}],
  ["/worker.js", {path: resolve(data, "site/worker.js"), type: "text/javascript"}],
  ["/page.js", {path: resolve(data, "site/page.js"), type: "text/javascript"}],
  ["/input.f32", {path: inputFile}],
  ["/runtime-baseline.onnx", {path: resolve(data, "runtime-baseline.onnx")}],
  ["/speaker.f32", {path: resolve(data, "speaker.f32")}],
  ["/model.onnx", {path: process.env.MODEL_GRAPH ? resolve(root, process.env.MODEL_GRAPH) : resolve(preparation.root, "onnx/tvtsyn_step_100ms.onnx")}],
  ["/metadata.json", {body: JSON.stringify(preparation.metadata), type: "application/json"}],
])
const server = createServer((request, response) => {
  const path = new URL(request.url, "http://localhost").pathname
  let entry = routes.get(path)
  if (/^\/runtime\/ort-wasm-simd-threaded(?:\.(?:jsep|asyncify|jspi))?\.(?:mjs|wasm)$/.test(path)) {
    entry = {path: resolve(runtime, basename(path)), type: path.endsWith(".wasm") ? "application/wasm" : "text/javascript"}
  }
  if (isolated) {
    response.setHeader("Cross-Origin-Opener-Policy", "same-origin")
    response.setHeader("Cross-Origin-Embedder-Policy", "require-corp")
  }
  response.setHeader("Cross-Origin-Resource-Policy", "same-origin")
  if (!entry) { response.writeHead(404); response.end(); return }
  response.setHeader("Content-Type", entry.type ?? "application/octet-stream")
  if (entry.body) response.end(entry.body)
  else createReadStream(entry.path).on("error", () => { response.destroy() }).pipe(response)
})
await new Promise(resolve => server.listen(0, "127.0.0.1", resolve))
const origin = `http://127.0.0.1:${server.address().port}`
const {root: _cachePath, metadata: _schema, ...native} = preparation
const report = {generated_at: new Date().toISOString(), native, runs: [],
  execution: Object.fromEntries([
    ["graph", routes.get("/model.onnx").path], ["input", inputFile],
    ["speaker",resolve(data,"speaker.f32")], ["native_reference",resolve(data,process.env.REFERENCE_FILE ?? "native.f32")],
  ].map(([name,path])=>[name,{sha256:createHash("sha256").update(readFileSync(path)).digest("hex"),bytes:readFileSync(path).length}])),
  machine: {architecture: arch(), platform: platform(), cpu: cpus()[0]?.model, memory_bytes: totalmem()},
  harness_sha256: Object.fromEntries(["prepare.py", "worker.js", "page.js", "run.mjs", "package-lock.json", "requirements.lock"].map(name => [name, createHash("sha256").update(readFileSync(resolve(here, name))).digest("hex")])),
  scope: `${preparation.input_samples / 16000}-second ${preparation.input_kind ?? "public speech"} input; ${modes.includes("paced") ? "parity and paced repeat" : "waveform parity only, no paced run"}. No microphone, training, privacy/recovery evaluation or production integration.`,
  memory_note: "Approximate sum of RSS across the Chrome process tree; shared pages may be counted more than once. Not isolated model/GPU allocation.",
  configuration: {gpu_opt_in: true, flags: ["--enable-unsafe-webgpu"], muted: true, cross_origin_isolated: isolated, wasm_threads: threads, resource_profile: profile, modes}}
mkdirSync(resolve(here, "results"), {recursive: true})
const save = () => writeFileSync(resolve(here, process.env.RESULT_PATH ?? "results/browser.json"), JSON.stringify(report, null, 2) + "\n")
function rss(pid) {
  const rows = execFileSync("ps", ["-axo", "pid=,ppid=,rss="], {encoding: "utf8"}).trim().split("\n").map(row => row.trim().split(/\s+/).map(Number))
  const descendants = new Set([pid])
  for (let changed = true; changed;) {
    changed = false
    for (const [child, parent] of rows) if (descendants.has(parent) && !descendants.has(child)) { descendants.add(child); changed = true }
  }
  return rows.filter(([child]) => descendants.has(child)).reduce((sum, [, , kib]) => sum + kib, 0) / 1024
}
function compare(a, b) {
  if (a.length !== b.length) throw new Error("Browser/native output length differs")
  let sum = 0, power = 0, max = 0, peak = 0
  for (let i = 0; i < a.length; i++) {
    if (!Number.isFinite(a[i])) throw new Error("Nonfinite browser output")
    const error = a[i] - b[i]
    sum += error * error; power += b[i] * b[i]; max = Math.max(max, Math.abs(error)); peak = Math.max(peak, Math.abs(a[i]))
  }
  return {samples: a.length, max_absolute_error: max, rms_error: Math.sqrt(sum / a.length), relative_rms_error: Math.sqrt(sum / power), peak}
}
try {
  for (const provider of (process.env.PROVIDERS ?? "webgpu,wasm").split(",")) {
    const result = {provider, status: "starting", memory: [], stages: [], console: []}
    report.runs.push(result); save()
    let browser, memoryTimer
    try {
      browser = await Browser.launch({gpu: true, extraArgs: report.configuration.flags})
      result.browser = await browser.send("Browser.getVersion")
      const page = await browser.newPage(`tvtsyn-${provider}`)
      async function stage(name) {
        if (!profile) return
        await new Promise(resolve => setTimeout(resolve, 2000))
        const samples = []
        for (let i=0;i<5;i++) { samples.push(rss(browser.proc.pid)); await new Promise(resolve=>setTimeout(resolve,200)) }
        result.stages.push({name, rss_mib: [...samples].sort((a,b)=>a-b)[2], samples})
        save()
      }
      await stage("empty_browser")
      memoryTimer = setInterval(() => {
        try { result.memory.push({time: Date.now(), rss_mib: rss(browser.proc.pid)}) } catch {}
      }, 2000)
      await page.send("Page.navigate", {url: origin})
      await page.waitFor("!!window.probe?.init", "probe scripts", 10_000)
      if (profile) {
        await page.eval(`window.probe.runtime(${threads})`)
        await page.waitFor(`window.probe.events.some(e=>e.type==='runtime_ready'||e.type==='failed')`, "runtime baseline", 30_000)
        await stage("runtime_only")
      }
      await page.eval(`window.probe.init(${JSON.stringify(provider)},${threads})`)
      await page.waitFor(`window.probe.events.some(e=>e.type==='initialized'||e.type==='failed')`, `${provider} model initialization`, 180_000)
      const initialized = await page.eval(`window.probe.events.find(e=>e.type==='initialized'||e.type==='failed')`)
      if (initialized.type === "failed") throw new Error(initialized.error)
      result.initialized = initialized
      await stage("model_ready")
      console.log(provider, "initialized", JSON.stringify(initialized)); save()
      if (provider === "webgpu" && (initialized.adapter?.isFallbackAdapter || initialized.adapter?.architecture === "swiftshader")) {
        throw new Error("Only a software WebGPU adapter is available in this browser; skipping hardware performance claims and paced GPU run")
      }
      for (const mode of modes) {
        await page.eval(`window.probe.run(${JSON.stringify(mode)},${mode === "parity" || !profile})`)
        await page.waitFor(`window.probe.events.some(e=>e.type==='failed'||(e.type==='complete'&&e.report.mode===${JSON.stringify(mode)}))`, `${provider} ${mode} conversion`, 180_000)
        const failure = await page.eval(`window.probe.events.find(e=>e.type==='failed')`)
        if (failure) throw new Error(failure.error)
        result[mode] = await page.eval(`window.probe.events.find(e=>e.type==='complete'&&e.report.mode===${JSON.stringify(mode)}).report`)
        const output = await page.eval(`window.probe.outputs[${JSON.stringify(mode)}]`)
        writeFileSync(resolve(data, `${outputTag}${provider}-${mode}.f32`), Buffer.from(new Float32Array(output).buffer))
        if (mode === "parity") {
          const bytes = readFileSync(resolve(data, process.env.REFERENCE_FILE ?? "native.f32"))
          result.comparison = compare(output, new Float32Array(bytes.buffer.slice(bytes.byteOffset, bytes.byteOffset + bytes.byteLength)))
          if (result.comparison.relative_rms_error > .001 || result.comparison.max_absolute_error > .01) {
            throw new Error("Waveform parity failed; skipping paced run until conversion is correct")
          }
        }
        console.log(provider, mode, JSON.stringify(result[mode])); save()
      }
      result.status = "complete"
      await stage("after_stream")
      await page.eval("window.probe.close()")
      await stage("worker_terminated")
    } catch (error) {
      result.status = "failed"
      result.error = error.stack ?? String(error)
      console.log(provider, "failed", result.error)
    } finally {
      clearInterval(memoryTimer)
      if (browser) await browser.close()
      save()
    }
  }
} finally {
  server.closeAllConnections()
  await new Promise(resolve => server.close(resolve))
}
console.log(`Saved ${here}/results/browser.json`)
if (!report.runs.some(run => run.status === "complete")) process.exitCode = 1
