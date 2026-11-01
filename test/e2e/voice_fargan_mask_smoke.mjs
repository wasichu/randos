// Native-prepared masking auditions: explicit UI fixtures, no inference or mic.
import assert from 'node:assert/strict'
import {Browser, BASE_URL} from './cdp.mjs'
import {wavFixture} from './wav_fixture.mjs'
const browser = await Browser.launch()
try {
  const page = await browser.newPage('fargan-feature-edits')
  await page.send('Page.addScriptToEvaluateOnNewDocument', {source: `(()=>{
    const fetch=window.fetch.bind(window), start=AudioBufferSourceNode.prototype.start;
    window.maskReviews=[];window.maskMissing=false;
    AudioBufferSourceNode.prototype.start=function(...args){window.maskBuffer=this.buffer;return start.apply(this,args)};
    const fixture=${wavFixture.toString()};
    window.fetch=(url,options)=>{
      if(url==='/dev/voice-lab/reviews'){window.maskReviews.push(JSON.parse(options.body));return Promise.resolve(new Response(JSON.stringify({saved_at:new Date().toISOString()}),{status:201}))}
      if(String(url).includes('/voice-lab/models/'))return Promise.resolve(new Response(window.maskMissing?'':fixture(),{status:window.maskMissing?404:200}));
      return fetch(url,options);
    };
  })()`})
  await page.open(`${BASE_URL}/dev/voice-lab`)
  await page.waitFor(`document.getElementById('voice-lab-status')?.dataset.state==='rendered'`, 'lab ready', 30000)
  assert.equal(await page.eval(`document.getElementById('voice-lab-view').value`), 'bandwidth')
  await page.labView('fargan_mask')
  await page.labView('fargan_mask')
  const choose = (id, value) => page.eval(`{const x=document.getElementById(${JSON.stringify(id)});x.value=${JSON.stringify(value)};x.dispatchEvent(new Event('change',{bubbles:true}))}`)
  const ready = () => page.waitFor(`document.getElementById('voice-lab-fargan_mask-status').dataset.state==='ready'`, 'masking comparison ready', 10000)
  const sources = ['high_voice.wav', 'mid_voice.wav', 'low_voice.wav', 'mencken_wasichu.wav', 'test_tone']
  for (const source of sources) {
    await choose('voice-lab-fargan_mask-source', source); await ready()
    const settings = await page.eval(`JSON.parse(document.getElementById('voice-lab-fargan_mask').dataset.round).cases[${JSON.stringify(source)}].settings`)
    assert.equal(settings.control.settings.pitch, 0)
    assert.equal(settings.control.settings.scale, 1)
    assert.equal(Math.abs(settings.pitch.settings.pitch), 1)
    assert.equal(settings.pitch.settings.scale, 1)
    assert.equal(settings.envelope.settings.pitch, 0)
    assert([.9, 1.1].includes(settings.envelope.settings.scale))
    for (const version of ['original', 'control', 'pitch', 'envelope', 'reference']) {
      await page.click(`#voice-lab-fargan_mask-play-${version}`)
      await page.waitFor(`document.getElementById('voice-lab-fargan_mask-status').dataset.state==='playing'`, 'masking version playing', 10000)
      assert.equal(await page.eval('window.maskBuffer.duration'), .75)
      await page.click('#voice-lab-fargan_mask-stop')
    }
  }
  await page.click('#voice-lab-fargan_mask-all')
  await page.waitFor(`document.getElementById('voice-lab-fargan_mask-status').dataset.state==='playing'`, 'five versions in order', 10000)
  assert.equal(await page.eval('window.maskBuffer.duration'), 3.75)
  await page.labView('basics')
  assert.equal(await page.eval(`document.getElementById('voice-lab-fargan_mask').dataset.playing`), '')
  await page.labView('fargan_mask')
  await choose('voice-lab-fargan_mask-source', 'mid_voice.wav'); await ready()
  await choose('voice-lab-review-fargan_mask-comparison-preference', 'reference')
  await page.waitFor(`document.getElementById('voice-lab-review-fargan_mask-status').dataset.state==='saved'`, 'masking preference saved', 10000)
  assert(await page.eval(`window.maskReviews.at(-1).context.mode==='fargan_masking_1'&&window.maskReviews.at(-1).ratings.comparison.preference==='reference'`))
  await page.labView('fargan')
  await choose('voice-lab-fargan-source', 'mid_voice.wav')
  await page.waitFor(`document.getElementById('voice-lab-fargan-status').dataset.state==='ready'`, 'historical quality control ready', 10000)
  assert.equal(await page.eval(`document.getElementById('voice-lab-review-fargan-comparison-preference').value`), '', 'quality review is separate')
  await page.labView('fargan_mask')
  assert.equal(await page.eval(`document.getElementById('voice-lab-review-fargan_mask-comparison-preference').value`), 'reference')
  await page.eval('window.maskMissing=true')
  await choose('voice-lab-fargan_mask-source', 'high_voice.wav')
  await page.waitFor(`document.getElementById('voice-lab-fargan_mask-status').dataset.state==='failed'`, 'missing clip visible', 10000)
  assert(await page.eval(`document.getElementById('voice-lab-fargan_mask-all').disabled`))
  await page.eval('window.maskMissing=false')
  await page.labView('listen')
  for (const processor of ['fargan_mask_control', 'fargan_mask_pitch', 'fargan_mask_envelope']) {
    for (const source of sources) {
      await choose('voice-lab-source', source); await choose('voice-lab-processor', processor)
      await page.waitFor(`document.getElementById('voice-lab-status').dataset.state==='rendered'`, 'prepared menu ready', 10000)
      assert(await page.eval(`document.querySelector('#voice-lab-result-original [data-result-title]').textContent.includes('16 kHz')`))
    }
  }
  assert.equal(await page.eval(`document.querySelectorAll('#voice-lab-fargan_mask [data-round-live]').length`), 0)
  assert.equal(await page.eval('window.__randosStreams.length'), 0)
  console.log('FARGAN masking: all sources/versions, isolated settings, five-way pauses, historical review separation, missing assets and menu availability passed')
} finally { await browser.close() }
