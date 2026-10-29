// Verify the generated listening artifact on the running dev server, silently.
import assert from "node:assert/strict"
import {writeFileSync} from "node:fs"
import {Browser, BASE_URL} from "../../test/e2e/cdp.mjs"

const browser = await Browser.launch()
let page
try {
  page = await browser.newPage("browser-report")
  await page.send("Page.addScriptToEvaluateOnNewDocument", {source: `(() => {
    const start=AudioBufferSourceNode.prototype.start;
    AudioBufferSourceNode.prototype.start=function(...args) { window.reportNode=this; return start.apply(this,args); };
  })();`})
  await page.send("Page.navigate", {url: `${BASE_URL}/dev/voice-lab/browser-probe`})
  await page.waitFor(`document.querySelectorAll('audio').length===3 && [...document.querySelectorAll('audio')].every(a=>a.duration===6)`, "all complete comparison clips", 10_000)
  await page.click("#loop")
  await page.click("#compare")
  await page.waitFor(`document.getElementById('playback-status').textContent.startsWith('Playing')`, "comparison playback", 10_000)
  assert(await page.eval(`window.reportNode.loop && Math.abs(window.reportNode.buffer.duration-18.75)<.001`), "full clips plus three pauses")
  await page.eval(`document.querySelector('audio').play()`)
  await page.waitFor(`window.reportNode.context.state==='closed' && [...document.querySelectorAll('audio')].filter(a=>!a.paused).length===1`, "individual playback cancels group", 10_000)
  await page.eval(`document.querySelectorAll('audio')[1].play()`)
  assert(await page.eval(`[...document.querySelectorAll('audio')].filter(a=>!a.paused).length===1`), "exclusive native players")
  await page.click("#compare")
  await page.waitFor(`document.getElementById('playback-status').textContent.startsWith('Playing')`, "comparison retry", 10_000)
  await page.click("#compare")
  await page.waitFor(`window.reportNode.context.state==='closed'`, "Stop closes audio context", 10_000)
  for (const [suffix,width,height] of [["",1440,1200],["-mobile",390,844]]) {
    await page.send("Emulation.setDeviceMetricsOverride", {width,height,deviceScaleFactor:1,mobile:width===390})
    assert(await page.eval(`document.documentElement.scrollWidth <= innerWidth`), "report fits viewport")
    const {data} = await page.send("Page.captureScreenshot", {format:"png",captureBeyondViewport:true})
    writeFileSync(`tmp/voice-browser-report${suffix}.png`, Buffer.from(data,"base64"))
  }
  console.log("Browser listening report: full clips, exclusive playback, Loop/Stop and desktop/mobile layout passed")
} catch (error) {
  console.log(page?.logs)
  console.log(await page?.eval(`document.getElementById('playback-status')?.textContent`))
  throw error
} finally {
  await browser.close()
}
