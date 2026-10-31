// Fake microphone only; Chrome is muted. No real audio or review writes.
import assert from 'node:assert/strict'
import {wavFixture} from './wav_fixture.mjs'
import {Browser, BASE_URL} from './cdp.mjs'
const browser=await Browser.launch()
const instrument=`(() => {
 const WorkerClass=window.Worker,Context=window.AudioContext,capture=navigator.mediaDevices.getUserMedia.bind(navigator.mediaDevices);
 window.dspWorkers=[];window.dspContexts=[];window.dspRequested=false;
 window.Worker=class extends WorkerClass{constructor(...args){super(...args);window.dspWorkers.push(this)}postMessage(data,...args){if(data.type==='init')this.initConfig={engine:data.engine,pitch:data.pitch,scale:data.scale};return super.postMessage(data,...args)}terminate(){this.wasTerminated=true;super.terminate()}};
 window.AudioContext=class extends Context{constructor(...args){super(...args);window.dspContexts.push(this)}};
 navigator.mediaDevices.getUserMedia=(...args)=>{window.dspRequested=true;return capture(...args)};
 const fixture=${wavFixture.toString()};
 const fetch=window.fetch.bind(window);window.fetch=(url,options)=>{
  if(url==='/dev/voice-lab/reviews')return Promise.reject(Error('This test must not save reviews'));
  if(String(url).includes('/voice-lab/models/'))return Promise.resolve(new Response(fixture()));
  return fetch(url,options);
 };
})()`
async function open(name,options){
 const page=await browser.newPage(name,options)
 await page.send('Page.addScriptToEvaluateOnNewDocument',{source:instrument})
 await page.open(`${BASE_URL}/dev/voice-lab`); await page.labView('listen')
 await page.waitFor(`document.getElementById('voice-lab-status')?.dataset.state==='rendered'`,'lab ready',30000)
 return page
}
const choose=(page,id,value)=>page.eval(`{const x=document.getElementById(${JSON.stringify(id)});x.value=${JSON.stringify(value)};x.dispatchEvent(new Event('change',{bubbles:true}))}`)
const stopped=page=>page.waitFor(`window.__randosStreams.every(s=>s.getTracks().every(t=>t.readyState==='ended'))&&window.dspWorkers.every(w=>w.wasTerminated)&&window.dspContexts.every(c=>c.state==='closed')`,'complete DSP teardown',10000)
try {
 const page=await open('dsp-live')
 await page.labView('engines')
 await page.waitFor(`document.getElementById('voice-lab-engines-status')?.dataset.state==='ready'`,'engine comparison ready',30000)
 await page.click('#voice-lab-engines-live-world')
 assert(await page.eval(`document.getElementById('voice-lab-view').value==='voice'&&document.getElementById('voice-lab-live-mode').value==='dsp'&&document.getElementById('voice-lab-live-engine').value==='world'`))
 assert.equal(await page.eval('window.__randosStreams.length'),0,'Use live selects settings without opening microphone')
 await choose(page,'voice-lab-live-engine','spectral')
 await page.click('#voice-lab-live-modified')
 await page.waitFor(`document.getElementById('voice-lab-live-dsp-metrics').dataset.delaySamples!==undefined`,'Signalsmith actual playout',15000)
 assert(await page.eval(`document.getElementById('voice-lab-live-status').dataset.state==='monitoring'`))
 await choose(page,'voice-lab-live-profile','lower_resonance')
 await stopped(page)
 await page.click('#voice-lab-live-modified')
 await page.waitFor(`document.getElementById('voice-lab-live-dsp-metrics').dataset.delaySamples!==undefined`,'lower pitch stronger resonance playout',15000)
 assert.deepEqual(await page.eval('window.dspWorkers.at(-1).initConfig'),{engine:'spectral',pitch:-2,scale:.8},'new profile reaches the live processor')
 for(const [strength,pitch] of [['half_pitch',-1],['zero_pitch',0],['current_pitch',-2]]){
  await choose(page,'voice-lab-live-pitch-strength',strength)
  await stopped(page)
  await page.click('#voice-lab-live-modified')
  await page.waitFor(`document.getElementById('voice-lab-live-dsp-metrics').dataset.delaySamples!==undefined`,'pitch strength streaming',15000)
  assert.deepEqual(await page.eval('window.dspWorkers.at(-1).initConfig'),{engine:'spectral',pitch,scale:.8},'resonance stays fixed while pitch movement changes')
 }
 const first=await page.eval('window.__randosStreams.length')
 await page.click('#voice-lab-live-original')
 assert.equal(await page.eval('window.__randosStreams.length'),first,'switching versions reuses microphone')
 await page.click('#voice-lab-live-modified')
 await choose(page,'voice-lab-live-engine','world')
 await stopped(page)
 assert(await page.eval(`document.getElementById('voice-lab-live-status').dataset.state==='idle'`),'settings change stops monitoring')
 await page.click('#voice-lab-live-modified')
 await page.waitFor(`document.getElementById('voice-lab-live-dsp-metrics').dataset.delaySamples!==undefined`,'WORLD actual playout',15000)
 assert.deepEqual(await page.eval('window.dspWorkers.at(-1).initConfig'),{engine:'world',pitch:-2,scale:.8},'WORLD also processes the newly shared profile')
 await page.eval(`window.dspWorkers.at(-1).dispatchEvent(new ErrorEvent('error',{message:'Injected DSP failure'}))`)
 await page.waitFor(`document.getElementById('voice-lab-live-status').dataset.state==='failed'`,'visible terminal worker failure',10000)
 await stopped(page)
 assert(await page.eval(`document.getElementById('voice-lab-live-status').textContent.includes('No original-voice fallback')`))
 await choose(page,'voice-lab-live-engine','spectral')
 await page.click('#voice-lab-live-modified')
 await page.waitFor(`document.getElementById('voice-lab-live-dsp-metrics').dataset.delaySamples!==undefined`,'restart after failure',15000)
 await page.labView('listen')
 await stopped(page)
 // Device loss must close the remaining microphone tracks and worker too.
 await page.labView('voice')
 await page.click('#voice-lab-live-modified')
 await page.waitFor(`document.getElementById('voice-lab-live-dsp-metrics').dataset.delaySamples!==undefined`,'device-loss preview',15000)
 await page.eval(`window.__randosStreams.at(-1).getAudioTracks()[0].dispatchEvent(new Event('ended'))`)
 await stopped(page)
 assert(await page.eval(`document.getElementById('voice-lab-live-status').textContent.includes('disconnected')`))
 await page.click('#voice-lab-live-modified')
 await page.waitFor(`document.getElementById('voice-lab-live-dsp-metrics').dataset.delaySamples!==undefined`,'navigation preview',15000)
 await page.eval(`window.addEventListener('pagehide',()=>sessionStorage.setItem('dspEndedOnLeave',String(window.__randosStreams.every(s=>s.getTracks().every(t=>t.readyState==='ended'))&&window.dspWorkers.every(w=>w.wasTerminated))))`)
 await page.send('Page.navigate',{url:BASE_URL+'/'})
 await page.waitFor(`document.getElementById('voice-lab')===null&&sessionStorage.getItem('dspEndedOnLeave')==='true'`,'navigation releases microphone',10000)
 const initializing=await open('dsp-initializing')
 await initializing.labView('voice');await choose(initializing,'voice-lab-live-mode','dsp')
 await initializing.eval(`{const add=AudioWorklet.prototype.addModule;AudioWorklet.prototype.addModule=function(...args){if(args[0].includes('dsp_bridge'))return new Promise(resolve=>{window.releaseDspModule=resolve});return add.apply(this,args)}}`)
 await initializing.click('#voice-lab-live-modified')
 await initializing.waitFor('typeof window.releaseDspModule===\"function\"','pending bridge initialization',10000)
 await initializing.click('#voice-lab-live-stop')
 await initializing.eval('window.releaseDspModule()')
 await stopped(initializing)
 assert.equal(await initializing.eval('window.dspRequested'),false,'cancelled initialization never requests the microphone')
 const denied=await open('dsp-denied',{getUserMediaError:'NotAllowedError'})
 await denied.labView('voice');await choose(denied,'voice-lab-live-mode','dsp');await denied.click('#voice-lab-live-modified')
 await denied.waitFor(`document.getElementById('voice-lab-live-status').dataset.state==='failed'`,'denied microphone',15000)
 await stopped(denied)
 const late=await open('dsp-late',{getUserMediaDelayMs:1500})
 await late.labView('voice');await choose(late,'voice-lab-live-mode','dsp');await late.click('#voice-lab-live-modified')
 await late.waitFor('window.dspRequested','pending permission',15000)
 await late.click('#voice-lab-live-stop')
 await late.waitFor('window.__randosStreams.length===1','late permission grant',10000)
 await stopped(late)
 assert(await late.eval(`document.getElementById('voice-lab-live-status').dataset.state==='idle'`))
 console.log('live DSP: both engines, dry/wet switching, profile changes, worker failure, device loss, navigation, denied and late permission teardown passed')
}finally{await browser.close()}
