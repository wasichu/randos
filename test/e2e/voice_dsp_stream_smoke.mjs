// Actual 128-frame AudioWorklet capture/playout against an independent offline
// Worker render of the exact captured fixture PCM. No microphone or uploads.
import assert from 'node:assert/strict'
import {streamFixture} from './dsp_stream_fixture.mjs'
import {validateWorldRealtimeFault} from './dsp_stream_diagnostics.mjs'
import {Browser, BASE_URL} from './cdp.mjs'
const browser=await Browser.launch()
try {
 const page=await browser.newPage('dsp-stream')
 await page.open(`${BASE_URL}/dev/voice-lab`); await page.labView('listen')
 await page.waitFor(`document.getElementById('voice-lab-status')?.dataset.state==='rendered'`,'lab ready',30000)
 const checkPcm=result=>{
  assert(result.delaySamples>0&&result.delaySamples<48000,'bounded startup samples')
  assert.equal(result.renderedFrames,result.count+result.delaySamples,'all callback samples including complete tail')
  assert(result.relativeRms<=.001&&result.maxAbs<=.01,'stream PCM matches offline reference')
  assert.equal(result.prefix,0,'startup is silent, with no original fallback')
  assert(result.tail>1e-8,'ending audio retained')
  assert(result.maxPending<=15360&&result.maxBuffered<=30720,'queues remain bounded')
 }
 const spectral=await streamFixture(page)
 checkPcm(spectral)
 console.log(`spectral: strict 48 kHz worklet stream passed; buffered delay ${(spectral.delaySamples/48).toFixed(1)} ms; parity ${spectral.relativeRms}`)
 // WORLD is a research comparison, not the shipping engine. Slow only the
 // fixture callback clock: identical sample coordinates, DSP settings, real
 // bridge and offline Worker reference, with more wall time per input block.
 // This qualifies transport/numerical conformance, never realtime performance.
 const world=await streamFixture(page,{engine:'world',contextRate:24000})
 assert.equal(world.contextRate,24000)
 checkPcm(world)
 console.log(`world: slowed-clock transport/PCM conformance passed; parity ${world.relativeRms}; no realtime claim`)
 const realtime=await streamFixture(page,{engine:'world',captureFault:true})
 if(realtime.fault){
  // Preserve the full snapshot even when a validation guard fails in CI.
  console.log('world: experimental 48 kHz terminal diagnostics',JSON.stringify(realtime.fault))
  const {mean,hopCost,classification}=validateWorldRealtimeFault(realtime.fault)
  console.log(`world: experimental 48 kHz ${classification}; completed-block mean ${mean.toFixed(1)} ms; warmup-inclusive cost ${hopCost.toFixed(1)} ms per 80 ms output hop; transport guards passed, PCM correctness passed separately`)
 }else{
  checkPcm(realtime)
  console.log(`world: experimental 48 kHz run kept up; parity ${realtime.relativeRms}`)
 }
 // A stalled engine and a starved output are separate terminal failures.
 for(const mode of ['pending','starved']){
  const fault=await page.eval(`(async()=>{
   const context=new AudioContext({sampleRate:48000});let node,source,timer;
   try{
    await context.resume();await context.audioWorklet.addModule('/assets/js/voice_lab/dsp_bridge.js');
    node=new AudioWorkletNode(context,'randos-lab-dsp-bridge',{numberOfInputs:1,numberOfOutputs:1,outputChannelCount:[1],channelCount:1,channelCountMode:'explicit'});
    const channel=new MessageChannel();let blocks=0,received=0;
    channel.port2.onmessage=({data})=>{if(data.type!=='block')return;blocks++;received+=data.pcm.length;if(${JSON.stringify(mode)}==='pending')return;
     if(blocks<=2){const pcm=new Float32Array(3840);channel.port2.postMessage({type:'output',start:(blocks-1)*3840,pcm},[pcm.buffer])}
     channel.port2.postMessage({type:'credit',received,buffer:data.pcm.buffer,computeMs:0},[data.pcm.buffer]);
    };
    node.port.postMessage({type:'link',port:channel.port1},[channel.port1]);
    const failure=new Promise((resolve,reject)=>{timer=setTimeout(()=>reject(Error('Expected terminal fault')),10000);node.port.onmessage=({data})=>{if(data.type==='fault')resolve(data.message)}});
    source=context.createConstantSource();source.offset.value=.1;source.connect(node);node.connect(context.destination);node.port.postMessage({type:'start',modified:true});source.start();
    const message=await failure;channel.port2.close();return message;
   }finally{clearTimeout(timer);source?.stop();node?.disconnect();await context.close()}
  })()`)
  assert(fault.includes(mode==='pending'?'pending input':'starved'))
  console.log(`bounded bridge: ${mode} failure is explicit`)
 }
}finally{await browser.close()}
