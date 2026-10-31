import {wavFixture} from './wav_fixture.mjs'
import assert from 'node:assert/strict'
import {Browser, BASE_URL} from './cdp.mjs'
const browser=await Browser.launch()
try{
 const page=await browser.newPage('engine-comparison')
 await page.send('Page.addScriptToEvaluateOnNewDocument',{source:`(()=>{
  const fetch=window.fetch.bind(window),start=AudioBufferSourceNode.prototype.start;
  AudioBufferSourceNode.prototype.start=function(...args){window.engineBuffer=this.buffer;return start.apply(this,args)};
  window.engineReviews=[];
  const fixture=${wavFixture.toString()};
  window.fetch=(url,options)=>{if(url==='/dev/voice-lab/reviews'){window.engineReviews.push(JSON.parse(options.body));return Promise.resolve(new Response(JSON.stringify({saved_at:new Date().toISOString()}),{status:201}))}if(String(url).includes('/voice-lab/models/'))return Promise.resolve(new Response(fixture()));return fetch(url,options)};
 })()`})
 await page.open(`${BASE_URL}/dev/voice-lab`); await page.labView('listen')
 await page.waitFor(`document.getElementById('voice-lab-status')?.dataset.state==='rendered'`,'lab readiness',30000)
 await page.labView('engines')
 const choose=(id,value)=>page.eval(`{const x=document.getElementById(${JSON.stringify(id)});x.value=${JSON.stringify(value)};x.dispatchEvent(new Event('change',{bubbles:true}))}`)
 const ready=()=>page.waitFor(`document.getElementById('voice-lab-engines-status').dataset.state==='ready'`,'three-way readiness',10000)
 for(const source of ['high_voice.wav','low_voice.wav','mid_voice.wav','mencken_wasichu.wav','test_tone']){
  await choose('voice-lab-engines-source',source);await ready()
  assert.equal(await page.eval(`document.querySelectorAll('#voice-lab-engines [data-round-row]').length`),3)
  for(const engine of ['original','spectral','world']){
   await page.click(`#voice-lab-engines-play-${engine}`)
   await page.waitFor(`document.getElementById('voice-lab-engines-status').dataset.state==='playing'`,'engine playback',10000)
   assert.equal(await page.eval('window.engineBuffer.duration'),.75)
   if(source==='mid_voice.wav')assert(await page.eval(`document.querySelector('#voice-lab-engines [data-round-note]').textContent.includes('Unresolved')&&!document.querySelector('#voice-lab-engines [data-round-note]').hidden`),'mid voice stays explicitly unresolved during playback')
   await page.click('#voice-lab-engines-stop')
  }
  await page.click('#voice-lab-engines-all')
  await page.waitFor(`document.getElementById('voice-lab-engines-status').dataset.state==='playing'`,'all three playback',10000)
  assert.equal(await page.eval('window.engineBuffer.duration'),2.25,'three clips and three pauses')
  await page.click('#voice-lab-engines-stop')
 }
 await choose('voice-lab-engines-source','mid_voice.wav');await ready()
 await choose('voice-lab-review-engines-comparison-preference','none')
 await page.waitFor(`document.getElementById('voice-lab-review-engines-status').dataset.state==='saved'`,'whole-engine-round auto-save',10000)
 assert(await page.eval(`window.engineReviews.at(-1).context.mode==='engine_comparison_1'&&window.engineReviews.at(-1).context.processor==='signalsmith_world'&&window.engineReviews.at(-1).ratings.comparison.preference==='none'`))
 assert.equal(await page.eval(`document.querySelector('#voice-lab-review-engines-comparison-preference option[value="current"]')`),null)
 await choose('voice-lab-engines-source','mencken_wasichu.wav');await ready()
 await page.click('#voice-lab-engines-live-world')
 assert(await page.eval(`document.getElementById('voice-lab-live-mode').value==='dsp'&&document.getElementById('voice-lab-live-engine').value==='world'&&document.getElementById('voice-lab-live-profile').value==='higher_resonance'`))
 assert.equal(await page.eval('window.__randosStreams.length'),0,'settings handoff never starts microphone')
 console.log('engine comparison: all sources/engines, whole-round reviews, unresolved mid voice, matched pauses and explicit live handoff passed')
}finally{await browser.close()}
