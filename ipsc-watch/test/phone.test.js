import {test} from 'node:test'
import assert from 'node:assert/strict'
import {readFileSync} from 'node:fs'
import vm from 'node:vm'
import * as wire from '../lib/wire.js'

const flush = async () => { for(let i=0;i<10;i++) await Promise.resolve() }
function fixture() {
  let Link, now=10000, serial=0, response
  const timers=new Map(), calls=[]
  const source=readFileSync(new URL('../lib/phone.js',import.meta.url),'utf8')
    .replace(/^import .*$/gm,'').replace('export class PhoneLink','class PhoneLink')
  vm.runInNewContext(source+'\ncapture(PhoneLink)', {...wire,Date:{now:()=>now},Promise,Uint8Array,ArrayBuffer,DataView,
    setInterval:cb=>{timers.set(++serial,cb);return serial},clearInterval:id=>timers.delete(id),getDelay:()=>3,capture:C=>{Link=C}})
  const link=new Link(()=>{},req=>{calls.push(req);return typeof response==='function'?response(req):response})
  return {link,calls,timers,respond:r=>{response=r},advance:ms=>{now+=ms}}
}
function frame({run=7,revision=9,phase=0,count=0,total=0,split=0xffffffff,flags=48,session='a'.repeat(32)}={}) {
  const bytes=new ArrayBuffer(20), b=new DataView(bytes)
  b.setUint8(0,1);b.setUint8(1,flags|phase);b.setUint16(2,count,true)
  b.setUint32(4,run,true);b.setUint32(8,revision,true);b.setUint32(12,total,true);b.setUint32(16,split,true)
  return {session,packet:Array.from(new Uint8Array(bytes))}
}
test('Zepp confirmation, live shots and start/finish keep transport receipt separate from completion',async()=>{
  const f=fixture(),{link}=f
  f.respond(frame({run:123456,revision:0,phase:4,flags:0}));link.connect();await flush()
  assert.match(link.message,/123456/);link.command(true);await flush()
  assert.equal(f.calls.filter(x=>x.method==='IPSC_COMMAND').length,0)
  f.respond(frame());link.poll();await flush();assert.equal(link.fresh(),true)
  f.respond({accepted:true});link.command(true);link.command(true);await flush()
  assert.equal(f.calls.filter(x=>x.method==='IPSC_COMMAND').length,1);assert.equal(f.calls.find(x=>x.method==='IPSC_COMMAND').params.session,'a'.repeat(32));assert.ok(link.pending)
  link.receive(frame({run:8,revision:10,phase:1}));assert.equal(link.pending,null)
  link.receive(frame({run:8,revision:11,phase:2,count:2,total:1640,split:390}))
  assert.equal(link.state.total,1640);assert.equal(link.state.split,390)
  link.command(false);await flush();assert.ok(link.pending)
  link.receive(frame({run:8,revision:12,phase:3,count:2,total:1640,split:390}));assert.equal(link.pending,null)
})
test('heartbeat rejects regressive frames and new authorization session clears old approval state',async()=>{
  const f=fixture(),{link}=f;f.respond(frame());link.connect();await flush()
  f.advance(4000);link.receive(frame());assert.equal(link.fresh(),true)
  f.advance(6000);link.receive(frame({revision:8}));assert.equal(link.fresh(),false)
  link.receive(frame({run:654321,revision:0,phase:4,flags:0,session:'b'.repeat(32)}))
  assert.match(link.message,/654321/);assert.equal(link.state.control,false)
  const count=f.calls.length;link.command(true);await flush();assert.equal(f.calls.length,count)
})
test('lost Zepp, errors and late responses cannot restore a closed connection',async()=>{
  const f=fixture(),{link}=f
  f.respond(()=>Promise.reject(new Error('Zepp disconnected')));link.connect();await flush()
  assert.match(link.message,/Zepp/);assert.equal(link.fresh(),false)
  f.respond({error:'Включите связь в IPSC на телефоне'});link.poll();await flush();assert.match(link.message,/Включите/)
  let resolve;f.respond(()=>new Promise(r=>{resolve=r}));link.poll();await flush()
  link.close();resolve(frame());await flush();assert.equal(link.state,null);assert.equal(f.timers.size,0)
})

test('finish during pending start is remembered and stop retries are bounded to the same run',async()=>{
  const f=fixture(),{link}=f
  f.respond(req=>req.method==='IPSC_COMMAND'?{accepted:true}:frame())
  link.connect();await flush();link.command(true);link.command(false);await flush()
  assert.equal(link.stopRequested,true)
  assert.equal(f.calls.filter(x=>x.method==='IPSC_COMMAND').length,1)
  const running=frame({run:8,revision:10,phase:1})
  f.respond(req=>req.method==='IPSC_COMMAND'?{accepted:true}:running)
  link.receive(running);await flush()
  let stops=()=>f.calls.filter(x=>x.method==='IPSC_COMMAND'&&x.params.packet[1]===2)
  assert.equal(stops().length,1);assert.equal(new DataView(new Uint8Array(stops()[0].params.packet).buffer).getUint32(4,true),8)
  for(let i=0;i<4;i++){f.advance(1600);link.poll();await flush()}
  assert.equal(stops().length,3)
  assert.ok(link.pending)
  link.receive(frame({run:8,revision:11,phase:3}));assert.equal(link.pending,null)
  f.advance(2000);link.poll();await flush();assert.equal(stops().length,3)
})

test('a stop intent is retired if the phone has already started a different run',async()=>{
  const f=fixture(),{link}=f
  f.respond(req=>req.method==='IPSC_COMMAND'?{accepted:true}:frame({phase:2}))
  link.connect();await flush();link.command(false);await flush()
  const count=f.calls.filter(x=>x.method==='IPSC_COMMAND').length
  link.receive(frame({run:8,revision:10,phase:2}));assert.equal(link.pending,null)
  f.advance(2000);link.poll();await flush()
  assert.equal(f.calls.filter(x=>x.method==='IPSC_COMMAND').length,count)
})

test('supported external timer start and stop wait for hardware state, not transport acceptance',async()=>{
  const f=fixture(),{link}=f
  f.respond(req=>req.method==='IPSC_COMMAND'?{accepted:true}:frame({flags:32}))
  link.connect();await flush();link.command(true);await flush()
  assert.ok(link.pending);assert.equal(link.state.phase,0)
  const running=frame({run:8,revision:10,phase:2,flags:32})
  f.respond(req=>req.method==='IPSC_COMMAND'?{accepted:true}:running)
  link.receive(running);await flush();assert.equal(link.pending,null)
  link.command(false);await flush();assert.ok(link.pending)
  link.receive(frame({run:8,revision:11,phase:3,flags:32}));assert.equal(link.pending,null)
})
