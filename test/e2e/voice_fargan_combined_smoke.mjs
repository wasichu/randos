// Final native-prepared comparison, with fixtures and intercepted owner reviews.
import assert from 'node:assert/strict'
import {Browser, BASE_URL} from './cdp.mjs'
import {wavFixture} from './wav_fixture.mjs'
import {MASKING_STYLES} from '../../assets/js/randos/voice/masking_choices.js'
const browser = await Browser.launch()
try {
  const page = await browser.newPage('final-fargan')
  await page.send('Page.addScriptToEvaluateOnNewDocument', {source: `(()=>{
    const fetch=window.fetch.bind(window), start=AudioBufferSourceNode.prototype.start;
    window.finalReviews=[];
    AudioBufferSourceNode.prototype.start=function(...args){window.finalBuffer=this.buffer;return start.apply(this,args)};
    const fixture=${wavFixture.toString()};
    window.fetch=(url,options)=>{
      if(url==='/dev/voice-lab/reviews'){window.finalReviews.push(JSON.parse(options.body));return Promise.resolve(new Response(JSON.stringify({saved_at:new Date().toISOString()}),{status:201}))}
      if(String(url).includes('/voice-lab/models/'))return Promise.resolve(new Response(fixture()));
      return fetch(url,options);
    };
  })()`})
  await page.open(`${BASE_URL}/dev/voice-lab`)
  await page.waitFor(`document.getElementById('voice-lab-status')?.dataset.state==='rendered'`, 'lab ready', 30000)
  assert.equal(await page.eval(`document.getElementById('voice-lab-view').value`), 'bandwidth')
  await page.labView('fargan_combined')
  const choose = (id, value) => page.eval(`{const x=document.getElementById(${JSON.stringify(id)});x.value=${JSON.stringify(value)};x.dispatchEvent(new Event('change',{bubbles:true}))}`)
  const ready = () => page.waitFor(`document.getElementById('voice-lab-fargan_combined-status').dataset.state==='ready'`, 'combined ready', 10000)
  const sources = ['high_voice.wav', 'mid_voice.wav', 'low_voice.wav', 'mencken_wasichu.wav', 'test_tone']
  for (const source of sources) {
    await choose('voice-lab-fargan_combined-source', source); await ready()
    const settings = await page.eval(`JSON.parse(document.getElementById('voice-lab-fargan_combined').dataset.round).cases[${JSON.stringify(source)}].settings.combined.settings`)
    const reference = MASKING_STYLES[['low_voice.wav','mencken_wasichu.wav'].includes(source) ? 'higher_resonance_pitch' : 'lower_resonance_pitch']
    assert.deepEqual(settings, reference, 'nominal pitch and low-band scale match shipping reference')
    for (const version of ['original', 'control', 'combined', 'reference']) {
      await page.click(`#voice-lab-fargan_combined-play-${version}`)
      await page.waitFor(`document.getElementById('voice-lab-fargan_combined-status').dataset.state==='playing'`, 'combined version playing', 10000)
      assert.equal(await page.eval('window.finalBuffer.duration'), .75)
      await page.click('#voice-lab-fargan_combined-stop')
    }
  }
  await page.click('#voice-lab-fargan_combined-all')
  await page.waitFor(`document.getElementById('voice-lab-fargan_combined-status').dataset.state==='playing'`, 'four-way sequence', 10000)
  assert.equal(await page.eval('window.finalBuffer.duration'), 3)
  await page.labView('basics')
  assert.equal(await page.eval(`document.getElementById('voice-lab-fargan_combined').dataset.playing`), '')
  await page.labView('fargan_combined')
  await choose('voice-lab-fargan_combined-source', 'mid_voice.wav'); await ready()
  await choose('voice-lab-review-fargan_combined-comparison-preference', 'combined')
  await page.waitFor(`document.getElementById('voice-lab-review-fargan_combined-status').dataset.state==='saved'`, 'final vote saved', 10000)
  assert(await page.eval(`window.finalReviews.at(-1).context.mode==='fargan_combined_1'&&window.finalReviews.at(-1).ratings.comparison.preference==='combined'`))
  await page.labView('fargan_mask')
  assert.equal(await page.eval(`document.getElementById('voice-lab-review-fargan_mask-comparison-preference').value`), '', 'old review remains separate')
  await page.labView('listen')
  for (const source of sources) {
    await choose('voice-lab-source', source); await choose('voice-lab-processor', 'fargan_combined')
    await page.waitFor(`document.getElementById('voice-lab-status').dataset.state==='rendered'`, 'combined menu ready', 10000)
    assert(await page.eval(`document.querySelector('#voice-lab-result-original [data-result-title]').textContent.includes('16 kHz')`))
  }
  assert.equal(await page.eval('window.__randosStreams.length'), 0)
  assert.equal(await page.eval(`document.querySelectorAll('#voice-lab-fargan_combined [data-round-live]').length`), 0)
  console.log('Final FARGAN: reference-matched nominal settings, every source/version, pauses, independent review, menu and playback cleanup passed')
} finally { await browser.close() }
