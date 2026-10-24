import {test} from 'node:test'
import assert from 'node:assert/strict'
import {readFileSync} from 'node:fs'
import vm from 'node:vm'

test('Side Service forwards only to phone loopback and reports offline errors',async()=>{
  let side, options, fail=false
  const saved = new Map()
  const source=readFileSync(new URL('../app-side/index.js',import.meta.url),'utf8').replace(/^import .*$/gm,'')
  vm.runInNewContext(source,{settingsLib:{getItem:k=>saved.get(k),setItem:(k,v)=>saved.set(k,v)},BaseSideService:x=>x,AppSideService:x=>{side=x},fetch:async o=>{
    options=o;if(fail)throw new Error('offline');return {body:JSON.stringify({accepted:true})}
  }})
  const request=req=>new Promise((resolve,reject)=>side.onRequest(req,(error,data)=>error?reject(error):resolve(data)))
  let value=await request({method:'IPSC_STATE'})
  assert.equal(value.accepted,true);assert.equal(options.url,'http://127.0.0.1:19373/v1/state')
  assert.match(options.headers['X-IPSC-Client'],/^[0-9a-f]{32}$/)
  assert.equal(options.headers['X-IPSC-Bridge'],'1')
  await request({method:'IPSC_COMMAND',params:{session:'a'.repeat(32),packet:Array(12).fill(0)}})
  assert.equal(options.headers['X-IPSC-Session'],'a'.repeat(32));assert.equal(options.method,'POST');assert.equal(JSON.parse(options.body).packet.length,12)
  value=await request({method:'OTHER'});assert.match(value.error,/Неизвестный/)
  fail=true;value=await request({method:'IPSC_STATE'});assert.match(value.error,/Включите/)
})

test('pair key survives service reload, is sent only to loopback and never forwarded to watch', async () => {
  const saved = new Map(), sent = []
  const source = readFileSync(new URL('../app-side/index.js',import.meta.url),'utf8').replace(/^import .*$/gm,'')
  let response = {session:'a'.repeat(32),packet:Array(20).fill(0),trust:'b'.repeat(64)}
  function fixture() {
    let side
    vm.runInNewContext(source,{BaseSideService:x=>x,AppSideService:x=>{side=x},
      settingsLib:{getItem:k=>saved.get(k),setItem:(k,v)=>saved.set(k,v)},
      fetch:async o=>{sent.push(o);return {body:JSON.stringify(response)}}})
    return req=>new Promise(resolve=>side.onRequest(req,(_,v)=>resolve(v)))
  }
  const first = fixture()
  const packet = await first({method:'IPSC_STATE'})
  assert.equal(packet.trust,undefined)
  assert.equal(sent[0].headers['X-IPSC-Trust'],undefined)
  const client = sent[0].headers['X-IPSC-Client']
  response = {accepted:true}
  const reloaded = fixture()
  await reloaded({method:'IPSC_COMMAND',params:{session:'a'.repeat(32),packet:Array(12).fill(0)}})
  assert.equal(sent[1].headers['X-IPSC-Client'],client)
  assert.equal(sent[1].headers['X-IPSC-Trust'],'b'.repeat(64))
  assert.equal(sent[1].url,'http://127.0.0.1:19373/v1/command')
})
