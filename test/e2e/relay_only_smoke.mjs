// The relay-only obligation, browser to browser: against a server whose only
// TURN server never answers (`just smoke` runs this with
// RANDOS_TEST_UNREACHABLE_RELAY=1), two pages are told "relay" and must never
// connect. On one machine, direct (host) candidates would connect at once,
// so a page that ignored the policy fails this test.

import {Browser, sleep} from "./cdp.mjs"

const CONNECT_TIMEOUT_MS = Number(process.env.RANDOS_CONNECT_TIMEOUT_MS ?? 15_000)

const browser = await Browser.launch()
let ok = false
try {
  const a = await browser.newPage("A")
  const b = await browser.newPage("B")
  await Promise.all([a.open(), b.open()])
  // Remember whether either page ever connects.
  for (const page of [a, b])
    await page.eval(`new MutationObserver(() => {
      if (document.querySelector("#webrtc-audio[data-webrtc-state='connected']")) window.__connected = true
    }).observe(document, {subtree: true, childList: true, attributes: true, attributeFilter: ["data-webrtc-state"]})`)

  await a.findRando("it", "tr")
  await b.findRando("tr", "it")
  await a.waitFor(`!!document.querySelector("#webrtc-audio[data-ice-transport-policy='relay']")`, "a relay-only call")

  const limitMs = CONNECT_TIMEOUT_MS + 6_000
  for (const page of [a, b])
    await page.waitFor(`window.__randosCallEnds > 0 || window.__connected === true`, `${page.name}'s call to end`, limitMs)
  const connected = await Promise.all([a, b].map(page => page.eval(`window.__connected === true`)))
  if (connected.some(Boolean)) throw new Error("a page connected without the relay: it ignored the relay-only policy")

  await a.hangUp()
  await sleep(200)
  ok = true
  console.log("  ✓ relay-only: with no reachable relay, two browsers never connect directly")
} catch (error) {
  console.log(`  ✗ relay-only\n      ${error.message}`)
} finally {
  await browser.close()
}
process.exit(ok ? 0 : 1)
