// Timer-based Worker screen, not an AudioWorklet or device-latency measurement.
window.probeWorkers=0
window.runProbe=async function(config){
  const input=new Float32Array(await(await fetch(`/input/${config.clip}.f32`)).arrayBuffer())
  const packet=config.packet??960,total=config.seconds?48000*config.seconds:input.length
  const output=config.seconds?null:new Float32Array(total),worker=new Worker('/worker.mjs',{type:'module'})
  window.probeWorkers++
  const stats={compute_ms:[],total,emitted:0,max_pending:0,max_output_queue:0,producer_late_ms:0,playout_late_ms:0,producer_missed_periods:0,playout_missed_periods:0,starved_samples:0,required_playout_ms:0,peak:0,prefill_ms:200}
  let sent=0,acked=0,played=0,timer,playTimer,deadline,start=performance.now(),settled=false,done=false
  return await new Promise((resolve,reject)=>{
    const stop=error=>{if(settled)return;settled=true;clearTimeout(timer);clearTimeout(playTimer);clearTimeout(deadline);worker.terminate();window.probeWorkers--;if(error)reject(error);else resolve({stats,pcm:output?Array.from(output):null})}
    window.stopProbe=()=>stop(Error('Probe stopped'))
    deadline=setTimeout(()=>stop(Error('Probe deadline exceeded')),config.seconds?config.seconds*1000+30000:60000)
    worker.onerror=e=>stop(Error(e.message))
    worker.onmessage=({data:d})=>{
      if(d.type==='error')return stop(Error(d.error))
      if(d.type==='ready'){stats.setup_ms=performance.now()-start;stats.memory_start=d.memory;stats.feature_error=d.feature_error;start=performance.now();produce();if(config.seconds)play();return}
      if(d.type==='ack'){acked=d.received;stats.memory_end=d.memory;if(d.phase==='finish')stats.finish_ms=d.compute;else stats.compute_ms.push(d.compute);return}
      if(d.type==='audio'){
        if(d.start!==stats.emitted)return stop(Error('Output not contiguous'))
        for(const v of d.pcm){if(!Number.isFinite(v))return stop(Error('Nonfinite audio'));stats.peak=Math.max(stats.peak,Math.abs(v))}
        if(d.pcm.length)stats.required_playout_ms=Math.max(stats.required_playout_ms,performance.now()-start-d.start/48)
        stats.emitted+=d.pcm.length
        stats.max_output_queue=Math.max(stats.max_output_queue,stats.emitted-played)
        if(config.seconds&&stats.emitted-played>96000)return stop(Error('Output queue exceeded two seconds'))
        output?.set(d.pcm,d.start)
      }
      if(d.type==='done'){if(stats.emitted!==total)return stop(Error('Incomplete stream'));stats.elapsed_ms=performance.now()-start;done=true;if(!config.seconds||played===total)stop()}
    }
    function produce(){
      if(settled)return
      if(sent===total){worker.postMessage({type:'finish'});return}
      const due=(sent+packet)/48,now=performance.now()-start
      if(config.seconds&&now<due){timer=setTimeout(produce,due-now);return}
      if(config.seconds){const late=Math.max(0,now-due);stats.producer_late_ms=Math.max(stats.producer_late_ms,late);if(late>=packet/48)stats.producer_missed_periods++}
      if(sent-acked>=96000)return stop(Error('Input queue exceeded two seconds'))
      const pcm=new Float32Array(packet)
      for(let i=0;i<packet;i++)pcm[i]=input[(sent+i)%input.length]
      sent+=packet;stats.max_pending=Math.max(stats.max_pending,sent-acked)
      worker.postMessage({type:'block',pcm},[pcm.buffer])
      timer=setTimeout(produce,0)
    }
    function play(){
      if(settled||played>=total)return
      const due=200+played/48,now=performance.now()-start
      if(now<due){playTimer=setTimeout(play,due-now);return}
      const late=Math.max(0,now-due);stats.playout_late_ms=Math.max(stats.playout_late_ms,late);if(late>=20)stats.playout_missed_periods++
      stats.starved_samples+=Math.max(0,Math.min(960,total-played)-Math.max(0,stats.emitted-played))
      played+=Math.min(960,total-played);if(played===total&&done)stop();else playTimer=setTimeout(play,0)
    }
    worker.postMessage({type:'begin',...config,total})
  })
}

window.checkWorkerFailure=()=>new Promise((resolve,reject)=>{
  const worker=new Worker('/worker.mjs',{type:'module'});let failures=0
  const timeout=setTimeout(()=>finish(Error('Failure cleanup deadline')),10000)
  const finish=error=>{clearTimeout(timeout);worker.terminate();if(error)reject(error);else resolve(true)}
  worker.onerror=e=>finish(Error(e.message))
  worker.onmessage=({data:d})=>{
    if(d.type==='ready'){const pcm=new Float32Array(960);pcm[1]=NaN;worker.postMessage({type:'block',pcm},[pcm.buffer])}
    if(d.type==='audio')finish(Error('Failed capture emitted audio'))
    if(d.type==='error'){
      failures++
      if(failures===1)worker.postMessage({type:'block',pcm:new Float32Array(960)})
      else finish()
    }
  }
  worker.postMessage({type:'begin',name:'fargan',pitch:-1,scale:.8,total:960,feature_probes:[]})
})
