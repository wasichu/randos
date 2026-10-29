import {createDspAdapter} from '/adapter-core.js'
export const RATE = 48000, HOP = 3840
const append = (a,b) => {const x=new Float64Array(a.length+b.length);x.set(a);x.set(b,a.length);return x}
export async function createAdapter(name,pitch,scale,total,emit) {
  if(name==='time')return rustAdapter(pitch,total,emit)
  const factory=(await import(`/build/${name}.mjs`)).default
  return createDspAdapter({name,module:await factory(),pitch,scale,total,emit})
}
async function rustAdapter(pitch,total,emit) {
  const bytes=await (await fetch('/rust.wasm')).arrayBuffer()
  const make=async(id,params)=>{
    const {instance}=await WebAssembly.instantiate(bytes,{}),m=instance.exports
    if(!m.voice_new(id,RATE,128))throw Error('Rust initialization failed')
    params.forEach((x,i)=>m.voice_set_param(i,x))
    return {memory:()=>m.memory.buffer.byteLength,process(x){new Float32Array(m.memory.buffer,m.voice_input(),x.length).set(x);m.voice_process(x.length);return new Float32Array(m.memory.buffer,m.voice_output(),x.length).slice()}}
  }
  const mc=await make(2,[.9]),shifter=await make(1,[pitch,40])
  let skip=1022,remaining=total,pending=new Float64Array(),emitted=0
  const aligned=x=>{
    const cut=Math.min(skip,x.length);skip-=cut
    const take=Math.min(remaining,x.length-cut);remaining-=take
    pending=append(pending,x.subarray(cut,cut+take))
    while(pending.length>=128){emit(emitted,shifter.process(pending.slice(0,128)));emitted+=128;pending=pending.slice(128)}
  }
  const push=x=>{for(let i=0;i<x.length;i+=128)aligned(mc.process(x.subarray(i,i+128)))}
  return {delay:1022,memory:()=>mc.memory()+shifter.memory(),push,finish(){push(new Float64Array(1022));if(pending.length){emit(emitted,shifter.process(pending));pending=new Float64Array()}},close(){}}
}
