// Offline quality-gate UI, mocked WAVs and review writes; never runs a model.
import assert from 'node:assert/strict'
import {Browser, BASE_URL} from './cdp.mjs'
import {wavFixture} from './wav_fixture.mjs'
const browser = await Browser.launch()
try {
  const page = await browser.newPage('fargan-quality')
  await page.send('Page.addScriptToEvaluateOnNewDocument', {source: `(()=>{
    const fetch=window.fetch.bind(window), start=AudioBufferSourceNode.prototype.start;
    window.farganReviews=[];
    AudioBufferSourceNode.prototype.start=function(...args){window.farganBuffer=this.buffer;return start.apply(this,args)};
    const fixture=${wavFixture.toString()};
    window.fetch=(url,options)=>{
      if(url==='/dev/voice-lab/reviews'){window.farganReviews.push(JSON.parse(options.body));return Promise.resolve(new Response(JSON.stringify({saved_at:new Date().toISOString()}),{status:201}))}
      if(String(url).includes('/voice-lab/models/'))return Promise.resolve(new Response(fixture()));
      return fetch(url,options);
    };
  })()`})
  await page.open(`${BASE_URL}/dev/voice-lab`)
  await page.waitFor(`document.getElementById('voice-lab-status')?.dataset.state==='rendered'`, 'lab ready', 30000)
  assert.equal(await page.eval(`document.getElementById('voice-lab-view').value`), 'bandwidth', 'current experiment opens first')
  assert.equal(await page.eval(`document.querySelectorAll('#voice-lab [role=tab]').length`), 0, 'no wall of tabs')
  assert.equal(await page.eval(`document.querySelectorAll('#voice-lab-view optgroup').length`), 4)
  await page.labView('fargan')
  const choose = (id, value) => page.eval(`{const x=document.getElementById(${JSON.stringify(id)});x.value=${JSON.stringify(value)};x.dispatchEvent(new Event('change',{bubbles:true}))}`)
  const ready = () => page.waitFor(`document.getElementById('voice-lab-fargan-status').dataset.state==='ready'`, 'FARGAN ready', 10000)
  await ready()
  assert(await page.eval(`document.getElementById('voice-lab-fargan-status').textContent.includes('16 kHz')`))
  for (const source of ['high_voice.wav', 'mid_voice.wav', 'low_voice.wav', 'mencken_wasichu.wav', 'test_tone']) {
    await choose('voice-lab-fargan-source', source); await ready()
    for (const variant of ['original', 'bandlimited', 'fargan', 'reference']) {
      await page.click(`#voice-lab-fargan-play-${variant}`)
      await page.waitFor(`document.getElementById('voice-lab-fargan-status').dataset.state==='playing'`, 'quality version playing', 10000)
      assert.equal(await page.eval('window.farganBuffer.duration'), .75)
      await page.click('#voice-lab-fargan-stop')
    }
  }
  await page.click('#voice-lab-fargan-all')
  await page.waitFor(`document.getElementById('voice-lab-fargan-status').dataset.state==='playing'`, 'quality sequence playing', 10000)
  assert.equal(await page.eval('window.farganBuffer.duration'), 3, 'four versions and four quarter-second pauses')
  await page.labView('basics')
  assert.equal(await page.eval(`document.getElementById('voice-lab-fargan').dataset.playing`), '', 'navigation stops playback')
  await page.labView('fargan')
  await choose('voice-lab-fargan-source', 'mid_voice.wav'); await ready()
  await choose('voice-lab-review-fargan-comparison-preference', 'acceptable')
  await page.waitFor(`document.getElementById('voice-lab-review-fargan-status').dataset.state==='saved'`, 'quality assessment saved', 10000)
  assert(await page.eval(`window.farganReviews.at(-1).context.mode==='fargan_quality_1'&&window.farganReviews.at(-1).ratings.comparison.preference==='acceptable'`))
  assert.equal(await page.eval(`document.querySelectorAll('#voice-lab-fargan [data-round-live]').length`), 0)
  await page.labView('listen')
  await choose('voice-lab-source', 'mid_voice.wav')
  await choose('voice-lab-processor', 'fargan_control')
  await page.waitFor(`document.getElementById('voice-lab-status').dataset.state==='rendered'`, 'FARGAN menu playback ready', 10000)
  assert(await page.eval(`document.querySelector('#voice-lab-result-original [data-description]').textContent.includes('16 kHz')`))
  assert.equal(await page.eval('window.__randosStreams.length'), 0, 'view changes never open microphone')
  console.log('FARGAN: current grouped view, every source/version, matched-band control, pauses, autosave, menu availability and navigation cleanup passed')
} finally { await browser.close() }
