// End-to-end smoke test for the browser call flow: two real Chrome pages,
// fake microphones, real WebRTC loopback, against a running dev server.
//
//   RANDOS_CALL_SEGMENT_MS=8000 just dev   # in another terminal, or use `just smoke`
//   node test/e2e/call_smoke.mjs
//   BASE_URL=https://randos.fly.dev SMOKE_SKIP_EXTENSION=1 node test/e2e/call_smoke.mjs  # production
//
// No npm dependencies: drives headless Chrome over the DevTools protocol
// (see cdp.mjs; CHROME_BIN picks the browser).

import {Browser, BASE_URL, sleep} from "./cdp.mjs"

// The server's connect timeout; just smoke shortens it (RANDOS_CONNECT_TIMEOUT_MS).
const CONNECT_TIMEOUT_MS = Number(process.env.RANDOS_CONNECT_TIMEOUT_MS ?? 15_000)

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
    await a.inCall()
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

    await e.inCall()
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
    await d.hangUp()
    await c.waitFor(`!document.querySelector("#webrtc-audio")`, "C's call teardown")
    await sleep(3_500)
    const streams = await c.streamCount()
    const live = await c.liveMicTracks()
    assert(live === 0, `${live} mic track(s) left live (${streams} captured after teardown)`)
  })

  // --- Client obligations (docs/architecture/participant_channel.md) -------
  // The same scenarios run for the TUI in clients/tui/test/integration.

  await scenario("obligation 6: mic denied ends the call with a reason; only the peer is requeued", async () => {
    const denied = await browser.newPage("denied", {getUserMediaError: "NotAllowedError"})
    const peer = await browser.newPage("peer6")
    await Promise.all([denied.open(), peer.open()])
    await denied.findRando("zh", "it")
    await peer.findRando("it", "zh")

    await denied.waitFor(
      `document.querySelector("#matchmaking-error")?.textContent.includes("microphone")`,
      "the reason on the idle page",
    )
    assert(await denied.eval(`!!document.querySelector("#idle-panel")`), "denied page isn't idle")
    await peer.waitFor(`!!document.querySelector("#looking-panel")`, "the peer requeued")
    await peer.stopLooking()
  })

  await scenario("obligation 4: a call that never connects ends for both at the connect timeout", async () => {
    const stuck = await browser.newPage("stuck", {relayOnly: true})
    const peer = await browser.newPage("peer4")
    await Promise.all([stuck.open(), peer.open()])
    await stuck.findRando("id", "ar")
    await peer.findRando("ar", "id")

    const limitMs = CONNECT_TIMEOUT_MS + 6_000
    await stuck.waitFor(`window.__randosCallEnds > 0`, "the stuck page's call to end", limitMs)
    await peer.waitFor(`window.__randosCallEnds > 0`, "the peer's call to end", limitMs)

    // Both were requeued (connection_failed) and, since a failed call keeps
    // no one apart, keep rematching each other; stop that.
    await stuck.hangUp()
    await peer.waitFor(`!!document.querySelector("#looking-panel")`, "the peer looking")
    await peer.stopLooking()
  })
} finally {
  await browser.close()
}

const failed = results.filter(r => !r.ok).length
console.log(`\n${results.length - failed} passed, ${failed} failed`)
process.exit(failed ? 1 : 0)
