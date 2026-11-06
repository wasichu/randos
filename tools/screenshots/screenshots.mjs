// The README's screenshots (docs/assets/), from a real call on a throwaway
// server: `just screenshots`, which runs this under with_test_server.sh with
// normal ten-minute segments. Nobody real is involved: the browsers have fake
// mics, and the TUI plays a test tone into a null speaker (RANDOS_FAKE_AUDIO).
//
//   1. The website, idle, inviting someone, and in a call, in light and
//      dark: two headless Chrome pages call each other.
//   2. The TUI, idle and in a call: a Chrome page waits as the peer, and VHS
//      (tui.tape) drives the TUI against it.
//
// Everything stops when this script does: Chrome is on the DevTools pipe,
// VHS is a child that exits with its tape, and the server has its watchdog.

import {spawn} from "node:child_process"
import {writeFileSync,readFileSync} from "node:fs"
import {Browser, sleep} from "../../test/e2e/cdp.mjs"

const OUT = "docs/assets"
const WIDTH = 1200
const HEIGHT = 820

async function setTheme(page, theme) {
  await page.eval(`(() => {
    localStorage.setItem("randos:theme", ${JSON.stringify(theme)});
    document.documentElement.setAttribute("data-theme", ${JSON.stringify(theme)});
  })()`)
  await sleep(400) // transitions settle
}

async function shoot(page, name) {
  const {data} = await page.send("Page.captureScreenshot", {format: "png"})
  writeFileSync(`${OUT}/${name}.png`, Buffer.from(data, "base64"))
  console.log(`  ${OUT}/${name}.png`)
}

async function bothThemes(page, name) {
  for (const theme of ["light", "dark"]) {
    await setTheme(page, theme)
    await shoot(page, `${name}-${theme}`)
  }
}

async function sized(page) {
  await page.send("Emulation.setDeviceMetricsOverride", {
    width: WIDTH, height: HEIGHT, deviceScaleFactor: 2, mobile: false,
  })
  return page
}

function run(command, args) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, {stdio: "inherit"})
    child.on("exit", code => (code === 0 ? resolve() : reject(new Error(`${command} exited ${code}`))))
  })
}

const browser = await Browser.launch()
try {
  console.log("website:")
  const a = await sized(await browser.newPage("A"))
  const b = await sized(await browser.newPage("B", {getUserMediaDelayMs: 15_000}))
  await Promise.all([a.open(), b.open()])
  await bothThemes(a, "web-home")

  // Witness multiple speaking choices, including narrow-screen wrapping.
  await a.chooseLanguages(["en", "es"], ["en"])
  await a.click("#speaking-summary")
  for (const [theme, width] of [["light", WIDTH], ["dark", WIDTH], ["light", 390]]) {
    await a.send("Emulation.setDeviceMetricsOverride", {
      width, height: HEIGHT, deviceScaleFactor: 2, mobile: width < WIDTH,
    })
    await setTheme(a, theme)
    if (!await a.eval("document.documentElement.scrollWidth <= window.innerWidth")) {
      throw Error(`Speaking picker overflows at ${width}px`)
    }
    const {data} = await a.send("Page.captureScreenshot", {format: "png"})
    writeFileSync(`tmp/speaking-picker-${theme}-${width}.png`, Buffer.from(data, "base64"))
  }
  await sized(a)
  await a.click("#speaking-summary")

  // Inviting: the link to share (its host is PHX_HOST's, randos.slowinput.org).
  await a.invite("en", ["es"])
  await sleep(400)
  await bothThemes(a, "web-invite")
  await a.click("#cancel-invitation-button")
  await a.waitFor(`!!document.querySelector("#conversation-form")`, "the form again")

  await a.findRando("en", "es")
  await b.findRando("es", "en")
  await a.waitFor('!!document.querySelector("#connecting-panel")', 'the connecting layout')
  for (const width of [WIDTH, 390, 320]) {
    await a.send("Emulation.setDeviceMetricsOverride", {
      width, height: HEIGHT, deviceScaleFactor: 2, mobile: width < WIDTH,
    })
    for (const theme of ["light", "dark"]) {
      await setTheme(a, theme)
      const fit = await a.eval(`(() => {
        const mute = document.querySelector('#mute-button').getBoundingClientRect();
        const cancel = document.querySelector('#cancel-connection-button').getBoundingClientRect();
        return document.documentElement.scrollWidth <= innerWidth &&
          mute.height === 48 && cancel.height === 48 &&
          Math.abs(mute.width - cancel.width) < 1 && mute.top === cancel.top;
      })()`)
      if (!fit) throw Error(`Connecting controls do not align at ${width}px (${theme})`)
      await shoot(a, `web-connecting-${theme}-${width}`)
    }
  }
  await sized(a)
  await Promise.all([a, b].map(page => page.waitFor(
    'document.querySelector("#webrtc-audio")?.dataset.webrtcState === "connected"',
    "audio after the deliberate microphone delay", 25_000,
  )))
  await sleep(2_500) // the waveforms fill in
  await bothThemes(a, "web-call")
  for (const width of [390, 320]) {
    await a.send("Emulation.setDeviceMetricsOverride", {
      width, height: HEIGHT, deviceScaleFactor: 2, mobile: true,
    })
    const fit = await a.eval(`(() => {
      const box = selector => document.querySelector(selector).getBoundingClientRect();
      const local = box('#local-waveform'), remote = box('#remote-waveform');
      const controls = ['#mute-button', '#next-rando-button', '#end-call-button'].map(box);
      return document.documentElement.scrollWidth <= innerWidth &&
        local.top === remote.top &&
        controls.every(r => r.width >= 44 && r.height >= 44 && r.bottom <= innerHeight) &&
        controls.every(r => r.top === controls[0].top);
    })()`)
    if (!fit) throw Error(`Mobile call controls or voices do not fit at ${width}px`)
    await bothThemes(a, `web-call-${width}`)
  }
  await sized(a)
  // Leave the site, so neither page can be matched with the TUI later.
  await a.hangUp()
  await Promise.all([a, b].map(page => page.send("Page.navigate", {url: "about:blank"})))

  console.log("terminal:")
  // The TUI's defaults: speaks English, wants to hear Spanish.
  const peer = await browser.newPage("peer")
  await peer.open()
  await peer.findRando("es", "en")
  await peer.waitFor(`!!document.querySelector("#cancel-search-button")`, "the peer waiting")
  await run("vhs", ["tools/screenshots/tui.tape"])
  // The headless native buffer cannot catch physical cursor-width residue.
  // Compare actual terminal-emulator pixels after dismissing the multilingual menu.
  const before=readFileSync('tmp/tui-language-pristine.png').toString('base64')
  const after=readFileSync('tmp/tui-language-dismissed.png').toString('base64')
  const same=await a.eval(`(async()=>{
    const pixels=async base64=>{const img=new Image();img.src='data:image/png;base64,'+base64;await img.decode();const canvas=document.createElement('canvas');canvas.width=img.width;canvas.height=img.height;const ctx=canvas.getContext('2d');ctx.drawImage(img,0,0);return {width:img.width,height:img.height,data:ctx.getImageData(0,0,img.width,img.height).data}};
    const left=await pixels(${JSON.stringify(before)}),right=await pixels(${JSON.stringify(after)});
    return left.width===right.width&&left.height===right.height&&left.data.every((value,index)=>value===right.data[index]);
  })()`)
  if(!same)throw Error('Dismissing the TUI language picker changed the physical terminal frame')
  console.log('  multilingual picker dismissal restores the exact terminal pixels')
} finally {
  await browser.close()
}
