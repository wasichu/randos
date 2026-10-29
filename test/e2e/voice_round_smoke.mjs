// Hermetic compact-round interaction test. No real review POST reaches disk.
import assert from 'node:assert/strict'
import {Browser, BASE_URL} from './cdp.mjs'
const browser=await Browser.launch()
try {
  const page=await browser.newPage('masking-round')
  await page.send('Page.addScriptToEvaluateOnNewDocument',{source:`(() => {
    const fetch=window.fetch.bind(window),start=AudioBufferSourceNode.prototype.start;
    window.roundPosts=[];
    AudioBufferSourceNode.prototype.start=function(...args){window.lastRoundBuffer=this.buffer;window.lastRoundNode=this;window.roundStarted=this.context.currentTime;return start.apply(this,args)};
    const fixture=()=>{
      const b=new ArrayBuffer(192044),v=new DataView(b),text=(at,s)=>[...s].forEach((c,i)=>v.setUint8(at+i,c.charCodeAt(0)));
      text(0,'RIFF');v.setUint32(4,192036,true);text(8,'WAVE');text(12,'fmt ');v.setUint32(16,16,true);v.setUint16(20,1,true);v.setUint16(22,1,true);v.setUint32(24,48000,true);v.setUint32(28,96000,true);v.setUint16(32,2,true);v.setUint16(34,16,true);text(36,'data');v.setUint32(40,192000,true);
      for(let i=0;i<96000;i++)v.setInt16(44+i*2,Math.round(Math.sin(i*.03)*3000),true);return b;
    };
    window.roundFixture=fixture;
    window.fetch=(url,options)=>{
      if(url==='/dev/voice-lab/reviews'){window.roundPosts.push(JSON.parse(options.body));return Promise.resolve(new Response(JSON.stringify({saved_at:new Date().toISOString()}),{status:201}))}
      if(!String(url).includes('/voice-lab/models/'))return fetch(url,options);
      if(window.roundFail)return Promise.resolve(new Response('missing',{status:404}));
      const response=()=>new Response(fixture());
      if(window.roundHold){window.roundHold=false;return new Promise(resolve=>{window.releaseRound=()=>resolve(response())})}
      return Promise.resolve(response());
    };
  })()`})
  await page.open(`${BASE_URL}/dev/voice-lab`)
  await page.waitFor(`document.getElementById('voice-lab-status')?.dataset.state==='rendered'`,'lab readiness',30000)
  const ready=()=>page.waitFor(`document.getElementById('voice-lab-round-status').dataset.state==='ready'`,'five ready versions',10000)
  const choose=(id,value)=>page.eval(`{const x=document.getElementById(${JSON.stringify(id)});x.value=${JSON.stringify(value)};x.dispatchEvent(new Event('change',{bubbles:true}))}`)
  await ready()
  await page.click('#voice-lab-play')
  await page.waitFor(`document.getElementById('voice-lab').dataset.playing==='modified'`,'main playback',10000)
  await page.click('#voice-lab-tab-round')
  assert(await page.eval(`document.getElementById('voice-lab').dataset.playing==='none'`),'changing views stops main playback')
  await page.click('#voice-lab-round-all')
  await page.waitFor(`document.getElementById('voice-lab-round-status').dataset.state==='playing'`,'all five playback',10000)
  assert.equal(await page.eval('window.lastRoundBuffer.duration'),11.25,'five complete two-second clips and five quarter-second pauses')
  assert(await page.eval(`document.querySelector('#voice-lab-round [data-round-row="original"]').dataset.active==='true'`),'current clip is highlighted')
  await page.waitFor(`document.querySelector('#voice-lab-round [data-round-row="current"]').dataset.active==='true'`,'sequence advances to current',10000)
  await page.click('#voice-lab-round-play-current')
  assert(await page.eval(`document.getElementById('voice-lab-round').dataset.playing===''`),'active row stop button stops the sequence')
  await page.click('#voice-lab-round-loop')
  await page.click('#voice-lab-round-play-more_pitch')
  await page.waitFor(`document.getElementById('voice-lab-round-status').dataset.state==='playing'`,'single version playback',10000)
  await page.waitFor(`window.lastRoundNode.context.currentTime-window.roundStarted>2.3`,'second loop iteration',10000)
  await page.click('#voice-lab-round-loop')
  await page.waitFor(`window.lastRoundNode.context.currentTime-window.roundStarted>2.6&&document.querySelector('#voice-lab-round [data-round-row="more_pitch"]').dataset.active==='true'`,'cursor remains accurate when loop is disabled',10000)
  await page.click('#voice-lab-round-stop')
  await page.click('#voice-lab-round-play-more_pitch')
  await page.waitFor(`document.getElementById('voice-lab-round-status').dataset.state==='playing'`,'round restarts',10000)
  await page.eval(`(async()=>{const audio=document.querySelector('[data-recovery-audio]');const url=URL.createObjectURL(new Blob([window.roundFixture()],{type:'audio/wav'}));audio.src=url;await audio.play();audio.pause();URL.revokeObjectURL(url)})()`)
  assert(await page.eval(`document.getElementById('voice-lab-round').dataset.playing===''`),'native audio player stops the round')
  await page.click('#voice-lab-round-play-more_pitch')
  await page.waitFor(`document.getElementById('voice-lab-round-status').dataset.state==='playing'`,'round restarts before leaving',10000)
  await page.click('#voice-lab-tab-listen')
  assert(await page.eval(`document.getElementById('voice-lab-round').dataset.playing===''`),'leaving round stops looping audio')
  await page.click('#voice-lab-tab-round')
  await choose('voice-lab-round-source','low_voice.wav')
  await ready()
  await choose('voice-lab-review-round-comparison-preference','none')
  await page.waitFor(`document.getElementById('voice-lab-review-round-status').dataset.state==='saved'`,'automatic round preference save',10000)
  assert(await page.eval(`window.roundPosts.at(-1).context.view==='round'&&window.roundPosts.at(-1).context.sample==='low_voice'&&window.roundPosts.at(-1).ratings.comparison.preference==='none'`))
  await choose('voice-lab-round-source','mid_voice.wav')
  await ready()
  assert.equal(await page.eval(`document.getElementById('voice-lab-review-round-comparison-preference').value`),'','preferences are source-specific')
  await choose('voice-lab-round-source','low_voice.wav')
  await ready()
  assert.equal(await page.eval(`document.getElementById('voice-lab-review-round-comparison-preference').value`),'none','previous preference restores')
  await page.eval('window.roundHold=true')
  await choose('voice-lab-round-source','high_voice.wav')
  await page.waitFor('typeof window.releaseRound==="function"','held round preparation',10000)
  assert(await page.eval(`document.getElementById('voice-lab-review-round-comparison-preference').disabled`),'preference disabled during preparation')
  await choose('voice-lab-round-source','test_tone')
  await ready()
  await page.eval('window.releaseRound()')
  await page.waitFor(`document.getElementById('voice-lab-round-status').textContent.includes('tone checks')`,'latest source retained',10000)
  await page.eval('window.roundFail=true')
  await choose('voice-lab-round-source','high_voice.wav')
  await page.waitFor(`document.getElementById('voice-lab-round-status').dataset.state==='failed'`,'missing clip state',10000)
  assert(await page.eval(`[...document.querySelectorAll('#voice-lab-round [data-round-play],#voice-lab-round-all')].every(x=>x.disabled)&&document.getElementById('voice-lab-review-round-comparison-preference').disabled`),'no partial comparison or preference')
  console.log('masking round: sequence gaps, progress, playback ownership, source isolation, auto-save, stale preparation and missing clips passed')
}finally{await browser.close()}
