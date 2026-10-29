// Two bounded Signalsmith experiments on a muted local browser. No microphone.
import {readFileSync,writeFileSync,mkdirSync} from 'node:fs'
import {createHash} from 'node:crypto'
import {Browser,BASE_URL} from '../../../test/e2e/cdp.mjs'
import {streamFixture} from '../../../test/e2e/dsp_stream_fixture.mjs'
const hash=path=>createHash('sha256').update(readFileSync(path)).digest('hex')
const report={completed:false,generated_at:new Date().toISOString(),engine:'spectral',batch_samples:3840,scope:'One-machine Signalsmith playback-prefill experiment. Sample-coordinate delay excludes hardware/call latency. No minute-long PCM is retained. Browser and TUI remain joint first-release requirements.',provenance:Object.fromEntries(['assets/js/voice_lab/dsp/bridge_worklet.js','assets/js/voice_lab/dsp/worker.js','assets/js/voice_lab/dsp/adapter.js','assets/js/randos/voice/dsp_adapter.js','assets/js/randos/voice/dsp_bridge.js','assets/vendor/voice_dsp/manifest.json','assets/vendor/voice_dsp/world.mjs','assets/vendor/voice_dsp/world.wasm','assets/vendor/voice_dsp/spectral.mjs','assets/vendor/voice_dsp/spectral.wasm','test/e2e/dsp_stream_fixture.mjs','dev/voice_lab/clips/mid_voice.wav','tools/voice-dsp/browser/buffering.mjs','config/config.exs'].map(path=>[path,hash(path)])),trials:{}}
const browser=await Browser.launch()
try{
 report.browser=await browser.send('Browser.getVersion')
 const page=await browser.newPage('buffering-experiment')
 await page.open(`${BASE_URL}/dev/voice-lab`)
 await page.waitFor(`document.getElementById('voice-lab-status')?.dataset.state==='rendered'`,'lab readiness',30000)
 report.executed_assets=await page.eval(`(async()=>{
  const rows={};for(const name of ['dsp_worker.js','dsp_bridge.js']){
   const response=await fetch('/assets/js/voice_lab/'+name,{cache:'no-store',signal:AbortSignal.timeout(15000)});if(!response.ok)throw Error('Missing built DSP asset');
   const bytes=await response.arrayBuffer();rows[name]={sha256:[...new Uint8Array(await crypto.subtle.digest('SHA-256',bytes))].map(x=>x.toString(16).padStart(2,'0')).join(''),bytes:bytes.byteLength};
  }return rows;
 })()`)
 for(const [name,item] of Object.entries(report.executed_assets))if(hash('priv/static/assets/js/voice_lab/'+name)!==item.sha256)throw Error('Served DSP asset differs from local build')
 for(const [name,prefillSamples] of [['baseline',7680],['short',3840]]){
  const trial={prefill_samples:prefillSamples}
  report.trials[name]=trial
  try{
   trial.fixture=await streamFixture(page,{engine:'spectral',prefillSamples})
   const f=trial.fixture
   trial.fixture_pass=f.renderedFrames===f.count+f.delaySamples&&f.prefix===0&&f.tail>1e-8&&f.relativeRms<=.001&&f.maxAbs<=.01&&f.maxPending<=15360&&f.maxBuffered<=30720
  }catch(error){trial.fixture_pass=false;trial.fixture_error=error.message}
  console.log(`${name}: exact callback fixture ${trial.fixture_pass?'passed':'failed'}`)
  console.log(`${name}: independent real-time minute, without retaining output PCM`)
  trial.sustained=await page.eval(`(async()=>{
   const context=new AudioContext({sampleRate:48000}),stats=[],abort=new AbortController();let node,worker,source,timer,finished=false,memoryStart=0,disposing;
   const dispose=()=>disposing??=(async()=>{
    abort.abort();try{node?.port.postMessage({type:'stop'})}catch{}try{source?.stop()}catch{}try{source?.disconnect()}catch{}try{node?.disconnect()}catch{}worker?.terminate();
    let closing;try{closing=context.state==='closed'?Promise.resolve():context.close().catch(()=>{})}catch{closing=Promise.resolve()}
    let closeTimer;try{await Promise.race([closing,new Promise(resolve=>{closeTimer=setTimeout(resolve,5000)})])}finally{clearTimeout(closeTimer)}
    return context.state==='closed';
   })();
   try{
    return await new Promise(resolve=>{
     const finish=async(status,error=null)=>{
      if(finished)return;finished=true;clearTimeout(timer);
      const closed=await dispose();
      resolve({status:closed?status:'fault',error:closed?error:'AudioContext teardown did not complete',stats,memory_start:memoryStart,memory_end:stats.at(-1)?.memory??null,teardown:closed});
     };
     timer=setTimeout(()=>void finish('fault','Setup/run did not complete before deadline'),80000);
     (async()=>{
      await context.resume();if(finished)return;
      const response=await fetch('/dev/voice-lab/clips/mid_voice.wav',{signal:abort.signal});if(!response.ok)throw Error('Fixture missing');
      const bytes=await response.arrayBuffer();if(finished)return;
      const buffer=await context.decodeAudioData(bytes);if(finished)return;
      await context.audioWorklet.addModule('/assets/js/voice_lab/dsp_bridge.js');if(finished)return;
      node=new AudioWorkletNode(context,'randos-lab-dsp-bridge',{numberOfInputs:1,numberOfOutputs:1,outputChannelCount:[1],channelCount:1,channelCountMode:'explicit',processorOptions:{engine:'spectral',prefillSamples:${prefillSamples}}});
      worker=new Worker('/assets/js/voice_lab/dsp_worker.js',{type:'module'});
      const channel=new MessageChannel();node.port.postMessage({type:'link',port:channel.port1},[channel.port1]);
      node.onprocessorerror=()=>void finish('fault','Audio bridge stopped');worker.onerror=e=>void finish('fault',e.message);
      node.port.onmessage=({data})=>{
       if(finished)return;
       if(data.type==='fault')void finish('fault',data.message);
       if(data.type==='stats'){
        stats.push(data);
        if(data.delaySamples!==null&&data.playedSamples!==data.clockFrames-data.delaySamples)return void finish('fault','Non-contiguous capture/playout counters');
        if(data.clockFrames>=48000*60)void finish('complete');
       }
      };
      worker.onmessage=({data})=>{
       if(finished)return;
       if(data.type==='fault')void finish('fault',data.message);
       if(data.type==='ready'){
        memoryStart=data.memory;source=context.createBufferSource();source.buffer=buffer;source.loop=true;
        node.port.postMessage({type:'start',modified:true});source.connect(node);node.connect(context.destination);source.start(context.currentTime+.05);
       }
      };
      worker.postMessage({type:'init',engine:'spectral',pitch:-2,scale:.9,port:channel.port2},[channel.port2]);
     })().catch(error=>void finish('fault',error.message));
    });
   }finally{finished=true;clearTimeout(timer);await dispose()}
  })()`)

  const s=trial.sustained,rows=s.stats
  trial.sustained_pass=s.status==='complete'&&s.teardown&&rows.at(-1)?.clockFrames>=48000*60&&rows.every(x=>x.maxPendingSamples<=15360&&x.maxBufferedSamples<=30720)
  trial.summary={status:s.status,fault:s.error,delay_ms:rows.find(x=>x.delaySamples!==null)?.delaySamples/48??null,min_output_after_quantum_ms:rows.length?Math.min(...rows.map(x=>x.minBufferedSamples))/48:null,max_output_ms:rows.length?Math.max(...rows.map(x=>x.maxBufferedSamples))/48:null,max_pending_input_ms:rows.length?Math.max(...rows.map(x=>x.maxPendingSamples))/48:null,memory_start:s.memory_start,memory_end:s.memory_end}
  console.log(`${name}: ${s.status}; ${JSON.stringify(trial.summary)}`)
 }
 for(const [name,item] of Object.entries(report.executed_assets))if(hash('priv/static/assets/js/voice_lab/'+name)!==item.sha256)throw Error('DSP build changed during measurement')
 for(const [path,expected] of Object.entries(report.provenance))if(hash(path)!==expected)throw Error('DSP source changed during measurement')
 report.completed=true
 report.short_available=Object.values(report.trials).every(t=>t.fixture_pass&&t.sustained_pass)
}finally{
 await browser.close();mkdirSync('tools/voice-dsp/results',{recursive:true});writeFileSync('tools/voice-dsp/results/buffering.json',JSON.stringify(report,null,2)+'\n')
}
