// Verify the real listening matrix without saving feedback or playing audible sound.
import assert from "node:assert/strict"
import {mkdirSync, writeFileSync} from "node:fs"
import {resolve} from "node:path"
import {Browser, BASE_URL} from "../../test/e2e/cdp.mjs"

const browser = await Browser.launch()
const report = {generated_at: new Date().toISOString(), base_url: BASE_URL, cases: []}
try {
  const page = await browser.newPage("voice-lab-matrix")
  await page.open(`${BASE_URL}/dev/voice-lab`)
  await page.waitFor(`document.getElementById('voice-lab-status')?.dataset.state==='rendered'`, "lab readiness", 30_000)
  await page.eval(`(() => {
    const start=AudioBufferSourceNode.prototype.start;
    AudioBufferSourceNode.prototype.start=function(...args){window.auditBuffer=this.buffer;return start.apply(this,args);};
  })()`)
  const modifications = await page.eval(`[...document.getElementById('voice-lab-processor').options].map(o=>({value:o.value,label:o.label}))`)
  const voices = await page.eval(`[...document.getElementById('voice-lab-source').options].map(o=>({value:o.value,label:o.label}))`)
  assert.equal(voices.filter(source => source.value.endsWith(".wav")).length, 4, "all four public voices are listed")
  assert(voices.some(source => source.value === "test_tone"), "generated tone is included")
  const choose = (id, value) => page.eval(`{const input=document.getElementById(${JSON.stringify(id)});input.value=${JSON.stringify(value)};input.dispatchEvent(new Event('change',{bubbles:true}));}`)
  for (const modification of modifications) {
    for (const voice of voices) {
      await choose("voice-lab-source", voice.value)
      await choose("voice-lab-processor", modification.value)
      await page.waitFor(`['rendered','unavailable','failed'].includes(document.getElementById('voice-lab-status').dataset.state)`, `${modification.value}/${voice.value} preparation`, 30_000)
      assert.equal(await page.eval(`document.getElementById('voice-lab-status').dataset.state`), "rendered", `${modification.value}/${voice.value}: missing/failed output`)
      const prepared = await page.eval(`(async () => {
        const root=document.getElementById('voice-lab'), name=document.getElementById('voice-lab-processor').value, source=document.getElementById('voice-lab-source').value;
        const models=JSON.parse(root.dataset.preparedModels), item=models[name]?.[source];
        if(!models[name])return null;
        if(!item||item.context.source_id!==JSON.parse(root.dataset.reviewSources)[source])throw new Error('Missing or stale prepared source');
        const decoder=new OfflineAudioContext(1,1,48000), expected={};
        for(const [version,key] of [['original','original'],['modified','converted']]){
          const filename=item.audio[key], response=await fetch('/dev/voice-lab/models/'+encodeURIComponent(filename));
          if(!response.ok)throw new Error('Missing WAV: '+filename);
          const bytes=await response.arrayBuffer(), hash=[...new Uint8Array(await crypto.subtle.digest('SHA-256',bytes))].map(x=>x.toString(16).padStart(2,'0')).join('');
          if(!filename.endsWith('__'+hash+'.wav'))throw new Error('WAV content hash mismatch');
          const buffer=await decoder.decodeAudioData(bytes);
          expected[version]={seconds:buffer.duration,samples:buffer.length,rate:buffer.sampleRate};
        }
        return {context:item.context,expected};
      })()`)
      const versions = {}
      for (const [version, button] of [["original", "voice-lab-play-original"], ["modified", "voice-lab-play"]]) {
        await page.click(`#${button}`)
        await page.waitFor(`document.getElementById('voice-lab').dataset.playing===${JSON.stringify(version)}`, `${version} playback`, 10_000)
        versions[version] = await page.eval(`(() => {
          const x=window.auditBuffer.getChannelData(0);let power=0,peak=0;
          for(const v of x){if(!Number.isFinite(v))throw new Error('Nonfinite playback');power+=v*v;peak=Math.max(peak,Math.abs(v));}
          return {seconds:window.auditBuffer.duration,samples:x.length,rate:window.auditBuffer.sampleRate,rms:Math.sqrt(power/x.length),peak};
        })()`)
        assert(versions[version].seconds > 1 && versions[version].rms > 1e-6, "nonempty, non-silent audio")
        if (prepared) {
          assert.equal(versions[version].samples, prepared.expected[version].samples, "play the complete selected WAV")
          assert.equal(versions[version].rate, prepared.expected[version].rate)
        }
        await page.click("#voice-lab-stop")
      }
      await page.click("#voice-lab-play-comparison")
      await page.waitFor(`document.getElementById('voice-lab').dataset.playing==='comparison'`, "paired playback", 10_000)
      const pairSeconds = await page.eval(`window.auditBuffer.duration`)
      assert(Math.abs(pairSeconds - versions.original.seconds - versions.modified.seconds - .5) < .01, "both complete clips with two 250 ms gaps")
      await page.click("#voice-lab-stop")
      report.cases.push({modification, voice, prepared_context: prepared?.context ?? null, versions, pair_seconds: pairSeconds})
    }
    console.log(`✓ ${modification.label}: all ${voices.length} sources`)
  }
  for (const id of ["round", "engines", "gentle"]) {
    await page.click(`#voice-lab-tab-${id}`)
    const clips = []
    const round = await page.eval(`JSON.parse(document.getElementById('voice-lab-'+${JSON.stringify(id)}).dataset.round)`)
    for (const [source, item] of Object.entries(round.cases)) {
      await choose(`voice-lab-${id}-source`, source)
      await page.waitFor(`document.getElementById('voice-lab-'+${JSON.stringify(id)}+'-status').dataset.state==='ready'`, "comparison readiness", 30_000)
      const lengths = []
      for (const variant of round.variants) {
        const expected = await page.eval(`(async()=>{
          const filename=${JSON.stringify(item.audio[variant.id])},response=await fetch('/dev/voice-lab/models/'+encodeURIComponent(filename));
          if(!response.ok)throw Error('Missing round WAV');
          const bytes=await response.arrayBuffer(),hash=[...new Uint8Array(await crypto.subtle.digest('SHA-256',bytes))].map(x=>x.toString(16).padStart(2,'0')).join('');
          if(!filename.endsWith('__'+hash+'.wav'))throw Error('Round content hash mismatch');
          const buffer=await new OfflineAudioContext(1,1,48000).decodeAudioData(bytes);return {length:buffer.length,rate:buffer.sampleRate};
        })()`)
        await page.click(`#voice-lab-${id}-play-${variant.id}`)
        await page.waitFor(`document.getElementById('voice-lab-'+${JSON.stringify(id)}+'-status').dataset.state==='playing'`, "round version playback", 10_000)
        assert.equal(await page.eval('window.auditBuffer.length'),expected.length+12000,"full round clip and trailing pause")
        assert.equal(item.context.source_id,await page.eval(`JSON.parse(document.getElementById('voice-lab').dataset.reviewSources)[${JSON.stringify(source)}]`),"round source context")
        await page.click(`#voice-lab-${id}-stop`)
        lengths.push(expected.length)
        clips.push({source,variant:variant.id,samples:expected.length,context:item.context})
      }
      await page.click(`#voice-lab-${id}-all`)
      await page.waitFor(`document.getElementById('voice-lab-'+${JSON.stringify(id)}+'-status').dataset.state==='playing'`, "comparison playback", 10_000)
      assert.equal(await page.eval('window.auditBuffer.length'),lengths.reduce((a,b)=>a+b,0)+round.variants.length*12000,"all complete clips and pauses")
      await page.click(`#voice-lab-${id}-stop`)
    }
    report[id + "_cases"] = clips
    report[id + "_complete"] = clips.length === ({round:25,engines:15,gentle:20}[id])
    assert(report[id + "_complete"], "all expected comparison clips")
    console.log(`${clips.length}/${({round:25,engines:15,gentle:20}[id])} ${id} comparison clips passed`)
  }
  report.modifications = modifications.length
  report.voices = 4
  report.sources = voices.length
  report.complete = report.cases.length === modifications.length * voices.length
  console.log(`${report.cases.length}/${modifications.length * voices.length} listening pairs passed; no reviews written`)
} finally {
  await browser.close()
  const output = resolve("tmp/voice-browser/lab-audit.json")
  mkdirSync(resolve("tmp/voice-browser"), {recursive: true})
  writeFileSync(output, JSON.stringify(report, null, 2) + "\n")
}
