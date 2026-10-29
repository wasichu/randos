import {wavFixture} from './wav_fixture.mjs'
// Tiny local WAV fixtures and intercepted review writes; no microphone access.
import assert from 'node:assert/strict'
import {Browser,BASE_URL} from './cdp.mjs'
const browser=await Browser.launch()
try{
 const page=await browser.newPage('gentler-pitch')
 await page.send('Page.addScriptToEvaluateOnNewDocument',{source:`(()=>{
  const fetch=window.fetch.bind(window),start=AudioBufferSourceNode.prototype.start;window.gentleReviews=[];
  AudioBufferSourceNode.prototype.start=function(...args){window.gentleBuffer=this.buffer;return start.apply(this,args)};
  const fixture=${wavFixture.toString()};
  window.fetch=(url,options)=>{if(url==='/dev/voice-lab/reviews'){window.gentleReviews.push(JSON.parse(options.body));return Promise.resolve(new Response(JSON.stringify({saved_at:new Date().toISOString()}),{status:201}))}if(String(url).includes('/voice-lab/models/'))return Promise.resolve(new Response(fixture()));return fetch(url,options)};
 })()`})
 await page.open(`${BASE_URL}/dev/voice-lab`)
 await page.waitFor(`document.getElementById('voice-lab-status')?.dataset.state==='rendered'`,'lab readiness',30000)
 await page.click('#voice-lab-tab-gentle')
 const choose=(id,value)=>page.eval(`{const x=document.getElementById(${JSON.stringify(id)});x.value=${JSON.stringify(value)};x.dispatchEvent(new Event('change',{bubbles:true}))}`)
 const ready=()=>page.waitFor(`document.getElementById('voice-lab-gentle-status').dataset.state==='ready'`,'four-way readiness',10000)
 for(const source of ['high_voice.wav','low_voice.wav','mid_voice.wav','mencken_wasichu.wav','test_tone']){
  await choose('voice-lab-gentle-source',source);await ready()
  const settings=await page.eval(`JSON.parse(document.getElementById('voice-lab-gentle').dataset.round).cases[${JSON.stringify(source)}].settings`)
  assert.equal(settings.half_pitch.pitch,settings.current_pitch.pitch/2)
  assert.equal(settings.zero_pitch.pitch,0)
  assert.equal(settings.half_pitch.scale,settings.current_pitch.scale)
  assert.equal(settings.zero_pitch.scale,settings.current_pitch.scale)
  for(const version of ['original','current_pitch','half_pitch','zero_pitch']){
   await page.click(`#voice-lab-gentle-play-${version}`)
   await page.waitFor(`document.getElementById('voice-lab-gentle-status').dataset.state==='playing'`,'gentle version playback',10000)
   assert.equal(await page.eval('window.gentleBuffer.duration'),.75)
   await page.click('#voice-lab-gentle-stop')
  }
  await page.click('#voice-lab-gentle-all')
  await page.waitFor(`document.getElementById('voice-lab-gentle-status').dataset.state==='playing'`,'four versions in sequence',10000)
  assert.equal(await page.eval('window.gentleBuffer.duration'),3,'four complete clips and four gaps')
  await page.click('#voice-lab-gentle-stop')
 }
 await choose('voice-lab-gentle-source','mid_voice.wav');await ready()
 assert(await page.eval(`document.querySelector('#voice-lab-gentle [data-round-note]').textContent.includes('unresolved')`))
 await choose('voice-lab-review-gentle-comparison-preference','zero_pitch')
 await page.waitFor(`document.getElementById('voice-lab-review-gentle-status').dataset.state==='saved'`,'zero-pitch preference saved',10000)
 assert(await page.eval(`window.gentleReviews.at(-1).context.mode==='gentle_pitch_1'&&window.gentleReviews.at(-1).ratings.comparison.preference==='zero_pitch'`))
 await choose('voice-lab-review-gentle-comparison-preference','none')
 await page.waitFor(`document.getElementById('voice-lab-review-gentle-status').dataset.state==='saved'`,'reject-round preference saved',10000)
 assert(await page.eval(`window.gentleReviews.at(-1).ratings.comparison.preference==='none'`),'None is useful differs from No pitch shift')
 await page.click('#voice-lab-gentle-live-zero_pitch')
 assert(await page.eval(`document.getElementById('voice-lab-live-mode').value==='dsp'&&document.getElementById('voice-lab-live-engine').value==='spectral'&&document.getElementById('voice-lab-live-pitch-strength').value==='zero_pitch'&&document.getElementById('voice-lab-live-buffering').value==='baseline'`))
 assert.equal(await page.eval('window.__randosStreams.length'),0,'handoff opens no microphone')
 await choose('voice-lab-live-engine','world')
 assert(await page.eval(`document.getElementById('voice-lab-live-buffer-experiment').hidden&&document.getElementById('voice-lab-live-buffering').value==='baseline'`),'shorter experiment stays Signalsmith-only')
 console.log('gentler pitch: all sources/versions, fixed resonance, independent zero/reject votes, pauses and exact live handoff passed')
}finally{await browser.close()}
