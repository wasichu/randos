import {blockReleaseMs} from './clock.mjs'
// Independent wall-clock producer; no acknowledgement-driven pacing.
window.runProbe=async function(config) {
  const input=new Float32Array(await (await fetch(`/input/${config.clip}.f32`)).arrayBuffer())
  const total=config.paced?48000*60:input.length,worker=new Worker('/worker.mjs',{type:'module'})
  const output=config.paced?null:new Float32Array(total)
  const stats={total,compute_ms:[],max_queue_samples:0,producer_late_ms:0,required_playout_ms:0,memory_start:0,memory_end:0,emitted:0,peak:0}
  let sent=0,acked=0,timer,deadline,start,readyAt,settled=false
  return await new Promise((resolve,reject)=>{
    const finish=(error)=>{if(settled)return;settled=true;clearTimeout(timer);clearTimeout(deadline);worker.terminate();if(error)reject(error);else resolve({stats,pcm:output?Array.from(output):null})}
    deadline=setTimeout(()=>finish(Error('Probe exceeded deadline')),config.paced?100000:60000)
    worker.onerror=e=>finish(Error(e.message))
    worker.onmessage=({data:d})=>{
      if(d.type==='error')return finish(Error(d.error))
      if(d.type==='ready'){readyAt=performance.now();stats.setup_ms=readyAt-start;stats.memory_start=d.memory;stats.declared_buffer_samples=d.delay;start=readyAt;produce();return}
      if(d.type==='ack'){acked=d.received;if(d.phase==='finish')stats.finish_ms=d.compute;else stats.compute_ms.push(d.compute);stats.memory_end=d.memory;return}
      if(d.type==='audio'){
        if(d.start!==stats.emitted)return finish(Error('Output position mismatch'))
        for(const v of d.pcm){if(!Number.isFinite(v))return finish(Error('Invalid audio'));stats.peak=Math.max(stats.peak,Math.abs(v))}
        stats.emitted+=d.pcm.length
        if(output)output.set(d.pcm,d.start)
        if(config.paced)stats.required_playout_ms=Math.max(stats.required_playout_ms,performance.now()-start-d.start/48)
      }
      if(d.type==='done'){stats.elapsed_ms=performance.now()-start;finish()}
    }
    function produce(){
      if(settled)return
      if(sent>=total){worker.postMessage({type:'finish'});return}
      const n=Math.min(3840,total-sent),due=blockReleaseMs(sent,n),now=performance.now()-start
      if(config.paced&&now<due){timer=setTimeout(produce,due-now);return}
      stats.producer_late_ms=Math.max(stats.producer_late_ms,Math.max(0,now-due))
      if(config.paced&&sent-acked>48000*2)return finish(Error('More than two seconds queued: overload'))
      const pcm=new Float32Array(n)
      for(let i=0;i<n;i++)pcm[i]=input[(sent+i)%input.length]
      sent+=n;stats.max_queue_samples=Math.max(stats.max_queue_samples,sent-acked)
      worker.postMessage({type:'block',pcm},[pcm.buffer])
      timer=setTimeout(produce,config.paced?Math.max(0,sent/48-(performance.now()-start)):0)
    }
    start=performance.now();worker.postMessage({type:'begin',...config,total})
  })
}
