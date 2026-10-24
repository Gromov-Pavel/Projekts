import {test} from 'node:test'
import assert from 'node:assert/strict'
import {readFileSync} from 'node:fs'
import vm from 'node:vm'

test('Side Service forwards only to phone loopback and reports offline errors',async()=>{
  let side, options, fail=false
  const source=readFileSync(new URL('../app-side/index.js',import.meta.url),'utf8').replace(/^import .*$/gm,'')
  vm.runInNewContext(source,{BaseSideService:x=>x,AppSideService:x=>{side=x},fetch:async o=>{
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
