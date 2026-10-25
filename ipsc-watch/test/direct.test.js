import {test} from 'node:test'
import assert from 'node:assert/strict'
import {readFileSync} from 'node:fs'
import vm from 'node:vm'
import {TimerDecoder,timerProfiles,controlPacket,identifyTimer} from '../lib/timers.js'

const start=[248,249,52,3,249,248], stop=[248,249,24,3,249,248]
const shot=[248,249,54,0,4,36,2,12,249,248]
const vectors=JSON.parse(readFileSync(new URL('../../fixtures/timer-protocol-vectors.json',import.meta.url),'utf8')).vectors
for(const v of vectors) test('shared protocol vector: '+v.id,()=>{
  const d=new TimerDecoder(v.id), events=v.frames.flatMap(frame=>d.add(frame))
  assert.deepEqual(events.map(e=>e.kind),['start','shot','stop'])
  assert.equal(events[1].time,v.expectedTimeMs)
  assert.deepEqual(d.add(v.frames[1]),[])
  assert.deepEqual(Array.from(controlPacket(v.id,true)),v.start)
  assert.deepEqual(Array.from(controlPacket(v.id,false)),v.stop)
})
test('ProTimer JSON handles every fragmentation boundary, quoted braces and malformed fields',()=>{
  const encode=s=>Array.from(s,c=>c.charCodeAt(0))
  const bytes=encode('{"t":"string-started","start":9,"note":"}\\\"{"}{"t":"shot","start":9,"index":0,"timeInMs":1641}')
  for(let cut=1;cut<bytes.length;cut++) {
    const d=new TimerDecoder('protimer-v2'), events=[...d.add(bytes.slice(0,cut)),...d.add(bytes.slice(cut))]
    assert.deepEqual(events.map(e=>e.kind),['start','shot']);assert.equal(events[1].time,1641)
  }
  const d=new TimerDecoder('protimer-v2')
  assert.deepEqual(d.add(encode('{"t":"shot","start":null,"index":0,"timeInMs":4}')),[])
  assert.deepEqual(d.add(encode('{"t":"string-started","start":"9"}')),[])
  d.add(encode('{"t":"string-started","start":9}'))
  assert.deepEqual(d.add(encode('{"t":"shot","start":9,"index":-1,"timeInMs":4}')),[])
})
test('direct Special Pie preserves fragmentation, wire indexes and ignores duplicate or stale shots',()=>{
  for(let cut=1;cut<start.length+shot.length;cut++) {
    const d=new TimerDecoder(timerProfiles[0].id), bytes=[...start,...shot]
    const events=[...d.add(bytes.slice(0,cut)),...d.add(bytes.slice(cut))]
    assert.deepEqual(events.map(e=>e.kind),['start','shot']);assert.equal(events[1].time,4360)
    assert.deepEqual(d.add(shot),[]);assert.equal(d.add(stop)[0].kind,'stop');assert.deepEqual(d.add(shot),[])
  }
  assert.deepEqual(Array.from(controlPacket(timerProfiles[0].id,true)),[248,249,52,249,248])
  assert.equal(identifyTimer('headphones',['fff0']),null)
  assert.equal(identifyTimer('SP M1A2 Timer 1234').id,timerProfiles[0].id)
})
test('SG events retain millisecond resolution and ACK cannot start a run',()=>{
  const d=new TimerDecoder('sg-v3')
  const begin=[7,0,0,0,0,9,0,30], hit=[11,4,0,0,0,9,0,0,0,0,6,105]
  assert.deepEqual(d.add([2,0,0]),[])
  assert.equal(d.add(begin)[0].kind,'start');assert.deepEqual(d.add(begin),[])
  assert.equal(d.add(hit)[0].time,1641);assert.deepEqual(d.add(hit),[])
  assert.deepEqual(d.add([11,4,0,0,0,8,0,1,0,0,8,100]),[])
  assert.equal(d.add([7,3,0,0,0,9,0,1])[0].kind,'stop')
  assert.deepEqual(d.add(hit),[]);assert.deepEqual(Array.from(controlPacket('sg-v3',false)),[1,3])
  assert.throws(()=>controlPacket('unknown',true))
})

function linkHarness() {
  const callbacks={},writes=[],disconnects=[],profiles=[],timers=new Map();let id=0,now=100
  const ble={mstOnPrepare:f=>callbacks.prepare=f,mstOnDescWriteComplete:f=>callbacks.desc=f,
    mstStartScan:f=>{callbacks.scan=f;return true},mstStopScan:()=>{},
    mstOnCharaNotification:f=>callbacks.notify=f,mstOnCharaWriteComplete:f=>callbacks.write=f,
    mstConnect:(addr,f)=>{
      // Registration before a live connection is not part of the official sample flow.
      delete callbacks.prepare;delete callbacks.desc;delete callbacks.notify;delete callbacks.write
      callbacks.connect=f;return true
    },mstBuildProfile:p=>{profiles.push(p);return true},
    mstWriteDescriptor:()=>true,mstWriteCharacteristic:(p,u,b)=>writes.push(Array.from(new Uint8Array(b))),
    mstDisconnect:id=>disconnects.push(id),mstDestroyProfileInstance:()=>{},mstOffAllCb:()=>{}}
  const context={ble,timerProfiles,TimerDecoder,controlPacket,uuid:s=>String(s).toLowerCase(),
    getDirectTimer:()=>({name:'Test',profile:timerProfiles[0].id,address:[1,2,3,4,5,6]}),
    Uint8Array,ArrayBuffer,Date:{now:()=>now},setTimeout:f=>{timers.set(++id,f);return id},clearTimeout:i=>timers.delete(i),setInterval:()=>++id,clearInterval:()=>{}}
  const source=readFileSync(new URL('../lib/direct.js',import.meta.url),'utf8').replace(/^import .*$/gm,'').replace('export class DirectTimerLink','globalThis.DirectTimerLink = class DirectTimerLink')
  vm.runInNewContext(source,context)
  const link=new context.DirectTimerLink(()=>{})
  const ready=()=>{link.connect();callbacks.scan({dev_addr:new Uint8Array([1,2,3,4,5,6]).buffer});callbacks.connect({connected:0,connect_id:7});callbacks.prepare({status:0,profile:5});callbacks.desc({profile:5,chara:timerProfiles[0].notify,status:0})}
  return {link,ready,callbacks,writes,disconnects,profiles,timers,advance:n=>{now+=n},emit:bytes=>callbacks.notify({profile:5,uuid:timerProfiles[0].notify,data:new Uint8Array(bytes).buffer})}
}
test('Zepp profile is registered after connection and uses native short service UUID',()=>{
  const h=linkHarness();h.link.connect();assert.equal(h.callbacks.prepare,undefined)
  const scanTimeout=Array.from(h.timers.values())[0]
  h.callbacks.scan({dev_addr:new Uint8Array([1,2,3,4,5,6]).buffer})
  assert.equal(h.profiles.length,0);assert.equal(h.timers.size,1)
  const connectTimeout=Array.from(h.timers.values())[0]
  h.callbacks.connect({connected:0,connect_id:7})
  assert.equal(h.profiles.length,1);assert.equal(h.profiles[0].id,7)
  assert.equal(h.profiles[0].list[0].list[0].uuid,'FFF0')
  assert.equal(h.profiles[0].list[0].list[0].list[0].uuid,timerProfiles[0].notify)
  assert.equal(typeof h.callbacks.prepare,'function')
  assert.equal(h.timers.size,1)
  scanTimeout();connectTimeout();assert.equal(h.link.stage,'profile');assert.equal(h.link.active,true)
  h.callbacks.prepare({status:0,profile:5})
  h.callbacks.desc({profile:5,chara:timerProfiles[0].notify,status:0})
  assert.equal(h.link.fresh(),true);assert.equal(h.timers.size,0)
})
test('direct mode connects only to saved address and reports actual failing stage',()=>{
  const h=linkHarness();h.link.connect()
  h.callbacks.scan({dev_addr:new Uint8Array([9,2,3,4,5,6]).buffer});assert.equal(h.callbacks.connect,undefined)
  h.callbacks.scan({dev_addr:new Uint8Array([1,2,3,4,5,6]).buffer});assert.equal(h.link.stage,'connect')
  h.callbacks.connect({connected:0,connect_id:7});assert.equal(h.link.stage,'profile')
  h.callbacks.prepare({status:0,profile:5});assert.equal(h.link.stage,'subscribe')
  const timeout=Array.from(h.timers.values())[0];timeout()
  assert.match(h.link.message,/Нет ответа подписки/);assert.doesNotMatch(h.link.message,/телефон/)
  assert.equal(h.link.fresh(),false)
})
test('direct link waits for subscription and real events; queues stop; never retries Start',()=>{
  const h=linkHarness();h.ready();assert.equal(h.link.fresh(),true)
  h.advance(60000);assert.equal(h.link.fresh(),true) // Idle timers send no heartbeat.
  h.link.command(true);assert.equal(h.link.state.phase,0);assert.equal(h.writes.length,1)
  h.link.command(false);assert.equal(h.link.stopRequested,true)
  h.emit(start);assert.equal(h.link.state.phase,2);assert.equal(h.writes.length,2)
  assert.deepEqual(h.writes[1],[248,249,24,249,248])
  h.emit(shot);assert.equal(h.link.state.total,4360);assert.equal(h.link.state.count,1)
  h.emit(stop);assert.equal(h.link.state.phase,3);assert.equal(h.link.pending,null)
  h.link.command(true);h.advance(11000);h.link.poll();assert.equal(h.writes.length,3)
  assert.equal(h.link.pending,null);assert.match(h.link.message,/Нет подтверждения/)
  h.callbacks.connect({connected:2,connect_id:7});assert.equal(h.link.fresh(),false)
  h.link.command(true);assert.equal(h.writes.length,3)
})
test('callbacks from closed connections cannot change a new direct session',()=>{
  const h=linkHarness();h.ready();const old=h.callbacks.notify
  h.link.close();old({profile:5,uuid:timerProfiles[0].notify,data:new Uint8Array(start).buffer})
  assert.equal(h.link.state.phase,0);assert.equal(h.link.active,false)
})
