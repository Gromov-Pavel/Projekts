import { test } from 'node:test'
import assert from 'node:assert/strict'
import { initialState, acceptSnapshot, metrics, keepAwake } from '../lib/session.js'
const packet = (extra = {}) => ({version:1,runId:'run1',sequence:1,phase:'running',source:'timer',shots:[1250],...extra})
test('first shot has total, count and no fabricated split', () => {
  assert.deepEqual(metrics(acceptSnapshot(initialState(),packet())),{count:1,total:1250,split:null})
})
test('full snapshot recovers skipped transmissions', () => {
  const s = acceptSnapshot(acceptSnapshot(initialState(),packet()),packet({sequence:5,shots:[1250,1640,2020]}))
  assert.deepEqual(metrics(s),{count:3,total:2020,split:380})
})
test('duplicate and old packets cannot overwrite screen', () => {
  const s = acceptSnapshot(initialState(),packet())
  assert.equal(acceptSnapshot(s,packet()),s)
  assert.equal(acceptSnapshot(s,packet({sequence:0})),s)
})
test('invalid times, ids and phases are rejected', () => {
  for (const extra of [{shots:[-1]},{shots:[1,1]},{shots:[2,1]},{shots:[NaN]}, {shots:[1.5]}, {runId:''},{phase:'oops'},{version:2}]) {
    const s=initialState(); assert.equal(acceptSnapshot(s,packet(extra)),s)
  }
})
test('different run, truncated or modified prefix and source switch rejected', () => {
  const s=acceptSnapshot(initialState(),packet())
  for(const extra of [{runId:'other'},{shots:[]},{shots:[1251]},{source:'demo'}])
    assert.equal(acceptSnapshot(s,packet({sequence:2,...extra})),s)
})
test('finish freezes result until explicit new session', () => {
  const s=acceptSnapshot(initialState(),packet({phase:'finished'}))
  assert.equal(acceptSnapshot(s,packet({sequence:2})),s)
  assert.equal(acceptSnapshot(initialState(),packet({runId:'new'})).runId,'new')
})
test('screen modes cover idle, run and finish', () => {
  for(const phase of ['idle','running','finished']) assert.equal(keepAwake('training',phase),true)
  assert.equal(keepAwake('run','running'),true)
  assert.equal(keepAwake('run','idle'),false)
  assert.equal(keepAwake('run','finished'),false)
})
