// Offline, pipe-owned muted Chrome. No microphone, speaker or external requests.
import {createServer} from 'node:http'
import {readFileSync,writeFileSync} from 'node:fs'
import {resolve,join} from 'node:path'
import {createHash} from 'node:crypto'
import {gzipSync,brotliCompressSync} from 'node:zlib'
import {execFileSync} from 'node:child_process'
import {cpus,platform,arch} from 'node:os'
import {Browser} from '../../../test/e2e/cdp.mjs'
const root=resolve('.'),here=join(root,'tools/voice-fargan/browser'),out=join(root,'tmp/fargan/browser')
const hash=b=>createHash('sha256').update(b).digest('hex')
const inputs=JSON.parse(readFileSync(join(out,'inputs.json'))),build=JSON.parse(readFileSync(join(out,'build.json')))
if(hash(readFileSync(join(out,'build.json')))!==inputs.build_sha256)throw Error('Stale prepared build')
for(const [path,wanted] of Object.entries({...build.files,...inputs.sources}))if(hash(readFileSync(join(root,path)))!==wanted)throw Error('Stale source/build: '+path)
const paths=new Map([['/','HTML'],['/page.mjs',join(here,'page.mjs')],['/worker.mjs',join(here,'worker.mjs')],['/adapter-core.js',join(root,'assets/js/randos/voice/dsp_adapter.js')]])
for(const ext of ['mjs','wasm']){
  paths.set('/fargan-core.'+ext,join(out,'fargan-core.'+ext))
  paths.set('/spectral.'+ext,join(root,'assets/vendor/voice_dsp/spectral.'+ext))
}
for(const c of Object.values(inputs.inputs)){
  const path=join(out,c.input)
  if(hash(readFileSync(path))!==c.input_sha256)throw Error('Stale input')
  paths.set(`/input/${c.clip}.f32`,path)
}
const report={generated_at:new Date().toISOString(),scope:'Dedicated Worker, causal 48→16→48 kHz FARGAN versus full-band Signalsmith. Independent timers and simulated 200 ms playout; no AudioWorklet, microphone, call or mobile qualification.',host:{platform:platform(),arch:arch(),cpu:cpus()[0].model},inputs_sha256:hash(readFileSync(join(out,'inputs.json'))),assets:{},sources:{},cases:[],paced:[],complete:false}
for(const [url,path] of paths)if(path!=='HTML'){
  const b=readFileSync(path);report.sources[url]=hash(b)
  if(url.endsWith('.wasm')||url.endsWith('core.mjs')||url==='/spectral.mjs')report.assets[url]={bytes:b.length,gzip_bytes:gzipSync(b).length,brotli_bytes:brotliCompressSync(b).length,sha256:hash(b)}
}
report.sources['run.mjs']=hash(readFileSync(join(here,'run.mjs')))
const server=createServer((req,res)=>{
  const path=paths.get(req.url)
  if(!path){res.writeHead(404).end();return}
  res.setHeader('Content-Type',path==='HTML'?'text/html':path.endsWith('.mjs')||path.endsWith('.js')?'text/javascript':path.endsWith('.wasm')?'application/wasm':'application/octet-stream')
  res.end(path==='HTML'?'<!doctype html><title>FARGAN browser gate</title><script type="module" src="/page.mjs"></script>':readFileSync(path))
})
const rss=pid=>{
  const rows=execFileSync('ps',['-axo','pid=,ppid=,rss='],{encoding:'utf8'}).trim().split('\n').map(x=>x.trim().split(/\s+/).map(Number)),ids=new Set([pid])
  for(let change=true;change;){change=false;for(const [id,parent] of rows)if(ids.has(parent)&&!ids.has(id)){ids.add(id);change=true}}
  return rows.filter(x=>ids.has(x[0])).reduce((n,x)=>n+x[2]/1024,0)
}
let browser
await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve))
const pageFor=async()=>{
  browser=await Browser.launch();report.browser=await browser.send('Browser.getVersion')
  const page=await browser.newPage('fargan-browser-gate')
  await page.send('Page.navigate',{url:`http://127.0.0.1:${server.address().port}/`})
  await page.waitFor('typeof window.runProbe==="function"','FARGAN probe readiness',10000)
  return page
}
const compare=(got,wanted)=>{
  if(got.length!==wanted.length)throw Error('Length mismatch')
  let error=0,power=0,max=0
  for(let i=0;i<got.length;i++){const d=got[i]-wanted[i];error+=d*d;power+=wanted[i]*wanted[i];max=Math.max(max,Math.abs(d))}
  return {relative_rms:Math.sqrt(error/Math.max(power,1e-24)),absolute_rms:Math.sqrt(error/got.length),max_abs:max}
}
try{
  let page=await pageFor()
  for(const [key,c] of Object.entries(inputs.inputs))for(const name of ['fargan','spectral']){
    const bytes=readFileSync(join(out,`${key}-${name}.f32`))
    if(hash(bytes)!==c.native[name])throw Error('Stale native output')
    const wanted=new Float32Array(bytes.buffer,bytes.byteOffset,bytes.length/4)
    const a=await page.eval(`window.runProbe(${JSON.stringify({...c,name,packet:960})})`)
    const b=await page.eval(`window.runProbe(${JSON.stringify({...c,name,packet:480})})`)
    const parity=compare(a.pcm,wanted),partition=compare(a.pcm,b.pcm)
    parity.bounds={relative_rms:.001,max_abs:.01}
    parity.pass=parity.relative_rms<=parity.bounds.relative_rms&&parity.max_abs<=parity.bounds.max_abs
    if(partition.max_abs!==0)throw Error('Browser output depends on packet partition')
    writeFileSync(join(out,`${key}-${name}-browser.f32`),Buffer.from(Float32Array.from(a.pcm).buffer))
    report.cases.push({key,name,stats:a.stats,parity,partition,output_sha256:hash(Buffer.from(Float32Array.from(a.pcm).buffer))})
    console.log(`${key}/${name}: relative RMS ${parity.relative_rms.toExponential(3)}, max ${parity.max_abs.toExponential(3)}, partition ${partition.max_abs}`)
  }
  report.failure_cleanup_pass=await page.eval('window.checkWorkerFailure()')
  report.stop_cleanup_pass=await page.eval(`(async()=>{
    const promise=window.runProbe(${JSON.stringify({...inputs.inputs.mid_voice__fuller,name:'fargan',seconds:60})})
    const result=promise.then(()=>false,e=>e.message==='Probe stopped')
    await new Promise(resolve=>setTimeout(resolve,100));window.stopProbe()
    return await result&&window.probeWorkers===0
  })()`)
  if(!report.failure_cleanup_pass||!report.stop_cleanup_pass)throw Error('Worker lifecycle check failed')
  await browser.close();browser=null
  const seconds=Number(process.env.FARGAN_PROBE_SECONDS??60)
  if(!Number.isInteger(seconds)||seconds<5||seconds>120)throw Error('Probe duration must be 5–120 seconds')
  for(const profile of ['fuller','brighter'])for(const name of ['fargan','spectral']){
    page=await pageFor();const before=rss(browser.proc.pid);let peak=before
    const sampler=setInterval(()=>{peak=Math.max(peak,rss(browser.proc.pid))},500)
    try{
      const {stats}=await page.eval(`window.runProbe(${JSON.stringify({...inputs.inputs['mid_voice__'+profile],name,seconds})})`)
      const sorted=stats.compute_ms.toSorted((a,b)=>a-b)
      stats.compute_summary={mean:sorted.reduce((a,b)=>a+b,0)/sorted.length,p95:sorted[Math.floor(sorted.length*.95)],max:sorted.at(-1)}
      delete stats.compute_ms
      report.paced.push({name,profile,seconds,stats,chrome_tree_before_mib:before,chrome_tree_peak_mib:peak,chrome_tree_delta_mib:peak-before})
      console.log(`${name}/${profile}: ${JSON.stringify(stats.compute_summary)}, starvation ${stats.starved_samples}, required availability ${stats.required_playout_ms.toFixed(1)} ms`)
    }finally{clearInterval(sampler);await browser.close();browser=null}
  }
  report.numerical_parity_pass=report.cases.every(c=>c.parity.pass)
  report.browser_listening_required=!report.numerical_parity_pass
  report.worker_pacing_pass=report.paced.every(({stats:s})=>s.starved_samples===0&&s.required_playout_ms<=s.prefill_ms&&s.producer_missed_periods===0&&s.playout_missed_periods===0)
  report.browser_listening_status='pending'
  report.device_qualified=false
  report.complete=true // Execution completed; this is NOT a conformance/quality verdict.
}finally{
  if(browser)await browser.close()
  await new Promise(resolve=>server.close(resolve))
  writeFileSync(join(root,'tools/voice-fargan/results/browser.json'),JSON.stringify(report,null,2)+'\n')
}
