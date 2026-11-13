// Queued search: translated headings and language alternatives must fit at
// phone/desktop widths, without opening the microphone or contacting a peer.
import assert from "node:assert/strict"
import {writeFileSync} from "node:fs"
import {Browser, BASE_URL} from "./cdp.mjs"

const browser = await Browser.launch()
const results = []
try {
  const page = await browser.newPage("translated-search")
  await page.open()
  const locales = await page.eval(`[...document.querySelectorAll('#locale-options button')].map(b=>b.id.replace('locale-option-',''))`)
  assert.equal(locales.length, 20)
  for (const locale of locales) {
    await page.send("Network.setCookie", {name: "randos_locale", value: locale, url: BASE_URL})
    await page.open()
    assert.equal(await page.eval("document.documentElement.lang"), locale)
    for (const choices of [["en"], ["en", "de", "ja"], ["en", "de", "ja", "fr", "es"]]) {
      await page.findRando(choices, choices)
      await page.waitFor(`!!document.querySelector('#looking-speaking')`, "search choices")
      assert.equal(await page.eval("window.__randosStreams.length"), 0, "queued search must not capture audio")
      for (const width of [320, 390, 1200]) {
        await page.send("Emulation.setDeviceMetricsOverride", {width, height: 820, deviceScaleFactor: 1, mobile: width < 640})
        for (const theme of ["light", "dark"]) {
          await page.eval(`document.documentElement.dataset.theme=${JSON.stringify(theme)}`)
          const faults = await page.eval(`(() => {
            const faults=[];
            if(document.documentElement.scrollWidth>innerWidth) faults.push('page overflow');
            const nodes=[...document.querySelectorAll('#looking-panel h2, #looking-panel dt, #looking-panel dd, #cancel-search-button')];
            if(nodes.length!==6) faults.push('missing search heading, directions or cancel button');
            for(const node of nodes) {
              const box=node.getBoundingClientRect();
              if(box.left<0 || box.right>innerWidth) faults.push('element outside viewport');
              const walker=document.createTreeWalker(node,NodeFilter.SHOW_TEXT);
              while(walker.nextNode()) {
                if(!walker.currentNode.textContent.trim())continue;
                const range=document.createRange();range.selectNodeContents(walker.currentNode);
                for(const r of range.getClientRects()) {
                  if(r.left<box.left-1 || r.right>box.right+1 || r.top<box.top-1 || r.bottom>box.bottom+1)
                    faults.push('text outside '+node.tagName);
                }
              }
            }
            return faults;
          })()`)
          results.push({locale, choices: choices.length, width, theme, faults})
        }
      }
      await page.stopLooking()
      await page.waitFor(`!!document.querySelector('#conversation-form')`, "search canceled")
    }
  }
  writeFileSync("tmp/search-layout.json", JSON.stringify(results, null, 2) + "\n")
  const failures = results.filter(result => result.faults.length)
  assert.equal(failures.length, 0, `translated search overflow: ${JSON.stringify(failures.slice(0, 8))}`)
  console.log(`${results.length} translated search layouts passed, including alternatives, counts and RTL`)
} finally {
  await browser.close()
}
