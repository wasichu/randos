// Model modifications share the main A/B controls. Tiny fixtures avoid any
// dependency on generated audio or model inference in the hermetic suite.
import assert from "node:assert/strict"
import {Browser, BASE_URL} from "./cdp.mjs"
const browser = await Browser.launch()
try {
  const page = await browser.newPage("model-menu")
  await page.open(`${BASE_URL}/dev/voice-lab`); await page.labView('listen')
  await page.waitFor(`document.getElementById('voice-lab-status')?.dataset.state==='rendered'`, "lab readiness", 30_000)
  await page.eval(`(() => {
    const fetch=window.fetch.bind(window), start=AudioBufferSourceNode.prototype.start;
    AudioBufferSourceNode.prototype.start=function(...args) { window.menuNode=this; return start.apply(this,args); };
    const fixture=level=>{
      const bytes=new ArrayBuffer(48044), d=new DataView(bytes), text=(at,s)=>[...s].forEach((c,i)=>d.setUint8(at+i,c.charCodeAt(0)));
      text(0,'RIFF');d.setUint32(4,48036,true);text(8,'WAVE');text(12,'fmt ');d.setUint32(16,16,true);
      d.setUint16(20,1,true);d.setUint16(22,1,true);d.setUint32(24,48000,true);d.setUint32(28,96000,true);d.setUint16(32,2,true);d.setUint16(34,16,true);
      text(36,'data');d.setUint32(40,48000,true);for(let i=0;i<24000;i++)d.setInt16(44+i*2,Math.round(level*32767),true);return bytes;
    };
    window.fetch=(url,options)=>{
      if(url==='/dev/voice-lab/reviews'){window.menuReview=JSON.parse(options.body);return Promise.resolve(new Response(JSON.stringify({saved_at:new Date().toISOString()}),{status:201}));}
      if(!String(url).includes('/voice-lab/models/'))return fetch(url,options);
      if(window.menuFail)return Promise.resolve(new Response('missing',{status:404}));
      const response=()=>new Response(fixture(String(url).includes('__original__')?.05:.2));
      if(window.menuHold&&String(url).includes('__converted__')){window.menuHold=false;return new Promise(resolve=>{window.releaseMenu=()=>resolve(response());});}
      return Promise.resolve(response());
    };
  })()`)
  const choose=(id,value)=>page.eval(`{const input=document.getElementById(${JSON.stringify(id)});input.value=${JSON.stringify(value)};input.dispatchEvent(new Event('change',{bubbles:true}));}`)
  const ready=()=>page.waitFor(`document.getElementById('voice-lab-status').dataset.state==='rendered'`, "prepared model pair", 10_000)
  await choose("voice-lab-source","high_voice.wav")
  await choose("voice-lab-processor","seed_vc_v2")
  await ready()
  assert(await page.eval(`document.getElementById('voice-lab-params').hidden && !document.getElementById('voice-lab-result-modified').dataset.latencyMs && document.querySelector('#voice-lab-result-modified [data-metrics]').textContent.includes('Pre-rendered')`))
  await page.click("#voice-lab-play-original")
  await page.waitFor(`document.getElementById('voice-lab').dataset.playing==='original'`, "prepared original", 10_000)
  assert(await page.eval(`window.menuNode.buffer.duration===.5 && Math.abs(window.menuNode.buffer.getChannelData(0)[0]-.05)<.001`), "use matched prepared original, not raw source")
  await page.click("#voice-lab-play-comparison")
  await page.waitFor(`document.getElementById('voice-lab').dataset.playing==='comparison'`, "prepared A/B comparison", 10_000)
  assert(await page.eval(`window.menuNode.buffer.duration===1.5 && Math.abs(window.menuNode.buffer.getChannelData(0)[36000]-.2)<.001`))
  await page.click("#voice-lab-stop")
  await choose("voice-lab-review-listen-disguised-resemblance","different")
  await page.click("#voice-lab-review-listen [data-review-save]")
  await page.waitFor(`document.getElementById('voice-lab-review-listen-status').dataset.state==='saved'`, "model review save", 10_000)
  assert(await page.eval(`window.menuReview.context.view==='model' && window.menuReview.context.processor==='seed_vc_v2' && window.menuReview.context.mode==='average_voice_style'`))
  await page.labView('models')
  assert(await page.eval(`document.getElementById('voice-lab-review-model-disguised-resemblance').value==='different'`), "same exact review context across views")
  await page.labView('listen')
  await choose("voice-lab-processor","tvtsyn_browser")
  await ready()
  await choose("voice-lab-review-listen-disguised-clarity","clear")
  await page.click("#voice-lab-review-listen [data-review-save]")
  await page.waitFor(`document.getElementById('voice-lab-review-listen-status').dataset.state==='saved'`, "TVTSyn review save", 10_000)
  assert(await page.eval(`window.menuReview.context.processor==='tvtsyn_browser' && window.menuReview.context.mode==='browser_wasm'`))
  await page.labView('voice')
  assert(await page.eval(`document.getElementById('voice-lab-live-modified').disabled && !document.getElementById('voice-lab-live-original').disabled`))
  await page.click("#voice-lab-live-original")
  await page.waitFor(`document.getElementById('voice-lab-live-status').dataset.state==='monitoring'`, "original mic with offline option", 10_000)
  await page.labView('listen')
  await choose("voice-lab-source","mid_voice.wav")
  await ready()
  assert(await page.eval(`document.querySelector('#voice-lab-result-modified [data-description]').textContent.includes('target-voice control')`))
  await choose("voice-lab-source","test_tone")
  await ready()
  assert(await page.eval(`!document.getElementById('voice-lab-play').disabled`))
  await choose("voice-lab-source","mid_voice.wav")
  await ready()
  await choose("voice-lab-processor","seed_vc_v2")
  await ready()
  await page.eval(`window.menuFail=true`)
  await choose("voice-lab-source","low_voice.wav")
  await page.waitFor(`document.getElementById('voice-lab-status').dataset.state==='failed'`, "missing prepared audio", 10_000)
  await page.eval(`window.menuFail=false;window.menuHold=true`)
  await choose("voice-lab-source","high_voice.wav")
  await page.waitFor(`!!window.releaseMenu`, "held model fetch", 10_000)
  await choose("voice-lab-processor","pitch_shift")
  await ready()
  await page.eval(`window.releaseMenu()`)
  await page.eval(`new Promise(resolve=>requestAnimationFrame(()=>requestAnimationFrame(resolve)))`)
  assert(await page.eval(`document.getElementById('voice-lab-result-modified').dataset.processor==='pitch_shift' && !!document.getElementById('voice-lab-result-modified').dataset.realTimeFactor`), "late model load cannot replace DSP")
  for (const processor of ["quality_pitch", "quality_resonance", "quality_both", "quality_tvtsyn"]) {
    await choose("voice-lab-processor",processor)
    await ready()
    assert(await page.eval(`document.querySelector('#voice-lab-result-original [data-metrics]').textContent.includes('Average level matched') && document.querySelector('#voice-lab-result-modified [data-metrics]').textContent.includes('Average level matched')`), "matched pair is labeled on both sides")
  }
  await choose("voice-lab-review-listen-disguised-naturalness","natural")
  await page.click("#voice-lab-review-listen [data-review-save]")
  await page.waitFor(`document.getElementById('voice-lab-review-listen-status').dataset.state==='saved'`, "sound-check review", 10_000)
  assert(await page.eval(`window.menuReview.context.processor==='quality_tvtsyn' && window.menuReview.context.mode==='rms_matched'`))
  await choose("voice-lab-source","low_voice.wav")
  await ready()
  await choose("voice-lab-source","mid_voice.wav")
  await ready()
  assert(await page.eval(`document.querySelector('#voice-lab-result-modified [data-description]').textContent.includes('target-voice control')`))
  for (const source of ["mid_voice.wav", "mencken_wasichu.wav"]) {
    await choose("voice-lab-source",source)
    await choose("voice-lab-processor","quality_both")
    await ready()
    await page.click("#voice-lab-play-comparison")
    await page.waitFor(`document.getElementById('voice-lab').dataset.playing==='comparison'`, "mid/Wasichu sound-check playback", 10_000)
    await page.click("#voice-lab-stop")
  }
  await choose("voice-lab-source","test_tone")
  await ready()
  assert(await page.eval(`document.getElementById('voice-lab-processor-note').textContent.includes('not speech')`))
  for (const processor of ["world_control", "world_pitch", "world_formants", "world_texture", "seed_vc_v2", "tvtsyn_native", "tvtsyn_int8", "hybrid_down_2", "hybrid_up_2", "hybrid_mild"]) {
    await choose("voice-lab-processor",processor)
    await ready()
  }
  await choose("voice-lab-source","high_voice.wav")
  for (const processor of ["world_control", "world_pitch", "world_formants", "world_texture"]) {
    await choose("voice-lab-processor",processor)
    await ready()
    assert(await page.eval(`document.getElementById('voice-lab-params').hidden && !document.getElementById('voice-lab-result-modified').dataset.latencyMs && document.querySelector('#voice-lab-result-modified [data-metrics]').textContent.includes('Average level matched')`))
  }
  await choose("voice-lab-review-listen-disguised-clarity","clear")
  await page.click("#voice-lab-review-listen [data-review-save]")
  await page.waitFor(`document.getElementById('voice-lab-review-listen-status').dataset.state==='saved'`, "WORLD review save", 10_000)
  assert(await page.eval(`window.menuReview.context.processor==='world_texture' && window.menuReview.context.mode==='model_free_dsp'`))
  for (const source of ["low_voice.wav", "mid_voice.wav", "mencken_wasichu.wav"]) {
    await choose("voice-lab-source",source)
    await ready()
  }
  await page.click("#voice-lab-play-comparison")
  await page.waitFor(`document.getElementById('voice-lab').dataset.playing==='comparison'`, "WORLD paired playback", 10_000)
  await page.click("#voice-lab-stop")
  for (const processor of ["browser_world","browser_spectral","browser_time"]) {
    for (const source of ["high_voice.wav","low_voice.wav","mid_voice.wav","mencken_wasichu.wav","test_tone"]) {
      await choose("voice-lab-source",source)
      await choose("voice-lab-processor",processor)
      await ready()
      assert(await page.eval(`document.querySelector('#voice-lab-result-original [data-result-title]').textContent==='Original'`), "browser candidates compare with the raw original")
      await page.click("#voice-lab-play-comparison")
      await page.waitFor(`document.getElementById('voice-lab').dataset.playing==='comparison'`, "browser DSP paired playback", 10_000)
      await page.click("#voice-lab-stop")
    }
    await choose("voice-lab-review-listen-disguised-clarity","clear")
    await page.click("#voice-lab-review-listen [data-review-save]")
    await page.waitFor(`document.getElementById('voice-lab-review-listen-status').dataset.state==='saved'`, "browser DSP review save", 10_000)
    assert(await page.eval(`window.menuReview.context.processor===${JSON.stringify(processor)} && window.menuReview.context.mode==='browser_dsp'`))
  }
  await choose("voice-lab-source","high_voice.wav")
  for (const size of [40,80,160]) {
    await choose("voice-lab-processor",`world_chunk_${size}`)
    await ready()
    assert(await page.eval(`document.querySelector('#voice-lab-result-original [data-result-title]').textContent==='Whole-recording WORLD' && document.querySelector('#voice-lab-result-modified [data-result-title]').textContent==='Chunked WORLD'`), "chunk comparison labels its actual reference")
    assert(await page.eval(`document.getElementById('voice-lab-review-listen-disguised-resemblance').labels[0].querySelector('span').textContent.includes('whole-recording WORLD')`))
    await page.click("#voice-lab-play-comparison")
    await page.waitFor(`document.getElementById('voice-lab').dataset.playing==='comparison'`, "whole/chunk comparison", 10_000)
    assert(await page.eval(`document.querySelector('#voice-lab-play-comparison [data-play-label]').textContent.includes('reference → chunked')`))
    await page.click("#voice-lab-stop")
  }
  await choose("voice-lab-review-listen-disguised-clarity","clear")
  await page.waitFor(`document.getElementById('voice-lab-review-listen-status').dataset.state==='saved'`, "chunk review autosave", 10_000)
  assert(await page.eval(`window.menuReview.context.mode==='chunked_world' && window.menuReview.context.processor==='world_chunk_160'`))
  await choose("voice-lab-source","test_tone")
  await ready()
  await choose("voice-lab-processor","pitch_shift")
  await ready()
  assert(await page.eval(`document.querySelector('#voice-lab-result-original [data-result-title]').textContent==='Original' && document.querySelector('#voice-lab-play-original [data-play-label]').textContent==='Play original' && document.getElementById('voice-lab-review-listen-disguised-resemblance').labels[0].querySelector('span').textContent.includes('original person')`), "regular comparisons restore their labels and review question")
  console.log("model menu: matched references, spectrograms, comparison, reviews, availability, mic guard and stale loads passed")
} finally { await browser.close() }
