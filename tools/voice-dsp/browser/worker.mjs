import {createAdapter} from './adapters.mjs'
let adapter,received=0,emitted=0,total=0
onmessage=async({data})=>{
  try {
    if(data.type==='begin') {
      total=data.total
      adapter=await createAdapter(data.name,data.pitch,data.scale,total,(start,y)=>{
        if(start!==emitted||!y.every(Number.isFinite))throw Error('Non-contiguous/nonfinite output')
        emitted+=y.length
        const pcm=Float32Array.from(y)
        postMessage({type:'audio',start,pcm},[pcm.buffer])
      })
      postMessage({type:'ready',memory:adapter.memory(),delay:adapter.delay});return
    }
    const before=performance.now()
    if(data.type==='block'){received+=data.pcm.length;adapter.push(data.pcm)}
    else if(data.type==='finish'){
      if(received!==total)throw Error('Input length mismatch')
      adapter.finish()
      if(emitted!==total)throw Error(`Incomplete drain: ${emitted}/${total}`)
    }
    postMessage({type:'ack',phase:data.type,received,compute:performance.now()-before,memory:adapter.memory()})
    if(data.type==='finish'){adapter.close();postMessage({type:'done'})}
  }catch(e){postMessage({type:'error',error:e.stack||String(e)})}
}
