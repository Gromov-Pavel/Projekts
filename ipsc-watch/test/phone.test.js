import {test} from 'node:test'
import assert from 'node:assert/strict'
import {readFileSync} from 'node:fs'
import vm from 'node:vm'
import * as wire from '../lib/wire.js'

function fixture() {
  let Link, now = 10000, serial = 0
  const callbacks = {}, writes = [], timers = new Map(), reads = []
  const ble = {
    mstStartScan: cb => {callbacks.scan=cb;return true}, mstStopScan:()=>{},
    mstConnect: (address, cb) => { callbacks.connection=cb; return true },
    mstOnPrepare:cb=>{callbacks.prepare=cb},
    mstOnCharaValueArrived:cb=>{callbacks.read=cb},
    mstOnCharaNotification:cb=>{callbacks.notify=cb},
    mstOnDescWriteComplete:cb=>{callbacks.descriptor=cb},
    mstOnCharaWriteComplete:cb=>{callbacks.write=cb},
    mstBuildProfile:()=>true,
    mstReadCharacteristic:(...a)=>reads.push(a),
    mstWriteDescriptor:()=>true,
    mstWriteCharacteristic:(...a)=>writes.push(a),
    mstDisconnect:()=>{},mstDestroyProfileInstance:()=>{},mstOffAllCb:()=>{},
  }
  const source=readFileSync(new URL('../lib/phone.js',import.meta.url),'utf8')
    .replace(/^import .*$/gm,'').replace('export class PhoneLink','class PhoneLink')
  vm.runInNewContext(source+'\ncapture(PhoneLink)', {...wire,ble,
    Date:{now:()=>now},Uint8Array,ArrayBuffer,DataView,
    setInterval:cb=>{timers.set(++serial,cb);return serial},
    setTimeout:cb=>{timers.set(++serial,cb);return serial},
    clearInterval:id=>timers.delete(id),clearTimeout:id=>timers.delete(id),
    capture:C=>{Link=C}})
  const link = new Link(()=>{})
  return {link,callbacks,writes,reads,timers,advance:ms=>{now+=ms}}
}
function frame({run=7, revision=9,phase=0,count=0,total=0,split=0xffffffff,flags=48}={}) {
  const data=new ArrayBuffer(20), b=new DataView(data)
  b.setUint8(0,1);b.setUint8(1,flags|phase);b.setUint16(2,count,true)
  b.setUint32(4,run,true);b.setUint32(8,revision,true)
  b.setUint32(12,total,true);b.setUint32(16,split,true)
  return data
}
test('documented BLE callbacks carry live shots and commands; no false finish on disconnect',()=>{
  const f=fixture(),{link,callbacks}=f
  link.connect()
  callbacks.scan({service_uuid_array:[wire.SERVICE.toUpperCase()],dev_addr:new ArrayBuffer(6)})
  callbacks.connection({connected:0,connect_id:4})
  callbacks.prepare({profile:11,status:0})
  assert.equal(f.reads.length,1)
  callbacks.read({profile:11,uuid:wire.STATE,status:8})
  assert.equal(link.fresh(),false)
  callbacks.read({profile:11,uuid:wire.STATE,status:0,data:frame({run:123456,revision:0,phase:4,flags:0})})
  assert.match(link.message,/123456/)
  link.command(true);assert.equal(f.writes.length,0)
  callbacks.read({profile:11,uuid:wire.STATE,status:0,data:frame()})
  callbacks.descriptor({profile:11,chara:wire.STATE,status:0})
  assert.equal(link.fresh(),true)
  link.command(true);link.command(true)
  assert.equal(f.writes.length,1)
  assert.ok(link.pending)
  callbacks.notify({profile:11,uuid:wire.STATE,data:frame({run:8,revision:10,phase:1})})
  assert.equal(link.pending,null)
  callbacks.notify({profile:11,uuid:wire.STATE,data:frame({run:8,revision:11,phase:2,count:2,total:1640,split:390})})
  assert.equal(link.state.total,1640)
  link.command(false);assert.equal(f.writes.length,2)
  callbacks.write({profile:11,uuid:wire.COMMAND,status:0})
  assert.ok(link.pending) // GATT receipt is not a timer completion.
  callbacks.connection({connected:2,connect_id:4})
  assert.equal(link.fresh(),false);assert.equal(link.state.phase,2)
  link.command(false);assert.equal(f.writes.length,2)
  assert.equal(f.timers.size,0)
})
test('tuple callbacks, stale heartbeat, timeout and teardown reject delayed packets',()=>{
  const f=fixture(),{link,callbacks}=f
  link.connect()
  callbacks.scan({service_uuid_array:[wire.SERVICE],dev_addr:new ArrayBuffer(6)})
  callbacks.connection({connected:0,connect_id:4});callbacks.prepare(11,0)
  callbacks.read(11,wire.STATE,frame(),0)
  assert.equal(link.fresh(),true)
  f.advance(6000);link.poll()
  assert.equal(link.fresh(),false);assert.match(link.message,/старые/)
  callbacks.read(11,wire.STATE,frame(),0)
  link.command(true);f.advance(11000);link.poll()
  assert.equal(link.pending,null)
  const old = callbacks.notify
  link.close();old(11,wire.STATE,frame({revision:12,count:1,total:1250}),20)
  assert.equal(link.state.count,0);assert.equal(f.timers.size,0)
})
