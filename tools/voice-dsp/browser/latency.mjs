// Same shared production bridge/core through its capture-enabled lab subclass.
import {createServer} from 'node:http'
import {readFileSync,writeFileSync,mkdirSync} from 'node:fs'
import {resolve,join} from 'node:path'
import {createHash} from 'node:crypto'
import {Browser} from '../../../test/e2e/cdp.mjs'
import {streamFixture} from '../../../test/e2e/dsp_stream_fixture.mjs'
const root=resolve('.'),here=join(root,'tools/voice-dsp/browser')
const paths=new Map([
 ['/page.mjs',join(here,'latency-page.mjs')],['/latency-worker.mjs',join(here,'latency-worker.mjs')],
 ['/original-worker.js',join(root,'priv/static/assets/js/voice_lab/dsp_worker.js')],
 ['/assets/js/voice_lab/dsp_bridge.js',join(root,'priv/static/assets/js/voice_lab/dsp_bridge.js')],
 ['/fixture.wav',join(root,'dev/voice_lab/clips/mid_voice.wav')],
])
const hash=path=>createHash('sha256').update(readFileSync(path)).digest('hex')
const sources=[...paths.values(),join(here,'latency.mjs'),join(root,'assets/js/randos/voice/dsp_bridge.js'),join(root,'assets/js/randos/voice/dsp_adapter.js'),join(root,'assets/js/voice_lab/dsp/worker.js'),join(root,'test/e2e/dsp_stream_fixture.mjs'),join(root,'assets/vendor/voice_dsp/manifest.json')]
const report={complete:false,generated_at:new Date().toISOString(),scope:'Actual AudioWorklet callback and independent Worker; unchanged core through capture-enabled shared bridge subclass. Synthetic/public fixtures, muted Chrome, no microphone/device/AEC/network latency qualification. Compute excludes deliberate injected stalls.',provenance:Object.fromEntries(sources.map(p=>[p.slice(root.length+1),hash(p)])),finite:[],paced:[]}
const server=createServer((req,res)=>{
 const url=new URL(req.url,'http://localhost')
 let path=paths.get(url.pathname)
 if(url.pathname==='/assets/js/voice_lab/dsp_worker.js')path=join(here,'latency-worker.mjs')
 if(url.pathname==='/'){res.setHeader('Content-Type','text/html');res.end('<!doctype html><title>Signalsmith latency probe</title><script type="module" src="/page.mjs"></script>');return}
 if(!path){res.writeHead(404).end();return}
 res.setHeader('Content-Type',path.endsWith('.wav')?'audio/wav':'text/javascript');res.end(readFileSync(path))
})
await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve))
let browser
try{
 browser=await Browser.launch();report.browser=await browser.send('Browser.getVersion')
 const page=await browser.newPage('signalsmith-latency')
 await page.send('Page.navigate',{url:`http://127.0.0.1:${server.address().port}/`})
 await page.waitFor('typeof window.pacedLatency==="function"','latency harness',10000)
 for(const [pitch,scale] of [[0,.8],[-1,.8],[0,1.25],[1,1.25]])for(const prefillSamples of [7680,3840]){
  const result=await streamFixture(page,{pitch,scale,prefillSamples})
  if(result.relativeRms>.001||result.maxAbs>.01||result.prefix!==0||result.renderedFrames!==result.count+result.delaySamples)throw Error('Finite callback PCM/length mismatch')
  report.finite.push({pitch,scale,prefillSamples,result})
  console.log(`finite ${pitch}/${scale} prefill${prefillSamples}: delay ${result.delaySamples/48}ms, parity ${result.relativeRms}`)
 }
 for(const jitter of [12,45,100])for(const prefillSamples of [7680,3840]){
  await page.eval(`window.probeJitter=${jitter}`)
  const result=await streamFixture(page,{pitch:-1,scale:.8,prefillSamples,captureFault:true})
  report.finite.push({stress:true,jitter_ms:jitter,prefillSamples,result})
  console.log(`stress ${jitter}ms prefill${prefillSamples}: ${result.fault?'FAULT '+result.fault.message:'survived'}`)
 }
 await page.eval('window.probeJitter=0')
 if(!process.argv.includes('--finite-only'))for(const prefillSamples of [7680,3840]){
  console.log(`paced 60s prefill${prefillSamples}`)
  const result=await page.eval(`window.pacedLatency(${prefillSamples},60)`)
  report.paced.push({prefillSamples,result})
 }
 for(const [p,wanted]of Object.entries(report.provenance))if(hash(join(root,p))!==wanted)throw Error('Source/build changed during measurement')
 report.complete=true
}finally{
 if(browser)await browser.close()
 await new Promise(resolve=>server.close(resolve))
 mkdirSync(join(root,'tools/voice-dsp/results'),{recursive:true})
 writeFileSync(join(root,'tools/voice-dsp/results/latency-browser.json'),JSON.stringify(report,null,2)+'\n')
}
