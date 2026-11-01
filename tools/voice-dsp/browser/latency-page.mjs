const NativeWorker=window.Worker
window.probeJitter=0
window.Worker=class extends NativeWorker{
  constructor(url,options){
    super(String(url).endsWith('dsp_worker.js')?url+'?jitter='+window.probeJitter:url,options)
  }
}

// Synthetic looped fixture; the output is connected only to muted test Chrome.
window.pacedLatency=async function(prefillSamples,seconds){
  const context=new AudioContext({sampleRate:48000}),rows=[],abort=new AbortController()
  let node,worker,source,timer,settled=false,coreDelaySamples=null,memory=null
  const close=async()=>{
    abort.abort()
    try{node?.port.postMessage({type:'stop'});source?.stop();source?.disconnect();node?.disconnect()}catch{}
    worker?.terminate()
    if(context.state==='closed')return
    let deadline
    try{
      await Promise.race([context.close(),new Promise((_,reject)=>{deadline=setTimeout(()=>reject(Error('AudioContext cleanup deadline')),5000)})])
    }finally{clearTimeout(deadline)}
  }
  try{
    return await new Promise((resolve,reject)=>{
      const finish=async error=>{
        if(settled)return;settled=true;clearTimeout(timer)
        try{await close();if(error)reject(error);else resolve({rows,coreDelaySamples,memory,closed:context.state==='closed'})}catch(e){reject(e)}
      }
      timer=setTimeout(()=>void finish(Error('Browser latency deadline')),seconds*1000+20000)
      ;(async()=>{
        await context.resume()
        if(settled)return
        const response=await fetch('/fixture.wav',{signal:abort.signal});if(!response.ok)throw Error('Missing public fixture')
        const fixture=await context.decodeAudioData(await response.arrayBuffer())
        if(settled)return
        await context.audioWorklet.addModule('/assets/js/voice_lab/dsp_bridge.js')
        if(settled)return
        node=new AudioWorkletNode(context,'randos-lab-dsp-bridge',{numberOfInputs:1,numberOfOutputs:1,outputChannelCount:[1],channelCount:1,channelCountMode:'explicit',processorOptions:{engine:'spectral',prefillSamples}})
        worker=new Worker('/assets/js/voice_lab/dsp_worker.js',{type:'module'})
        const channel=new MessageChannel();node.port.postMessage({type:'link',port:channel.port1},[channel.port1])
        node.onprocessorerror=()=>void finish(Error('Worklet failed'))
        worker.onerror=e=>void finish(Error(e.message))
        node.port.onmessage=({data})=>{
          if(data.type==='fault')void finish(Error(data.message))
          if(data.type==='stats'){
            rows.push(data)
            if(data.delaySamples!==null&&data.playedSamples!==data.clockFrames-data.delaySamples)return void finish(Error('Non-contiguous playout'))
            if(data.clockFrames>=48000*seconds)void finish()
          }
        }
        worker.onmessage=({data})=>{
          if(data.type==='fault')void finish(Error(data.message))
          if(data.type==='ready'){
            coreDelaySamples=data.adapterDelaySamples;memory=data.memory
            source=context.createBufferSource();source.buffer=fixture;source.loop=true
            node.port.postMessage({type:'start',modified:true});source.connect(node);node.connect(context.destination);source.start(context.currentTime+.05)
          }
        }
        worker.postMessage({type:'init',engine:'spectral',pitch:-1,scale:.8,port:channel.port2},[channel.port2])
      })().catch(error=>void finish(error))
    })
  }finally{clearTimeout(timer);if(context.state!=='closed')await close()}
}
