// Minimal Chrome DevTools Protocol harness for the e2e tests (no npm
// dependencies): launch headless Chrome with fake media, open pages as
// separate people, drive and inspect them. Used by call_smoke.mjs and
// tui_browser_call.mjs.
//
// Set CHROME_BIN to pick a browser; otherwise we look for Playwright's
// chrome-headless-shell or Google Chrome.

import {spawn, execSync} from "node:child_process"
import {existsSync, mkdtempSync, rmSync} from "node:fs"
import {tmpdir} from "node:os"
import {join} from "node:path"

export const BASE_URL = process.env.BASE_URL ?? "http://localhost:4000"
export const sleep = ms => new Promise(resolve => setTimeout(resolve, ms))

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

export class Browser {
  // DevTools runs over a pipe (fds 3 and 4), not a port: Chrome exits as soon
  // as the pipe closes, which the OS does when this process dies, however it
  // dies (even kill -9). So a Chrome can never outlive the run that started
  // it, and concurrent runs can't collide on a port. `extraArgs`: more flags.
  static async launch({extraArgs = []} = {}) {
    const {bin, headlessFlag} = findChrome()
    const profile = mkdtempSync(join(tmpdir(), "randos-smoke-"))
    const args = [
      "--remote-debugging-pipe",
      `--user-data-dir=${profile}`,
      "--use-fake-device-for-media-stream",
      "--use-fake-ui-for-media-stream",
      "--autoplay-policy=no-user-gesture-required",
      "--disable-gpu",
      "--no-first-run",
      ...extraArgs,
      "about:blank",
    ]
    if (headlessFlag) args.unshift(headlessFlag)
    const proc = spawn(bin, args, {stdio: ["ignore", "ignore", "ignore", "pipe", "pipe"]})

    const browser = new Browser(proc, profile)
    // Chrome answers once it's up; fail clearly if it can't start.
    await Promise.race([
      browser.send("Browser.getVersion"),
      new Promise((_, reject) => proc.once("exit", code => reject(new Error(`Chrome exited (${code}) at startup`)))),
      sleep(20_000).then(() => Promise.reject(new Error("Chrome did not start"))),
    ])
    return browser
  }

  constructor(proc, profile) {
    Object.assign(this, {proc, profile, nextId: 0, pending: new Map(), buffer: ""})
    // Messages from Chrome arrive on fd 4, each terminated by a NUL byte.
    proc.stdio[4].setEncoding("utf8")
    proc.stdio[4].on("data", chunk => {
      this.buffer += chunk
      let end
      while ((end = this.buffer.indexOf("\0")) >= 0) {
        const msg = JSON.parse(this.buffer.slice(0, end))
        this.buffer = this.buffer.slice(end + 1)
        const waiter = msg.id && this.pending.get(msg.id)
        if (!waiter) continue
        this.pending.delete(msg.id)
        msg.error ? waiter.reject(new Error(msg.error.message)) : waiter.resolve(msg.result)
      }
    })
    proc.once("exit", () => {
      for (const {reject} of this.pending.values()) reject(new Error("Chrome exited"))
      this.pending.clear()
    })
  }

  send(method, params = {}, sessionId) {
    const id = ++this.nextId
    this.proc.stdio[3].write(JSON.stringify({id, method, params, sessionId}) + "\0")
    return new Promise((resolve, reject) => this.pending.set(id, {resolve, reject}))
  }

  // A page in its own browser context (separate cookies/storage = separate person).
  // Options simulate a client's failure modes (see "Client obligations" in
  // participant_channel.md): `getUserMediaError` makes the mic prompt reject
  // with that DOMException name (e.g. "NotAllowedError" = denied);
  // `relayOnly` forces relay-only ICE with no TURN server, so this page can
  // never connect.
  async newPage(name, {getUserMediaDelayMs = 0, getUserMediaError = null, relayOnly = false} = {}) {
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
          const failWith = ${JSON.stringify(getUserMediaError)};
          if (failWith) throw new DOMException("simulated", failWith);
          const stream = await original(constraints);
          window.__randosStreams.push(stream);
          return stream;
        };
        // Record peer connections so tests can read getStats().
        window.__randosPeers = [];
        const OriginalPeer = window.RTCPeerConnection;
        window.RTCPeerConnection = function (config = {}, ...rest) {
          if (${relayOnly}) config = {...config, iceTransportPolicy: "relay"};
          const pc = new OriginalPeer(config, ...rest);
          window.__randosPeers.push(pc);
          return pc;
        };
        window.RTCPeerConnection.prototype = OriginalPeer.prototype;
        // Each time this page's call element goes away, the call ended for
        // this page (even if it's requeued and rematched straight away).
        window.__randosCallEnds = 0;
        new MutationObserver(records => {
          for (const record of records)
            for (const node of record.removedNodes)
              if (node.id === "webrtc-audio" || node.querySelector?.("#webrtc-audio")) window.__randosCallEnds++;
        }).observe(document, {childList: true, subtree: true});`,
    })
    return page
  }

  async close() {
    const exited = new Promise(resolve => this.proc.once("exit", resolve))
    this.proc.stdio[3].end()
    this.proc.kill()
    await exited
    rmSync(this.profile, {recursive: true, force: true, maxRetries: 5, retryDelay: 100})
  }
}

export class Page {
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

  async open(url = BASE_URL) {
    await this.send("Page.navigate", {url})
    await this.waitFor(`!!document.querySelector("[data-phx-main].phx-connected")`, "LiveView connect")
  }

  // Hang up from whichever phase the call is in: "connecting" shows a cancel
  // button, the call itself an End button (both send end_call).
  async hangUp() {
    await this.waitFor(
      `!!document.querySelector("#end-call-button, #cancel-connection-button")`,
      "a hang-up button",
    )
    return this.eval(`document.querySelector("#end-call-button, #cancel-connection-button").click()`)
  }

  callEnds() {
    return this.eval(`window.__randosCallEnds`)
  }

  // Stop looking, so a requeued page doesn't keep rematching.
  async stopLooking() {
    await this.eval(`document.querySelector("#cancel-search-button")?.click()`)
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


// Inbound audio on the page's latest peer connection: packets and Chrome's
// own energy measure, which is zero for silence.
export async function inboundAudio(page) {
  return page.eval(`(async () => {
    const pc = window.__randosPeers.at(-1);
    if (!pc) return null;
    const stats = await pc.getStats();
    for (const report of stats.values()) {
      if (report.type === "inbound-rtp" && report.kind === "audio") {
        return {packetsReceived: report.packetsReceived, totalAudioEnergy: report.totalAudioEnergy ?? 0};
      }
    }
    return null;
  })()`)
}
