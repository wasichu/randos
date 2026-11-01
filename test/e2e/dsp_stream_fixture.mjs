// Deterministic generated input through the real render callback; no microphone.
export async function streamFixture(page,{engine="spectral",prefillSamples=7680,pitch=-2,scale=.9,contextRate=48000,captureFault=false}={}) {
 if (![24000,48000].includes(contextRate)) throw Error("Unsupported fixture clock")
 return page.eval(`(async()=>{
   const engine=${JSON.stringify(engine)},prefillSamples=${prefillSamples},pitch=${pitch},scale=${scale},count=3840*24,contextRate=${contextRate},context=new AudioContext({sampleRate:contextRate}),workers=[],ports=[];
   let node,source,deadline,wholeDeadline,startedAt,cancelled=false;
   const offline=(input)=>new Promise((resolve,reject)=>{
    if(cancelled)return reject(Error("Fixture cancelled"));
    const worker=new Worker('/assets/js/voice_lab/dsp_worker.js',{type:'module'});workers.push(worker);
    const channel=new MessageChannel(),output=new Float32Array(input.length);ports.push(channel.port1);let received=0;
    worker.onerror=e=>reject(Error(e.message));worker.onmessage=({data})=>{
     if(cancelled)return;
     if(data.type==='fault')reject(Error(data.message));
     if(data.type==='ready'){
      for(let start=0;start<input.length;start+=3840){const pcm=input.slice(start,start+3840);channel.port1.postMessage({type:'block',start,pcm},[pcm.buffer])}
      channel.port1.postMessage({type:'finish',total:input.length});
     }
    };
    channel.port1.onmessage=({data})=>{
     if(data.type==='fault')reject(Error(data.message));
     if(data.type==='output'){if(data.start!==received)return reject(Error('Offline span gap'));output.set(data.pcm,data.start);received+=data.pcm.length}
     if(data.type==='end'){channel.port1.close();if(received!==input.length)return reject(Error('Offline truncation'));resolve(output)}
    };
    worker.postMessage({type:'init',engine,pitch,scale,port:channel.port2},[channel.port2]);
   });
   const run=async()=>{
    if(context.sampleRate!==contextRate)throw Error("Fixture clock mismatch");
    await context.resume();if(cancelled)throw Error("Fixture cancelled");await context.audioWorklet.addModule('/assets/js/voice_lab/dsp_bridge.js');if(cancelled)throw Error('Fixture cancelled');
    node=new AudioWorkletNode(context,'randos-lab-dsp-bridge',{numberOfInputs:1,numberOfOutputs:1,outputChannelCount:[1],channelCount:1,channelCountMode:'explicit',processorOptions:{testFrames:count,engine,prefillSamples}});
    const worker=new Worker('/assets/js/voice_lab/dsp_worker.js',{type:'module'});workers.push(worker);
    const channel=new MessageChannel();node.port.postMessage({type:'link',port:channel.port1},[channel.port1]);
    const rendered=new Promise((resolve,reject)=>{
     deadline=setTimeout(()=>reject(Error('Streaming fixture timed out')),20000);
     node.onprocessorerror=()=>reject(Error('Bridge error'));
     node.port.onmessage=({data})=>{if(data.type==='fault'){const fault={engine,message:data.message,diagnostics:data.diagnostics,wallMs:performance.now()-startedAt};const error=Error(engine+': '+data.message+' '+JSON.stringify(fault));error.dspFault=fault;reject(error)};if(data.type==='test-result')resolve(data)};
     worker.onerror=e=>reject(Error(e.message));worker.onmessage=({data})=>{
      if(cancelled)return;
      if(data.type==='fault')reject(Error(data.message));
      if(data.type==='ready'){
       const buffer=context.createBuffer(1,count,contextRate),wave=buffer.getChannelData(0);
       let phase=0;for(let i=0;i<count;i++){
        const seconds=i/48000,gate=seconds>.1&&seconds<1.75?Math.min(1,(seconds-.1)/.03,(1.75-seconds)/.05):0;
        phase+=2*Math.PI*(145+18*Math.sin(seconds*4))/48000;wave[i]=gate*(.18*Math.sin(phase)+.055*Math.sin(phase*2)+.025*Math.sin(phase*3));
       }
       source=context.createBufferSource();source.buffer=buffer;
       startedAt=performance.now();node.port.postMessage({type:'start',modified:true});source.connect(node);node.connect(context.destination);source.start(context.currentTime+.05);
      }
     };
    });
    worker.postMessage({type:'init',engine,pitch,scale,port:channel.port2},[channel.port2]);
    const actual=await rendered;clearTimeout(deadline);if(cancelled)throw Error("Fixture cancelled");
    source.disconnect();node.disconnect();await context.close();if(cancelled)throw Error("Fixture cancelled");
    const reference=await Promise.race([offline(actual.input),new Promise((_,reject)=>{deadline=setTimeout(()=>reject(Error('Offline reference timed out')),15000)})]);clearTimeout(deadline);
    const wet=actual.output.subarray(actual.delaySamples,actual.delaySamples+count);
    let error=0,power=0,max=0,prefix=0,tail=0;
    for(let i=0;i<count;i++){const d=wet[i]-reference[i];error+=d*d;power+=reference[i]*reference[i];max=Math.max(max,Math.abs(d));if(i>count-12000)tail+=wet[i]*wet[i]}
    for(let i=0;i<actual.delaySamples;i++)prefix=Math.max(prefix,Math.abs(actual.output[i]));
    return {contextRate,count,renderedFrames:actual.renderedFrames,delaySamples:actual.delaySamples,maxPending:actual.maxPendingSamples,maxBuffered:actual.maxBufferedSamples,minBuffered:actual.minBufferedSamples,relativeRms:Math.sqrt(error/Math.max(power,1e-24)),maxAbs:max,prefix,tail};
   };
   try{
    return await Promise.race([run(),new Promise((_,reject)=>{wholeDeadline=setTimeout(()=>reject(Error('Whole stream fixture timed out')),35000)})]);
   }catch(error){
    if(${captureFault}&&error.dspFault)return {fault:error.dspFault};
    throw error;
   }finally{
    cancelled=true;clearTimeout(deadline);clearTimeout(wholeDeadline);
    try{source?.disconnect()}catch{}try{node?.disconnect()}catch{}
    for(const port of ports)port.close();for(const worker of workers)worker.terminate();
    let closing;try{closing=context.state==='closed'?Promise.resolve():context.close().catch(()=>{})}catch{closing=Promise.resolve()}
    let closeTimer;try{await Promise.race([closing,new Promise(resolve=>{closeTimer=setTimeout(resolve,5000)})])}finally{clearTimeout(closeTimer)}
    if(context.state!=='closed')throw Error('Fixture AudioContext teardown did not complete');
   }
  })()`)
}
