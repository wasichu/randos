import test from 'node:test'
import assert from 'node:assert/strict'
import {validateWorldRealtimeFault} from './dsp_stream_diagnostics.mjs'

function snapshot(overrides={}) {
  // Three input credits, two contiguous output hops consumed; two additional
  // input hops are queued/in flight when the 48 kHz callback starves.
  return {
    engine:'world',count:3840*24,message:'DSP playback starved after starting',wallMs:400,
    diagnostics:{
      clockFrames:19200,sentSamples:19200,acknowledgedSamples:11520,
      writtenSamples:7680,playedSamples:7680,bufferedSamples:0,
      delaySamples:11520,prefillSamples:7680,pendingSamples:7680,
      computeBlocks:3,computeTotalMs:161,computeMaxMs:80,...overrides,
    },
  }
}

test('warmup-inclusive output-hop cost may exceed every measured call',()=>{
  // Credited durations [1,80,80]: max=80, actual mean=53⅔, hop cost=80.5.
  const result=validateWorldRealtimeFault(snapshot())
  assert.equal(result.mean,161/3)
  assert.equal(result.hopCost,80.5)
  assert.equal(result.classification,'compute-budget-exceeded')
})

test('starvation with cheap completed work is an unattributed deadline miss',()=>{
  const result=validateWorldRealtimeFault(snapshot({computeTotalMs:6,computeMaxMs:3}))
  assert.equal(result.mean,2)
  assert.equal(result.hopCost,3)
  assert.equal(result.classification,'deadline-miss/undetermined')
})

test('the 80 ms budget boundary does not assert the research engine must overload',()=>{
  assert.equal(validateWorldRealtimeFault(snapshot({computeTotalMs:160})).classification,'deadline-miss/undetermined')
})

test('CI starvation after the input-length clock boundary is valid during delayed playout',()=>{
  const fault=snapshot({
    clockFrames:94592,sentSamples:92160,acknowledgedSamples:84480,
    writtenSamples:80640,playedSamples:80640,delaySamples:13952,
    computeBlocks:22,computeTotalMs:1590.899999999965,computeMaxMs:93.09999999997672,
  })
  fault.wallMs=1966.5
  assert.equal(validateWorldRealtimeFault(fault).classification,'deadline-miss/undetermined')
  // Later in the tail no more input hops are released, even as the clock runs.
  fault.diagnostics.clockFrames=96000
  fault.diagnostics.delaySamples=15360
  fault.wallMs=2000
  validateWorldRealtimeFault(fault)
  fault.diagnostics.sentSamples+=3840
  fault.diagnostics.pendingSamples+=3840
  assert.throws(()=>validateWorldRealtimeFault(fault),/no missing input hops/)
})

test('invalid fixture lengths and input beyond the fixture remain fatal',()=>{
  for(const count of [undefined,NaN,0,-3840,92161,483840]) {
    assert.throws(()=>validateWorldRealtimeFault({...snapshot(),count}),/bounded fixture input/)
  }
  assert.throws(()=>validateWorldRealtimeFault({...snapshot(),count:7680}),/no missing input hops/)
})

test('unexpected engine errors and invalid output still fail',()=>{
  for(const message of ['Invalid DSP output','DSP cannot keep up: pending input limit exceeded','Missing audio or output buffer overflow','Invalid DSP credit']) {
    assert.throws(()=>validateWorldRealtimeFault({...snapshot(),message}),/unexpected research failure/)
  }
  assert.throws(()=>validateWorldRealtimeFault({...snapshot(),engine:'spectral'}))
})

test('missing and nonfinite diagnostics remain fatal',()=>{
  assert.throws(()=>validateWorldRealtimeFault({...snapshot(),diagnostics:undefined}),/complete finite fault diagnostics/)
  for(const key of Object.keys(snapshot().diagnostics)) {
    const fault=snapshot();delete fault.diagnostics[key]
    assert.throws(()=>validateWorldRealtimeFault(fault),`missing ${key} must fail`)
    assert.throws(()=>validateWorldRealtimeFault(snapshot({[key]:NaN})),`nonfinite ${key} must fail`)
  }
})

test('output gaps, overflow, clock mismatch and missing input remain fatal',()=>{
  for(const overrides of [
    {writtenSamples:7808},
    {playedSamples:7808},
    {bufferedSamples:128},
    {pendingSamples:19200},
    {clockFrames:19328},
    {prefillSamples:3840},
    {computeBlocks:4},
    {computeTotalMs:240,computeMaxMs:20},
    {computeTotalMs:-1},
    {computeMaxMs:-1},
  ]) assert.throws(()=>validateWorldRealtimeFault(snapshot(overrides)),JSON.stringify(overrides))
  // Keep the backlog bounded and contiguous but omit one released input hop.
  assert.throws(()=>validateWorldRealtimeFault(snapshot({delaySamples:15360,clockFrames:23040})),/no missing input hops/)
  assert.throws(()=>validateWorldRealtimeFault(snapshot({delaySamples:26880,clockFrames:34560,sentSamples:34560,pendingSamples:23040})),/bounded compute backlog/)
  assert.throws(()=>validateWorldRealtimeFault({...snapshot(),wallMs:1000}),/audio and wall clocks agree/)
  assert.throws(()=>validateWorldRealtimeFault({...snapshot(),wallMs:0}))
})
