// Research only: no devices or network beyond same-origin WASM modules.
import {createDspAdapter} from '/adapter-core.js'
let engine, received=0, emitted=0, total=0, pending=new Float64Array(3840), fill=0
onmessage=async({data:d})=>{
  try {
    if(d.type==='begin') {
      if(engine)throw Error('Already initialized')
      total=d.total
      const factory=(await import(d.name==='fargan'?'/fargan-core.mjs':'/spectral.mjs')).default
      const m=await factory()
      const emit=(start,y)=>{
        if(start!==emitted||!y.every(Number.isFinite)||start+y.length>total)throw Error('Invalid output coordinates/audio')
        const pcm=Float32Array.from(y); emitted+=pcm.length
        postMessage({type:'audio',start,pcm},[pcm.buffer])
      }
      if(d.name==='fargan') {
        if(m._fg_new(d.pitch,d.scale)!==1)throw Error('FARGAN setup failed')
        let featureError=0
        for(const probe of d.feature_probes){
          new Float32Array(m.HEAPU8.buffer,m._fg_feature_input(),20).set(probe.input)
          if(m._fg_edit()!==1)throw Error('WASM feature edit failed')
          const got=new Float32Array(m.HEAPU8.buffer,m._fg_feature_output(),20)
          for(let i=0;i<20;i++)featureError=Math.max(featureError,Math.abs(got[i]-probe.expected[i]))
        }
        if(featureError>5e-5)throw Error('WASM feature edit differs from accepted Python')
        if(m._fg_new(d.pitch,d.scale)!==1)throw Error('FARGAN reset failed')
        const accept=n=>{if(n<0)throw Error(`FARGAN failed: ${n}`);emit(emitted,new Float32Array(m.HEAPU8.buffer,m._fg_output(),n).slice())}
        engine={featureError,memory:()=>m.HEAPU8.buffer.byteLength,push(x){new Float32Array(m.HEAPU8.buffer,m._fg_input(),x.length).set(x);accept(m._fg_process(x.length))},finish(){accept(m._fg_finish())},close:()=>m._fg_close()}
      } else if(d.name==='spectral') {
        const core=createDspAdapter({name:'spectral',module:m,pitch:d.pitch,scale:d.scale,total,emit})
        engine={memory:core.memory,push(x){
          for(let at=0;at<x.length;){const n=Math.min(x.length-at,3840-fill);pending.set(x.subarray(at,at+n),fill);fill+=n;at+=n;if(fill===3840){core.push(pending);fill=0}}
        },finish(){if(fill)core.push(pending.slice(0,fill));core.finish(total)},close(){pending.fill(0);core.close()}}
      } else throw Error('Unknown engine')
      postMessage({type:'ready',memory:engine.memory(),feature_error:engine.featureError??null});return
    }
    if(!engine)throw Error('Not initialized')
    const before=performance.now()
    if(d.type==='block'){
      if(!(d.pcm instanceof Float32Array)||![480,960].includes(d.pcm.length)||received+d.pcm.length>total)throw Error('Invalid input frame')
      engine.push(d.pcm);received+=d.pcm.length
    } else if(d.type==='finish'){
      if(received!==total)throw Error('Incomplete input')
      engine.finish()
      if(emitted!==total)throw Error(`Incomplete output: ${emitted}/${total}`)
    } else throw Error('Unknown request')
    postMessage({type:'ack',received,phase:d.type,compute:performance.now()-before,memory:engine.memory()})
    if(d.type==='finish'){engine.close();engine=null;postMessage({type:'done'})}
  } catch(e){engine?.close();engine=null;pending.fill(0);postMessage({type:'error',error:e.stack||String(e)})}
}
