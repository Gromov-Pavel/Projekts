import { test } from 'node:test'
import assert from 'node:assert/strict'
import {decodeState, acceptState, commandPacket} from '../lib/wire.js'

const vector = () => Uint8Array.from(Buffer.from('0132020007000000090000006806000086010000', 'hex')).buffer
test('Dart wire vector yields exact total, split and shot count', () => {
  assert.deepEqual(decodeState(vector()), {run:7, revision:9, phase:2,
    phone:true, control:true, failed:false, count:2, total:1640, split:390})
})
test('rejects corrupt frames, impossible split, old and regressive snapshots', () => {
  assert.equal(decodeState(new ArrayBuffer(19)), null)
  const wrong = vector(); new DataView(wrong).setUint8(0,2)
  assert.equal(decodeState(wrong),null)
  const s = decodeState(vector())
  for (const extra of [{revision:8},{revision:10,count:1},{revision:10,total:1000},
    {revision:10,phone:false},{revision:10,total:1641}])
    assert.equal(acceptState(s,{...s,...extra}),s)
  const finished = {...s,phase:3}
  assert.equal(acceptState(finished,{...s,revision:11}),finished)
  assert.equal(acceptState(s,{...s,revision:10,count:3,total:2000,split:360}).count,3)
})
test('commands require capability and carry expected run for phone and supported external timers', () => {
  const state = decodeState(vector())
  const stop = commandPacket(state,false,1), data = new DataView(stop)
  assert.equal(stop.byteLength,12)
  assert.equal(data.getUint8(1),2)
  assert.equal(data.getUint32(4,true),7)
  assert.equal(commandPacket(state,true,2),null)
  assert.equal(new DataView(commandPacket({...state,phone:false},false,2)).getUint8(1),2)
  assert.equal(commandPacket({...state,phone:false,control:false},false,2),null)
  assert.equal(commandPacket({...state,control:false},false,2),null)
  assert.equal(commandPacket(state,false,65536),null)
  assert.equal(new DataView(commandPacket({...state,phase:0},true,2)).getUint8(1),1)
})
