// Test-only interpretation of the research WORLD fixture's terminal snapshot.
// Transport failures remain fatal; timing distinguishes observed completed work
// from deadline misses whose queued/in-flight cause is not measured here.
import assert from 'node:assert/strict'

export function validateWorldRealtimeFault({engine,message,diagnostics:d,wallMs}) {
  assert.equal(engine,'world')
  assert.equal(message,'DSP playback starved after starting','unexpected research failure')
  assert(d&&typeof d==='object'&&!Array.isArray(d)&&Object.values(d).every(Number.isFinite),'complete finite fault diagnostics')
  for(const key of ['clockFrames','sentSamples','acknowledgedSamples','writtenSamples','playedSamples','bufferedSamples','delaySamples','prefillSamples','pendingSamples','computeBlocks']) assert(Number.isSafeInteger(d[key])&&d[key]>=0,key)
  assert.equal(d.prefillSamples,7680)
  assert(d.delaySamples>0&&d.delaySamples<48000)
  assert.equal(d.sentSamples%3840,0)
  assert.equal(d.acknowledgedSamples%3840,0)
  assert.equal(d.writtenSamples,d.acknowledgedSamples-3840,'WORLD lookahead remains contiguous')
  assert.equal(d.writtenSamples,d.playedSamples)
  assert.equal(d.bufferedSamples,0)
  assert.equal(d.pendingSamples,d.sentSamples-d.acknowledgedSamples)
  assert(d.pendingSamples>3840&&d.pendingSamples<=15360,'bounded compute backlog')
  assert.equal(d.clockFrames,d.delaySamples+d.playedSamples,'continuous playout clock')
  assert.equal(d.sentSamples,Math.floor((d.clockFrames+128)/3840)*3840,'no missing input hops')
  assert(d.clockFrames<3840*24)
  assert.equal(d.computeBlocks,d.acknowledgedSamples/3840)
  assert(d.computeBlocks>2)
  for(const key of ['computeTotalMs','computeMaxMs']) assert(Number.isFinite(d[key])&&d[key]>=0,key)
  const mean=d.computeTotalMs/d.computeBlocks
  // The first credited WORLD block accumulates lookahead without analysis,
  // but its measured time is still in the total. Cost per output hop includes
  // that warmup; unlike the actual mean, it may exceed the largest call time.
  const hopCost=d.computeTotalMs/(d.computeBlocks-1)
  const tolerance=Math.max(1,d.computeMaxMs,mean)*1e-6
  assert(d.computeMaxMs+tolerance>=mean,'maximum covers mean completed-block time')
  assert(Number.isFinite(wallMs)&&wallMs>0&&d.computeTotalMs<=wallMs*1.1)
  assert(Math.abs(d.clockFrames/48-wallMs)<=Math.max(100,wallMs*.15),'audio and wall clocks agree')
  return {mean,hopCost,classification:hopCost>80?'compute-budget-exceeded':'deadline-miss/undetermined'}
}
