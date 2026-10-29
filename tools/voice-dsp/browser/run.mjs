// Offline same-origin Worker feasibility screen. Chrome is muted and pipe-owned.
import {execFileSync} from 'node:child_process'
import {arch,cpus,platform,release,totalmem} from 'node:os'
import {createServer} from 'node:http'
import {readFileSync,writeFileSync,mkdirSync} from 'node:fs'
import {resolve,join} from 'node:path'
import {createHash} from 'node:crypto'
import {gzipSync,brotliCompressSync} from 'node:zlib'
import {Browser} from '../../../test/e2e/cdp.mjs'
const root=resolve('.'),here=join(root,'tools/voice-dsp/browser'),out=join(root,'tmp/voice-dsp/browser')
const mode=process.argv.includes('--native-cadence')?'native_cadence':process.argv.includes('--gentle')?'gentle':process.argv.includes('--engines')?'engines':process.argv.includes('--round')?'round':'baseline'
const configs={
 native_cadence:{output:'native-cadence-output',input:'native-cadence-inputs.json',native:'native-cadence-reference',build:'native-cadence-build.json',report:'native-cadence-browser.json',names:['spectral'],experiment:'native_cadence_1'},
 gentle:{output:'gentle-output',input:'gentle-inputs.json',native:'gentle-native',build:'gentle-native-build.json',report:'gentle-pitch-probe.json',names:['spectral'],experiment:'gentle_pitch_1'},
 baseline:{input:'inputs.json',native:'native',build:'native-build.json',report:'browser-probe.json',names:['world','spectral','time'],experiment:'three_adapters',paced:true},
 round:{input:'round-inputs.json',native:'round-native',build:'round-native-build.json',report:'masking-round-probe.json',names:['spectral'],experiment:'signalsmith_strength_1'},
 engines:{output:'engine-output',input:'engine-inputs.json',native:'engine-native',build:'engine-native-build.json',report:'engine-comparison-probe.json',names:['world','spectral'],experiment:'engine_comparison_1'},
}
const config=configs[mode],round=mode!=='baseline'
const inputs=JSON.parse(readFileSync(join(out,config.input))),checks=round?{}:JSON.parse(readFileSync(join(out,'checks.json'))),names=config.names
const nativeFolder=config.native,outputFolder=join(out,config.output??'.')
mkdirSync(outputFolder,{recursive:true})
const report={generated_at:new Date().toISOString(),experiment:config.experiment,scope:'Single-threaded WASM in a dedicated Worker; call and device delays unmeasured. Preprocessed 48 kHz input, offline listening levels.',inputs,assets:{},cases:[],checks:[],paced:[]}

function rss(pid){
  const rows=execFileSync('ps',['-axo','pid=,ppid=,rss='],{encoding:'utf8'}).trim().split('\n').map(x=>x.trim().split(/\s+/).map(Number));const included=new Set([pid]);let changed=true;while(changed){changed=false;for(const [id,parent] of rows)if(included.has(parent)&&!included.has(id)){included.add(id);changed=true}}return rows.filter(x=>included.has(x[0])).reduce((s,x)=>s+x[2]/1024,0)
}
const hash=x=>createHash('sha256').update(x).digest('hex')
const paths=new Map([['/','HTML'],...['page.mjs','worker.mjs','adapters.mjs','clock.mjs'].map(x=>['/'+x,join(here,x)]),['/adapter-core.js',join(root,'assets/js/randos/voice/dsp_adapter.js')],['/rust.wasm',join(root,'assets/js/randos/voice/randos_voice.wasm')]])
for(const name of ['world','spectral'])for(const ext of ['mjs','wasm'])paths.set(`/build/${name}.${ext}`,join(out,`${name}.${ext}`))
for(const clip of Object.keys({...inputs,...checks}))paths.set(`/input/${clip}.f32`,join(out,'input',`${inputs[clip]?.input_key??clip}.f32`))
for(const [url,path] of paths)if(url.endsWith('.wasm')||url.startsWith('/build/')){const b=readFileSync(path);report.assets[url]={bytes:b.length,gzip_bytes:gzipSync(b).length,brotli_bytes:brotliCompressSync(b).length,sha256:hash(b)}}
report.host={arch:arch(),platform:platform(),os_release:release(),cpu:cpus()[0]?.model,logical_cpus:cpus().length,physical_memory_bytes:totalmem(),node:process.version}
report.native_build=JSON.parse(readFileSync(join(out,config.build)))
for(const [clip,c] of Object.entries({...inputs,...checks})){
 if(hash(readFileSync(join(out,'input',`${inputs[clip]?.input_key??clip}.f32`)))!==c.input_sha256)throw Error('Stale input bytes')
 for(const name of names)if(hash(readFileSync(join(out,nativeFolder,`${clip}-${name}.f32`)))!==c.native_sha256[name])throw Error('Stale native reference')
}
report.adapter_core_sha256=hash(readFileSync(join(root,'assets/js/randos/voice/dsp_adapter.js')))
report.provenance=Object.fromEntries(['adapters.mjs','worker.mjs','clock.mjs','page.mjs','world.cpp','spectral.cpp','prepare.py','build.py','run.mjs','round.py','engines.py','gentle.py','sources.json'].map(x=>[x,hash(readFileSync(join(here,x)))]))
const server=createServer((req,res)=>{
  const path=paths.get(req.url)
  if(!path){res.writeHead(404).end();return}
  res.setHeader('Content-Type',path==='HTML'?'text/html':(path.endsWith('.mjs')||path.endsWith('.js'))?'text/javascript':path.endsWith('.wasm')?'application/wasm':'application/octet-stream')
  res.end(path==='HTML'?'<!doctype html><title>DSP Worker probe</title><script type="module" src="/page.mjs"></script>':readFileSync(path))
})
await new Promise(resolve=>server.listen(0,'127.0.0.1',resolve))
let browser
try {
  browser=await Browser.launch()
  report.browser=await browser.send('Browser.getVersion')
  const page=await browser.newPage('dsp-worker-probe')
  await page.send('Page.navigate',{url:`http://127.0.0.1:${server.address().port}/`})
  await page.waitFor('typeof window.runProbe==="function"','probe readiness',10000)
  for(const [clip,config] of Object.entries({...inputs,...checks}))for(const name of names){
    const {stats,pcm}=await page.eval(`window.runProbe(${JSON.stringify({...config,clip,name,paced:false})})`)
    const expectedBytes=readFileSync(join(out,nativeFolder,`${clip}-${name}.f32`))
    const expected=new Float32Array(expectedBytes.buffer,expectedBytes.byteOffset,expectedBytes.length/4)
    if(expected.length!==pcm.length)throw Error('Output length mismatch')
    let error=0,power=0,max=0
    for(let i=0;i<pcm.length;i++){const delta=pcm[i]-expected[i];error+=delta*delta;power+=expected[i]*expected[i];max=Math.max(max,Math.abs(delta))}
    const relative_rms=Math.sqrt(error/Math.max(power,1e-24)),pass=relative_rms<=.001&&max<=.01
    const results=clip.startsWith("check_")?report.checks:report.cases
    results.push({clip,name,stats,output_sha256:hash(Buffer.from(Float32Array.from(pcm).buffer)),parity:{relative_rms,absolute_rms:Math.sqrt(error/pcm.length),max_abs:max,pass}})
    console.log(`${clip}/${name}: relative RMS ${relative_rms.toExponential(2)}, max ${max.toExponential(2)}`)
    if(!pass&&!clip.startsWith('check_'))throw Error(`Native/WASM speech/tone parity failed: ${clip}/${name}`)
    writeFileSync(join(outputFolder,`${clip}-${name}.f32`),Buffer.from(Float32Array.from(pcm).buffer))
  }
  if(!round)for(const name of names){
    const rssBefore=rss(browser.proc.pid)
    const clip='mid_voice',config={...inputs[clip],clip,name,paced:true}
    console.log(`Independent-clock minute: ${name}`)
    let rssPeak=rssBefore
    const sampler=setInterval(()=>{rssPeak=Math.max(rssPeak,rss(browser.proc.pid))},500)
    let stats
    try{({stats}=await page.eval(`window.runProbe(${JSON.stringify(config)})`))}finally{clearInterval(sampler)}
    stats.chrome_tree_peak_rss_mib=rssPeak
    stats.chrome_tree_peak_delta_mib=rssPeak-rssBefore
    report.paced.push({name,clip,stats,rss_before_mib:rssBefore,rss_after_worker_terminated_mib:rss(browser.proc.pid)})
    console.log(`${name}: required output playout ${stats.required_playout_ms.toFixed(1)} ms; WASM ${(stats.memory_end/1048576).toFixed(1)} MiB`)
  }
  report.speech_tone_parity_pass=report.cases.every(x=>x.parity.pass)
  report.boundary_parity_pass=round?null:report.checks.every(x=>x.parity.pass)
  report.complete=true
}finally{
  if(browser)await browser.close()
  await new Promise(resolve=>server.close(resolve))
  mkdirSync(join(here,'../results'),{recursive:true})
  writeFileSync(join(here,'../results/'+config.report),JSON.stringify(report,null,2)+'\n')
}
