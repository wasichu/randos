// The browser half of the automated TUI ↔ browser call: one headless Chrome
// participant (fake mic) that finds a match and holds the call. Driven by
// clients/tui/test/integration/browser_call_test.exs, which plays the TUI.
//
//   BASE_URL=http://localhost:4010 node test/e2e/tui_browser_call.mjs <speaks> <hears> <hold_ms>
//
// Environment (failure modes for the "Client obligations" scenarios):
//   EXPECT=connected (default) | call_ends — what this run waits for
//   MIC_ERROR=NotAllowedError — the mic prompt rejects (denied)
//   RELAY_ONLY=1 — this browser can never connect
//   REPORT_EVERY_MS=N — also report Chrome's inbound stats every N ms while
//     holding ({"event": "inbound", "inbound": {...}})
//   INVITE=1 — make an invitation link instead of finding a rando, and
//     report it ({"event": "invitation", "url": "..."})
//   JOIN=<token> — join the invitation with this token instead
//
// Reports progress as JSON lines on stdout, one object each:
//   {"event": "looking"}                          waiting in the queue
//   {"event": "connected"}                        WebRTC connected
//   {"event": "result", "inbound": {...}}         after hold_ms: Chrome's
//     inbound-rtp audio stats (packetsReceived, totalAudioEnergy)
//   {"event": "call_ended", "idle": bool, "looking": bool, "error": "..."}
//                                                 (EXPECT=call_ends): the call
//     ended for this browser; where it ended up, and its error message
//   {"event": "error", "message": "..."}          then exits 1
//
// Host candidates stay real IPs (not mDNS .local names), as they would for a
// browser and helper on one machine or LAN; the helper can't resolve mDNS.

import {Browser, BASE_URL, inboundAudio, sleep} from "./cdp.mjs"

const [speaks, hears, holdMs] = process.argv.slice(2)
const expect = process.env.EXPECT ?? "connected"
const connectTimeoutMs = Number(process.env.RANDOS_CONNECT_TIMEOUT_MS ?? 15_000)
const report = event => console.log(JSON.stringify(event))

let browser

// Driven by an Elixir test over a Port: when the test ends (passed, failed,
// or timed out), the Port closes our stdin. Leave then, instead of carrying
// on unwatched; Chrome follows us (its DevTools pipe closes).
process.stdin.on("end", () => process.exit(1))
process.stdin.resume()

try {
  browser = await Browser.launch({extraArgs: ["--disable-features=WebRtcHideLocalIpsWithMdns"]})
  const page = await browser.newPage("browser", {
    getUserMediaError: process.env.MIC_ERROR || null,
    relayOnly: process.env.RELAY_ONLY === "1",
  })
  await page.open(BASE_URL)
  if (process.env.MASKING) {
    const id = process.env.MASKING
    if (!['lower_resonance','lower_resonance_pitch','higher_resonance','higher_resonance_pitch'].includes(id)) throw Error('Invalid test masking style')
    await page.eval(`{
      const family=document.getElementById('voice-family'),tone=document.getElementById('voice-tone');
      family.value=${JSON.stringify(id.endsWith('_pitch')?'tone_pitch':'tone')};family.dispatchEvent(new Event('change',{bubbles:true}));
      tone.value=${JSON.stringify(id.startsWith('lower')?'fuller':'brighter')};tone.dispatchEvent(new Event('change',{bubbles:true}));
    }`)
  }
  if (process.env.INVITE === "1") {
    report({event: "invitation", url: await page.invite(speaks, hears)})
  } else if (process.env.JOIN) {
    await page.join(`${BASE_URL}/join#${process.env.JOIN}`)
  } else {
    await page.findRando(speaks, hears)
  }
  // Either we wait in the queue, or a peer was already waiting and we match
  // at once (then there's no "looking" to report). A failing call can come
  // and go faster than this poll, so call_ends runs skip it and rely on the
  // call-ends counter.
  if (expect !== "call_ends" && !process.env.INVITE && !process.env.JOIN) {
    await page.waitFor(
      `!!document.querySelector("#looking-panel") || !!document.querySelector("#webrtc-audio")`,
      "looking or matched",
    )
    if (await page.eval(`!!document.querySelector("#looking-panel")`)) report({event: "looking"})
  }

  if (expect === "call_ends") {
    await page.waitFor(`window.__randosCallEnds > 0`, "the call to end", connectTimeoutMs + 6_000)
    await sleep(300)
    report({
      event: "call_ended",
      idle: await page.eval(`!!document.querySelector("#idle-panel")`),
      looking: await page.eval(`!!document.querySelector("#looking-panel")`),
      error: await page.eval(`document.querySelector("#matchmaking-error")?.textContent.trim() ?? null`),
    })
    // A requeued page keeps being rematched (a failed call keeps no one
    // apart); stop.
    await page.eval(`document.querySelector("#cancel-connection-button, #cancel-search-button")?.click()`)
  } else {
    await page.webrtcStateIs("connected")
    report({event: "connected"})

    // REPORT_EVERY_MS: Chrome's inbound stats while holding too, so a test
    // can watch the audio stop at a cut and come back (ICE restart).
    const every = Number(process.env.REPORT_EVERY_MS ?? 0)
    const until = Date.now() + Number(holdMs)
    while (every > 0 && Date.now() + every < until) {
      await sleep(every)
      report({event: "inbound", inbound: await inboundAudio(page)})
    }
    await sleep(Math.max(until - Date.now(), 0))
    report({event: "result", inbound: await inboundAudio(page)})
  }
} catch (error) {
  report({event: "error", message: error.message})
  process.exitCode = 1
} finally {
  await browser?.close()
}
