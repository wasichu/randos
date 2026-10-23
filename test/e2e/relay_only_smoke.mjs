// The relay-only obligation, browser to browser: against a server whose only
// TURN server never answers (`just smoke` runs this with
// RANDOS_TEST_UNREACHABLE_RELAY=1), calls are relay-only and must never
// connect. On one machine, direct (host) candidates would connect at once,
// so a call that connects went direct.
//
//   1. Obedient pages: each must use only the relay (obligation 8).
//   2. Pages that ignore the policy and offer their direct addresses: the
//      server must drop those addresses, so these can't connect either.

import {Browser, sleep} from "./cdp.mjs"

const CONNECT_TIMEOUT_MS = Number(process.env.RANDOS_CONNECT_TIMEOUT_MS ?? 15_000)
const browser = await Browser.launch()
const results = []

async function scenario(name, options, [speaks, hears]) {
  try {
    const a = await browser.newPage(`${name} A`, options)
    const b = await browser.newPage(`${name} B`, options)
    await Promise.all([a.open(), b.open()])
    // Remember whether either page ever connects.
    for (const page of [a, b])
      await page.eval(`new MutationObserver(() => {
        if (document.querySelector("#webrtc-audio[data-webrtc-state='connected']")) window.__connected = true
      }).observe(document, {subtree: true, childList: true, attributes: true, attributeFilter: ["data-webrtc-state"]})`)

    await a.findRando(speaks, hears)
    await b.findRando(hears, speaks)
    await a.waitFor(`!!document.querySelector("#webrtc-audio[data-ice-transport-policy='relay']")`, "a relay-only call")

    const limitMs = CONNECT_TIMEOUT_MS + 6_000
    for (const page of [a, b])
      await page.waitFor(`window.__randosCallEnds > 0 || window.__connected === true`, `${page.name}'s call to end`, limitMs)
    const connected = await Promise.all([a, b].map(page => page.eval(`window.__connected === true`)))
    if (connected.some(Boolean)) throw new Error("connected without the relay: a direct address reached the peer")

    // Requeued, the two rematch at once (a failed call keeps no one apart),
    // so hang up, then leave.
    await a.hangUp()
    await sleep(200)
    await Promise.all([a, b].map(page => page.send("Page.navigate", {url: "about:blank"})))
    results.push(true)
    console.log(`  ✓ ${name}`)
  } catch (error) {
    results.push(false)
    console.log(`  ✗ ${name}\n      ${error.message}`)
  }
}

try {
  await scenario("relay-only: two browsers never connect directly", {}, ["it", "tr"])
  await scenario("relay-only: the server keeps a disobedient client's addresses from its peer",
    {ignoreRelayPolicy: true}, ["fr", "ko"])
} finally {
  await browser.close()
}
process.exit(results.every(Boolean) ? 0 : 1)
