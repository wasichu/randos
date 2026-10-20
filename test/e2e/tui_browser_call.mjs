// The browser half of the automated TUI ↔ browser call: one headless Chrome
// participant (fake mic) that finds a match and holds the call. Driven by
// clients/tui/test/integration/browser_call_test.exs, which plays the TUI.
//
//   BASE_URL=http://localhost:4010 node test/e2e/tui_browser_call.mjs <speaks> <listens> <hold_ms>
//
// Reports progress as JSON lines on stdout, one object each:
//   {"event": "looking"}                          waiting in the queue
//   {"event": "connected"}                        WebRTC connected
//   {"event": "result", "inbound": {...}}         after hold_ms: Chrome's
//     inbound-rtp audio stats (packetsReceived, totalAudioEnergy)
//   {"event": "error", "message": "..."}          then exits 1
//
// Host candidates stay real IPs (not mDNS .local names), as they would for a
// browser and helper on one machine or LAN; the helper can't resolve mDNS.

import {Browser, BASE_URL, inboundAudio, sleep} from "./cdp.mjs"

const [speaks, listens, holdMs] = process.argv.slice(2)
const report = event => console.log(JSON.stringify(event))

let browser
try {
  browser = await Browser.launch({
    port: 9335,
    extraArgs: ["--disable-features=WebRtcHideLocalIpsWithMdns"],
  })
  const page = await browser.newPage("browser")
  await page.open(BASE_URL)
  await page.findRando(speaks, listens)
  // Either we wait in the queue, or a peer was already waiting and we match
  // at once (then there's no "looking" to report).
  await page.waitFor(
    `!!document.querySelector("#looking-panel") || !!document.querySelector("#webrtc-audio")`,
    "looking or matched",
  )
  if (await page.eval(`!!document.querySelector("#looking-panel")`)) report({event: "looking"})

  await page.webrtcStateIs("connected")
  report({event: "connected"})

  await sleep(Number(holdMs))
  report({event: "result", inbound: await inboundAudio(page)})
} catch (error) {
  report({event: "error", message: error.message})
  process.exitCode = 1
} finally {
  await browser?.close()
}
