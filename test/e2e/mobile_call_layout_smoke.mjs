// Real muted calls: translated labels must stay inside their
// controls, including long Mute/Unmute words and RTL, at phone/desktop sizes.
import assert from "node:assert/strict"
import {writeFileSync} from "node:fs"
import {Browser, BASE_URL} from "./cdp.mjs"

const browser = await Browser.launch()
const results = []
try {
  const caller = await browser.newPage("translated-caller")
  const peer = await browser.newPage("translated-peer")
  await caller.open()
  const locales = await caller.eval(`[...document.querySelectorAll('#locale-options button')].map(b=>b.id.replace('locale-option-',''))`)
  assert.equal(locales.length, 20)
  for (const locale of locales) {
    await caller.send("Network.setCookie", {name: "randos_locale", value: locale, url: BASE_URL})
    await Promise.all([caller.open(), peer.open()])
    assert.equal(await caller.eval("document.documentElement.lang"), locale)
    await caller.findRando("en", "es")
    await peer.findRando("es", "en")
    await Promise.all([caller.inCall(), peer.inCall()])
    for (const muted of [false, true]) {
      if (muted) {
        await caller.click("#mute-button")
        await caller.waitFor(`document.querySelector('#mute-button').getAttribute('aria-pressed')==='true'`, "muted label")
      }
      for (const width of [320, 390, 1200]) {
        await caller.send("Emulation.setDeviceMetricsOverride", {width, height: 820, deviceScaleFactor: 1, mobile: width < 640})
        for (const theme of ["light", "dark"]) {
          await caller.eval(`document.documentElement.dataset.theme=${JSON.stringify(theme)}`)
          const layout = await caller.eval(`(() => {
            const ids=['mute-button','next-rando-button','end-call-button'];
            const controls=ids.flatMap(id=>{
              const button=document.getElementById(id); if(!button)return [];
              const box=button.getBoundingClientRect(), text=[];
              const walker=document.createTreeWalker(button,NodeFilter.SHOW_TEXT);
              while(walker.nextNode()) {
                if(!walker.currentNode.textContent.trim())continue;
                const range=document.createRange();range.selectNodeContents(walker.currentNode);
                for(const rect of range.getClientRects())text.push({left:rect.left,right:rect.right,top:rect.top,bottom:rect.bottom});
              }
              return [{id,box:box.toJSON(),text}];
            });
            return {overflow:document.documentElement.scrollWidth>innerWidth, controls,
              voicesAligned:document.querySelector('#local-waveform').getBoundingClientRect().top===document.querySelector('#remote-waveform').getBoundingClientRect().top};
          })()`)
          assert.deepEqual(layout.controls.map(control => control.id),
            ["mute-button", "next-rando-button", "end-call-button"], "all call controls must be present")
          const faults = []
          if (layout.overflow) faults.push("page overflow")
          if (!layout.voicesAligned) faults.push("voices not aligned")
          for (const {id, box, text} of layout.controls) {
            if (box.width < 44 || box.height < 44 || box.left < 0 || box.right > width || box.bottom > 820) faults.push(`${id}: control outside viewport or too small`)
            if (text.some(r => r.left < box.left - 1 || r.right > box.right + 1 || r.top < box.top - 1 || r.bottom > box.bottom + 1)) faults.push(`${id}: text outside button`)
          }
          results.push({locale, width, theme, muted, faults})
        }
      }
    }
    await caller.hangUp()
    await Promise.all([caller.callEnds(), peer.callEnds()])
    await peer.waitFor(`!!document.querySelector('#cancel-search-button')`, "peer requeued")
    await peer.stopLooking()
  }
  writeFileSync("tmp/mobile-call-layout.json", JSON.stringify(results, null, 2) + "\n")
  const failures = results.filter(result => result.faults.length)
  assert.equal(failures.length, 0, `translated call control overflow: ${JSON.stringify(failures.slice(0, 8))}`)
  console.log(`${results.length} translated active-call layouts passed, including Mute/Unmute and RTL`)
} finally {
  await browser.close()
}
