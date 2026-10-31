// Prepared native audition; UI fixtures never capture audio or write owner reviews.
import assert from 'node:assert/strict'
import {Browser, BASE_URL} from './cdp.mjs'
import {wavFixture} from './wav_fixture.mjs'
const browser = await Browser.launch()
try {
  const page = await browser.newPage('selective-resonance')
  await page.send('Page.addScriptToEvaluateOnNewDocument', {source: `(()=>{
    const fetch=window.fetch.bind(window), start=AudioBufferSourceNode.prototype.start;
    window.envelopeReviews=[];window.missingEnvelope=false;
    AudioBufferSourceNode.prototype.start=function(...args){window.lastEnvelopeBuffer=this.buffer;return start.apply(this,args)};
    const fixture=${wavFixture.toString()};
    window.fetch=(url,options)=>{
      if(url==='/dev/voice-lab/reviews'){window.envelopeReviews.push(JSON.parse(options.body));return Promise.resolve(new Response(JSON.stringify({saved_at:new Date().toISOString()}),{status:201}))}
      if(String(url).includes('/voice-lab/models/'))return Promise.resolve(new Response(window.missingEnvelope?'':fixture(),{status:window.missingEnvelope?404:200}));
      return fetch(url,options);
    };
  })()`})
  await page.open(`${BASE_URL}/dev/voice-lab`); await page.labView('listen')
  await page.waitFor(`document.getElementById('voice-lab-status')?.dataset.state==='rendered'`, 'lab ready', 30000)
  await page.labView('envelope')
  const choose = (id, value) => page.eval(`{const x=document.getElementById(${JSON.stringify(id)});x.value=${JSON.stringify(value)};x.dispatchEvent(new Event('change',{bubbles:true}))}`)
  const ready = () => page.waitFor(`document.getElementById('voice-lab-envelope-status').dataset.state==='ready'`, 'envelope ready', 10000)
  for (const source of ['high_voice.wav', 'low_voice.wav', 'mid_voice.wav', 'mencken_wasichu.wav', 'test_tone']) {
    await choose('voice-lab-envelope-source', source); await ready()
    const settings = await page.eval(`JSON.parse(document.getElementById('voice-lab-envelope').dataset.round).cases[${JSON.stringify(source)}].settings`)
    for (const name of ['bend_a', 'bend_b']) {
      assert.equal(settings[name].pitch, settings.current.pitch)
      assert.equal(settings[name].scale, settings.current.scale)
    }
    assert.equal(Math.abs(settings.current.pitch), 1)
    assert.equal(settings.bend_a.bend, .15)
    assert.equal(settings.bend_b.bend, -.15)
    for (const name of ['original', 'current', 'bend_a', 'bend_b']) {
      await page.click(`#voice-lab-envelope-play-${name}`)
      await page.waitFor(`document.getElementById('voice-lab-envelope-status').dataset.state==='playing'`, 'version playing', 10000)
      assert.equal(await page.eval('window.lastEnvelopeBuffer.duration'), .75)
      await page.click('#voice-lab-envelope-stop')
    }
    await page.click('#voice-lab-envelope-all')
    await page.waitFor(`document.getElementById('voice-lab-envelope-status').dataset.state==='playing'`, 'all four playing', 10000)
    assert.equal(await page.eval('window.lastEnvelopeBuffer.duration'), 3, 'four clips plus four quarter-second gaps')
    await page.click('#voice-lab-envelope-stop')
  }
  assert.equal(await page.eval(`document.querySelectorAll('#voice-lab-envelope [data-round-live]').length`), 0, 'no unsupported live handoff')
  await choose('voice-lab-envelope-source', 'mid_voice.wav'); await ready()
  await choose('voice-lab-review-envelope-comparison-preference', 'bend_a')
  await page.waitFor(`document.getElementById('voice-lab-review-envelope-status').dataset.state==='saved'`, 'saved preference', 10000)
  assert(await page.eval(`window.envelopeReviews.at(-1).context.mode==='selective_resonance_1'&&window.envelopeReviews.at(-1).ratings.comparison.preference==='bend_a'`))
  await choose('voice-lab-envelope-source', 'high_voice.wav'); await ready()
  assert.equal(await page.eval(`document.getElementById('voice-lab-review-envelope-comparison-preference').value`), '', 'reviews are source-specific')
  await choose('voice-lab-envelope-source', 'mid_voice.wav'); await ready()
  assert.equal(await page.eval(`document.getElementById('voice-lab-review-envelope-comparison-preference').value`), 'bend_a')
  await page.eval('window.missingEnvelope=true')
  await choose('voice-lab-envelope-source', 'high_voice.wav')
  await page.waitFor(`document.getElementById('voice-lab-envelope-status').dataset.state==='failed'`, 'missing WAV visible', 10000)
  assert(await page.eval(`document.getElementById('voice-lab-envelope-all').disabled`))
  await page.eval('window.missingEnvelope=false')
  await choose('voice-lab-envelope-source', 'mid_voice.wav'); await ready()
  await page.click('#voice-lab-envelope-all')
  await page.waitFor(`document.getElementById('voice-lab-envelope-status').dataset.state==='playing'`, 'playing before navigation', 10000)
  await page.labView('listen')
  assert.equal(await page.eval(`document.getElementById('voice-lab-envelope').dataset.playing`), '')
  assert.equal(await page.eval('window.__randosStreams.length'), 0, 'audition never requests a microphone')
  console.log('selective resonance: every source/version, fixed pitch/scale, sequential pauses, isolated autosave, missing files and navigation cleanup passed')
} finally { await browser.close() }
