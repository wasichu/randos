// Hermetic generated-media UI fixtures; no microphone or owner-review writes.
import assert from 'node:assert/strict'
import {Browser,BASE_URL} from './cdp.mjs'
import {wavFixture} from './wav_fixture.mjs'
const browser=await Browser.launch()
try{
  const page=await browser.newPage('voice-texture')
  await page.send('Page.addScriptToEvaluateOnNewDocument',{source:`(()=>{
    const original=window.fetch.bind(window),fixture=${wavFixture.toString()};
    window.textureReviews=[];window.textureMissing=false;
    const start=AudioBufferSourceNode.prototype.start;
    AudioBufferSourceNode.prototype.start=function(...args){window.textureDuration=this.buffer.duration;return start.apply(this,args)};
    window.fetch=(url,options)=>{
      if(url==='/dev/voice-lab/reviews'){window.textureReviews.push(JSON.parse(options.body));return Promise.resolve(new Response(JSON.stringify({saved_at:new Date().toISOString()}),{status:201}))}
      if(String(url).includes('/voice-lab/models/'))return Promise.resolve(new Response(window.textureMissing?'':fixture(),{status:window.textureMissing?404:200}));
      return original(url,options);
    };
  })()`})
  await page.open(`${BASE_URL}/dev/voice-lab`)
  await page.waitFor(`document.getElementById('voice-lab-view')?.dataset.ready==='true'`,'lab ready',30000)
  assert.equal(await page.eval(`document.getElementById('voice-lab-view').value`),'bandwidth')
  const choose=(id,value)=>page.eval(`{const x=document.getElementById(${JSON.stringify(id)});x.value=${JSON.stringify(value)};x.dispatchEvent(new Event('change',{bubbles:true}))}`)
  for(const [id,mode,names] of [['bandwidth','bandwidth_1',['narrower','wider']],['source_shape','source_1',['softer','sharper']]]){
    await page.labView(id)
    const ready=()=>page.waitFor(`document.getElementById('voice-lab-${id}-status').dataset.state==='ready'`,'prepared comparison',10000)
    for(const source of ['high_voice.wav','mid_voice.wav','low_voice.wav','mencken_wasichu.wav','test_tone']){
      await choose(`voice-lab-${id}-source`,source);await ready()
      for(const variant of ['original','reference','control',...names]){
        await page.click(`#voice-lab-${id}-play-${variant}`)
        await page.waitFor(`document.getElementById('voice-lab-${id}-status').dataset.state==='playing'`,'variant playback',10000)
        await page.click(`#voice-lab-${id}-stop`)
      }
      await page.click(`#voice-lab-${id}-all`)
      await page.waitFor(`document.getElementById('voice-lab-${id}-status').dataset.state==='playing'`,'five-way playback',10000)
      assert.equal(await page.eval('window.textureDuration'),3.75,'five fixture clips and quarter-second gaps')
      await page.click(`#voice-lab-${id}-stop`)
    }
    await choose(`voice-lab-${id}-source`,'mid_voice.wav');await ready()
    await choose(`voice-lab-review-${id}-comparison-preference`,names[0])
    await page.waitFor(`document.getElementById('voice-lab-review-${id}-status').dataset.state==='saved'`,'autosaved new preference',10000)
    assert(await page.eval(`window.textureReviews.at(-1).context.mode===${JSON.stringify(mode)}&&window.textureReviews.at(-1).ratings.comparison.preference===${JSON.stringify(names[0])}`))
    await choose(`voice-lab-${id}-source`,'high_voice.wav');await ready()
    assert.equal(await page.eval(`document.getElementById('voice-lab-review-${id}-comparison-preference').value`),'')
    await choose(`voice-lab-${id}-source`,'mid_voice.wav');await ready()
    assert.equal(await page.eval(`document.getElementById('voice-lab-review-${id}-comparison-preference').value`),names[0])
    await page.eval('window.textureMissing=true')
    await choose(`voice-lab-${id}-source`,'high_voice.wav')
    await page.waitFor(`document.getElementById('voice-lab-${id}-status').dataset.state==='failed'`,'missing asset failure',10000)
    assert(await page.eval(`document.getElementById('voice-lab-${id}-all').disabled`))
    await page.eval('window.textureMissing=false')
    await choose(`voice-lab-${id}-source`,'mid_voice.wav');await ready()
    await page.click(`#voice-lab-${id}-all`)
    await page.waitFor(`document.getElementById('voice-lab-${id}-status').dataset.state==='playing'`,'playing before leaving',10000)
    await page.labView('listen')
    assert.equal(await page.eval(`document.getElementById('voice-lab-${id}').dataset.playing`),'')
    assert.equal(await page.eval(`document.querySelectorAll('#voice-lab-${id} [data-round-live]').length`),0)
  }
  for(const name of ['texture_bandwidth_narrower','texture_bandwidth_wider','texture_source_softer','texture_source_sharper']){
    await choose('voice-lab-processor',name)
    await page.waitFor(`document.getElementById('voice-lab-status').dataset.state==='rendered'`,'prepared Listen choice',10000)
  }
  assert.equal(await page.eval('window.__randosStreams.length'),0)
  console.log('both DSP texture rounds: all 50 versions, pauses, autosave, isolated contexts, missing assets, Listen options and teardown passed')
}finally{await browser.close()}
