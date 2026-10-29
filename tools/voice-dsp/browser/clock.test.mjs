import assert from 'node:assert/strict'
import {blockReleaseMs} from './clock.mjs'
assert.equal(blockReleaseMs(0,3840),80,'first block must wait for its final sample')
assert.equal(blockReleaseMs(3840,3840),160,'next block follows absolute input clock')
assert.equal(blockReleaseMs(7680,480),170,'partial final block needs no full-hop padding')
console.log('DSP producer release clock passed')
