// End-to-end smoke test for the browser call flow: two real Chrome pages,
// fake microphones, real WebRTC loopback, against a running dev server.
//
//   RANDOS_CALL_SEGMENT_MS=8000 just dev   # in another terminal, or use `just smoke`
//   node test/e2e/call_smoke.mjs
//   BASE_URL=https://randos.fly.dev SMOKE_SKIP_EXTENSION=1 node test/e2e/call_smoke.mjs  # production
//
// No npm dependencies: drives headless Chrome over the DevTools protocol.
// Set CHROME_BIN to pick a browser; otherwise we look for Playwright's
// chrome-headless-shell or Google Chrome.

import {spawn, execSync} from "node:child_process"
import {existsSync, mkdtempSync, rmSync} from "node:fs"
import {tmpdir} from "node:os"
import {join} from "node:path"

const BASE_URL = process.env.BASE_URL ?? "http://localhost:4000"
const PORT = 9334
const sleep = ms => new Promise(resolve => setTimeout(resolve, ms))

function findChrome() {
  if (process.env.CHROME_BIN) return {bin: process.env.CHROME_BIN, headlessFlag: "--headless=new"}

  const shell = execSync(
    "find ~/Library/Caches/ms-playwright ~/.cache/ms-playwright -name chrome-headless-shell -type f -perm -u+x 2>/dev/null | head -1 || true",
  ).toString().trim()
  if (shell) return {bin: shell, headlessFlag: null}

  const chrome = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"
  if (existsSync(chrome)) return {bin: chrome, headlessFlag: "--headless=new"}

  throw new Error("No Chrome found; set CHROME_BIN")
}

// --- Minimal CDP client (flattened sessions over one browser socket) -------

class Browser {
  static async launch() {
    const {bin, headlessFlag} = findChrome()
    const profile = mkdtempSync(join(tmpdir(), "randos-smoke-"))
    const args = [
      `--remote-debugging-port=${PORT}`,
      `--user-data-dir=${profile}`,
      "--use-fake-device-for-media-stream",
      "--use-fake-ui-for-media-stream",
      "--autoplay-policy=no-user-gesture-required",
      "--disable-gpu",
      "--no-first-run",
      "about:blank",
    ]
    if (headlessFlag) args.unshift(headlessFlag)
    const proc = spawn(bin, args, {stdio: "ignore"})

    let version
    for (let i = 0; i < 50 && !version; i++) {
      try {
        version = await (await fetch(`http://127.0.0.1:${PORT}/json/version`)).json()
      } catch {
        await sleep(200)
      }
    }
    if (!version) throw new Error("Chrome did not start")

    const browser = new Browser(proc, profile, new WebSocket(version.webSocketDebuggerUrl))
    await new Promise(resolve => browser.ws.addEventListener("open", resolve))
    return browser
  }

  constructor(proc, profile, ws) {
    Object.assign(this, {proc, profile, ws, nextId: 0, pending: new Map()})
    ws.addEventListener("message", event => {
      const msg = JSON.parse(event.data)
      const waiter = msg.id && this.pending.get(msg.id)
      if (!waiter) return
      this.pending.delete(msg.id)
      msg.error ? waiter.reject(new Error(msg.error.message)) : waiter.resolve(msg.result)
    })
  }

  send(method, params = {}, sessionId) {
    const id = ++this.nextId
    this.ws.send(JSON.stringify({id, method, params, sessionId}))
    return new Promise((resolve, reject) => this.pending.set(id, {resolve, reject}))
  }

  // A page in its own browser context (separate cookies/storage = separate person).
  async newPage(name, {getUserMediaDelayMs = 0} = {}) {
    const {browserContextId} = await this.send("Target.createBrowserContext")
    const {targetId} = await this.send("Target.createTarget", {url: "about:blank", browserContextId})
    const {sessionId} = await this.send("Target.attachToTarget", {targetId, flatten: true})
    const page = new Page(this, name, sessionId)
    await page.send("Page.enable")
    await page.send("Runtime.enable")
    // Record every mic stream so tests can check nothing is left live, and
    // optionally slow getUserMedia down to open a teardown race window.
    await page.send("Page.addScriptToEvaluateOnNewDocument", {
      source: `
        window.__randosStreams = [];
        localStorage.setItem("randos:theme", "light");
        const original = navigator.mediaDevices.getUserMedia.bind(navigator.mediaDevices);
        navigator.mediaDevices.getUserMedia = async constraints => {
          await new Promise(r => setTimeout(r, ${getUserMediaDelayMs}));
          const stream = await original(constraints);
          window.__randosStreams.push(stream);
          return stream;
        };`,
    })
    return page
  }

  async close() {
    this.ws.close()
    const exited = new Promise(resolve => this.proc.once("exit", resolve))
    this.proc.kill()
    await exited
    rmSync(this.profile, {recursive: true, force: true, maxRetries: 5, retryDelay: 100})
  }
}

class Page {
  constructor(browser, name, sessionId) {
    Object.assign(this, {browser, name, sessionId})
  }

  send(method, params) {
    return this.browser.send(method, params, this.sessionId)
  }

  async eval(expression) {
    const {result, exceptionDetails} = await this.send("Runtime.evaluate", {
      expression,
      awaitPromise: true,
      returnByValue: true,
    })
    if (exceptionDetails) throw new Error(`${this.name}: ${exceptionDetails.exception?.description}`)
    return result.value
  }

  async waitFor(expression, label, timeoutMs = 20_000) {
    const deadline = Date.now() + timeoutMs
    while (Date.now() < deadline) {
      if (await this.eval(expression).catch(() => false)) return
      await sleep(150)
    }
    throw new Error(`${this.name}: timed out waiting for ${label}`)
  }

  async open() {
    await this.send("Page.navigate", {url: BASE_URL})
    await this.waitFor(`!!document.querySelector("[data-phx-main].phx-connected")`, "LiveView connect")
  }

  click(selector) {
    return this.eval(`document.querySelector(${JSON.stringify(selector)}).click()`)
  }

  // Choose languages, accept the terms, and press "Find a rando".
  async findRando(speaks, listens) {
    await this.eval(`(() => {
      const set = (id, value) => {
        const el = document.getElementById(id);
        el.value = value;
        el.dispatchEvent(new Event("input", {bubbles: true}));
        el.dispatchEvent(new Event("change", {bubbles: true}));
      };
      set("conversation_speaking_language", ${JSON.stringify(speaks)});
      set("conversation_listening_language", ${JSON.stringify(listens)});
      const box = document.getElementById("conversation_adult_acknowledgment");
      if (!box.checked) box.click();
    })()`)
    await this.waitFor(`!document.querySelector("#find-rando-button").disabled`, "find button enabled")
    await this.click("#find-rando-button")
  }

  webrtcStateIs(state) {
    return this.waitFor(
      `document.querySelector("#webrtc-audio")?.dataset.webrtcState === ${JSON.stringify(state)}`,
      `webrtc state ${state}`,
    )
  }

  streamCount() {
    return this.eval(`window.__randosStreams.length`)
  }

  // Live mic tracks among the first `count` streams this page captured.
  liveMicTracks(count = Infinity) {
    return this.eval(`window.__randosStreams.slice(0, ${count === Infinity ? "undefined" : count})
      .flatMap(s => s.getTracks()).filter(t => t.readyState === "live").length`)
  }

  // Non-transparent pixels on a visualizer canvas currently in the DOM.
  paintedPixels(canvasId) {
    return this.eval(`(() => {
      const canvas = document.getElementById(${JSON.stringify(canvasId)});
      if (!canvas) return -1;
      const {data} = canvas.getContext("2d").getImageData(0, 0, canvas.width, canvas.height);
      let painted = 0;
      for (let i = 3; i < data.length; i += 4) if (data[i] !== 0) painted++;
      return painted;
    })()`)
  }
}

// --- Scenarios ---------------------------------------------------------------

const results = []

async function scenario(name, fn) {
  const started = Date.now()
  try {
    await fn()
    results.push({name, ok: true})
    console.log(`  ✓ ${name} (${Date.now() - started}ms)`)
  } catch (error) {
    results.push({name, ok: false})
    console.log(`  ✗ ${name}\n      ${error.message}`)
  }
}

function assert(condition, message) {
  if (!condition) throw new Error(message)
}

const browser = await Browser.launch()
console.log(`call smoke against ${BASE_URL}`)

try {
  const a = await browser.newPage("A")
  const b = await browser.newPage("B")
  await Promise.all([a.open(), b.open()])

  await scenario("two people match and connect audio", async () => {
    await a.findRando("en", "es")
    await b.findRando("es", "en")
    await Promise.all([a.webrtcStateIs("connected"), b.webrtcStateIs("connected")])
  })

  // Production uses real 10-minute segments; set SMOKE_SKIP_EXTENSION=1 there.
  if (!process.env.SMOKE_SKIP_EXTENSION) await scenario("visualizers keep drawing after an extension", async () => {
    await Promise.all([
      a.waitFor(`!!document.querySelector("#extension-panel")`, "extension prompt", 60_000),
      b.waitFor(`!!document.querySelector("#extension-panel")`, "extension prompt", 60_000),
    ])
    await a.click("#continue-call-button")
    await b.click("#continue-call-button")
    await a.waitFor(`!!document.querySelector("#call-panel")`, "call panel after extension")
    await sleep(1_500)
    const painted = await a.paintedPixels("local-waveform-canvas")
    assert(painted > 0, `local visualizer canvas is blank after extension (painted=${painted})`)
  })

  await scenario("next rando releases the microphone", async () => {
    const streams = await a.streamCount()
    assert(streams > 0, "page A never captured a mic stream")
    await a.click("#next-rando-button")
    await sleep(1_000)
    const live = await a.liveMicTracks(streams)
    assert(live === 0, `${live} mic track(s) from the finished call still live`)
  })

  await scenario("ending a call stays on the page, goes idle, and releases the microphone", async () => {
    const e = await browser.newPage("E")
    const f = await browser.newPage("F")
    await Promise.all([e.open(), f.open()])
    await e.findRando("ja", "ko")
    await f.findRando("ko", "ja")
    await Promise.all([e.webrtcStateIs("connected"), f.webrtcStateIs("connected")])

    const streams = await e.streamCount()
    await e.eval(`window.__sameDocument = true`)
    await e.click("#end-call-button")
    await e.waitFor(`!!document.querySelector("#idle-panel")`, "idle after ending")
    assert(await e.eval(`window.__sameDocument === true`), "ending the call reloaded the page")
    await sleep(500)
    const live = await e.liveMicTracks(streams)
    assert(live === 0, `${live} mic track(s) still live after ending the call`)
  })

  await scenario("peer hanging up during the mic prompt releases the microphone", async () => {
    const c = await browser.newPage("C", {getUserMediaDelayMs: 2_500})
    const d = await browser.newPage("D")
    await Promise.all([c.open(), d.open()])
    await c.findRando("fr", "de")
    await d.findRando("de", "fr")
    await c.webrtcStateIs("requesting_microphone")
    await d.webrtcStateIs("waiting_for_offer")
    await d.click("#end-call-button")
    await c.waitFor(`!document.querySelector("#webrtc-audio")`, "C's call teardown")
    await sleep(3_500)
    const streams = await c.streamCount()
    const live = await c.liveMicTracks()
    assert(live === 0, `${live} mic track(s) left live (${streams} captured after teardown)`)
  })
} finally {
  await browser.close()
}

const failed = results.filter(r => !r.ok).length
console.log(`\n${results.length - failed} passed, ${failed} failed`)
process.exit(failed ? 1 : 0)
