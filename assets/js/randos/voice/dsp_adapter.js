// Research Worker adapters. Coordinates are original 48 kHz sample positions.
export const RATE = 48000, HOP = 3840
const append = (a,b) => {const x=new Float64Array(a.length+b.length);x.set(a);x.set(b,a.length);return x}
export function createDspAdapter({name, module: m, pitch, scale, total: length = null, emit}) {
  let total = length ?? Infinity
  const finishLength = received => {
    if (!Number.isSafeInteger(received) || received < 0) throw Error('A finite sample count is required to finish')
    total = received
  }
  if(m._dsp_new(pitch,scale)!==1)throw Error('DSP initialization failed')
  const call=(x,flush=false)=>{
    if(!flush)new Float64Array(m.HEAPU8.buffer,m._dsp_input(),x.length).set(x)
    const n=flush?m._dsp_flush(x.length):m._dsp_process(x.length)
    if(n<0)throw Error('DSP processing failed')
    return new Float64Array(m.HEAPU8.buffer,m._dsp_output(),n).slice()
  }
  const memory=()=>m.HEAPU8.buffer.byteLength
  if(name==='spectral') {
    const inputLatency=m._dsp_input_latency(), outputLatency=m._dsp_output_latency(), delay=inputLatency+outputLatency
    let position=-delay
    const accept=y=>{const start=Math.max(0,position),end=Math.min(total,position+y.length);if(end>start)emit(start,y.slice(start-position,end-position));position+=y.length}
    return {memory,delay, push:x=>accept(call(x)),finish(received = length){finishLength(received);accept(call(new Float64Array(inputLatency)));accept(call(new Float64Array(outputLatency),true))},close:()=>m._dsp_close()}
  }
  const past=3840, overlap=960, future=1920
  let buffer=new Float64Array(),base=0,received=0,start=0,tail=new Float64Array(overlap)
  const drain=eos=>{
    while(start<total&&(eos||received>=start+HOP+overlap+future)) {
      const window=new Float64Array(past+HOP+overlap+future)
      const low=Math.max(0,start-past),high=Math.min(received,start+HOP+overlap+future)
      window.set(buffer.subarray(low-base,high-base),low-(start-past))
      const y=call(window).slice(past,past+HOP+overlap)
      if(y.length!==HOP+overlap)throw Error('Incomplete WORLD window')
      if(start)for(let i=0;i<overlap;i++)y[i]=tail[i]*(1-i/overlap)+y[i]*i/overlap
      emit(start,y.slice(0,Math.min(HOP,total-start)))
      tail=y.slice(HOP);start+=HOP
      const discard=Math.max(0,start-past-base);buffer=buffer.slice(discard);base+=discard
    }
  }
  return {memory,delay:HOP+overlap+future,push(x){buffer=append(buffer,x);received+=x.length;drain(false)},finish(count = length){finishLength(count);drain(true)},close:()=>m._dsp_close()}
}
