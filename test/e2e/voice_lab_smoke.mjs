// The voice lab, end to end, against a dev server (the lab is dev only):
// every source renders through every processor (offline, so silent), the
// numbers come out sane, and the seam's live latency gets measured. Prints
// the numbers.
//
//   BASE_URL=http://localhost:4000 node test/e2e/voice_lab_smoke.mjs

import {writeFileSync} from "node:fs"
import {Browser, BASE_URL} from "./cdp.mjs"

const failures = []
const check = (ok, message) => ok || failures.push(message)

const browser = await Browser.launch()
try {
  const page = await browser.newPage("lab")
  await page.open(`${BASE_URL}/dev/voice-lab`)
  await page.waitFor(`document.querySelector("#voice-lab-status")?.dataset.state === "ready"`, "the lab to load", 30_000)

  const sources = JSON.parse(await page.eval(`JSON.stringify([...document.querySelectorAll("#voice-lab-source option")].map(o => o.value))`))
  check(sources.length >= 4, `expected 3 clips and the test tone, got ${sources}`)
  const sliders = Number(await page.eval(`document.querySelectorAll("#voice-lab-params input[type=range]").length`))
  check(sliders === 2, `expected the pitch shifter's 2 sliders, got ${sliders}`)

  for (const source of sources) {
    await page.eval(`document.querySelector("#voice-lab-source").value = ${JSON.stringify(source)}`)
    await page.click("#voice-lab-render")
    await page.waitFor(`["rendered", "failed"].includes(document.querySelector("#voice-lab-status").dataset.state)`, `rendering ${source}`, 60_000)
    const status = await page.eval(`document.querySelector("#voice-lab-status").textContent`)
    check(!status.startsWith("Render failed"), `${source}: ${status}`)

    const results = JSON.parse(await page.eval(`JSON.stringify([...document.querySelectorAll("#voice-lab-results article")].map(card => ({
      id: card.id, rtf: card.dataset.realTimeFactor, latency: card.dataset.latencyMs,
      spectrogram: card.querySelector("canvas").width})))`))
    console.log(source)
    for (const r of results) {
      console.log(`  ${r.id}: real-time factor ${r.rtf ?? "-"}, delay ${r.latency ?? "-"} ms, spectrogram ${r.spectrogram} columns`)
      check(r.spectrogram > 0, `${source} ${r.id}: no spectrogram`)
    }
    const passthrough = results.find(r => r.id === "voice-lab-result-passthrough")
    const pitch = results.find(r => r.id === "voice-lab-result-pitch_shift")
    check(passthrough?.latency === "0", `${source}: passthrough delay ${passthrough?.latency} ms, expected 0`)
    check(Number(pitch?.latency) > 5 && Number(pitch?.latency) < 60, `${source}: pitch shift delay ${pitch?.latency} ms`)
    check(Number(pitch?.rtf) < 0.5, `${source}: pitch shift real-time factor ${pitch?.rtf}`)
  }

  await page.click("#voice-lab-measure")
  await page.waitFor(`["measured", "failed"].includes(document.querySelector("#voice-lab-seam-result").dataset.state)`, "the seam measurement", 30_000)
  const seam = await page.eval(`document.querySelector("#voice-lab-seam-result").textContent`)
  console.log(`seam: ${seam}`)
  check(!seam.startsWith("Measurement failed"), seam)

  if (process.env.SCREENSHOT) {
    await page.send("Emulation.setDeviceMetricsOverride", {width: 1200, height: 1800, deviceScaleFactor: 1, mobile: false})
    const {data} = await page.send("Page.captureScreenshot", {format: "png", captureBeyondViewport: true})
    writeFileSync(process.env.SCREENSHOT, Buffer.from(data, "base64"))
  }
} finally {
  await browser.close()
}

for (const failure of failures) console.log(`✗ ${failure}`)
console.log(failures.length ? `${failures.length} failed` : "voice lab ok")
process.exit(failures.length ? 1 : 0)
