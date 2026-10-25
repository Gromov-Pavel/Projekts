import {test} from 'node:test'
import assert from 'node:assert/strict'
import {readFileSync} from 'node:fs'
import vm from 'node:vm'
import {identifyTimer,timerProfiles} from '../lib/timers.js'

test('scan lists unnamed devices, merges scan response, requires explicit protocol for unknown devices',()=>{
  let page,scan,saved,mode='direct',destination
  const buttons=[]
  const context={ArrayBuffer,Uint8Array,identifyTimer,timerProfiles,Page:p=>page=p,
    ble:{mstStartScan:f=>{scan=f;return true},mstStopScan:()=>{}},
    replace:({url})=>destination=url,getTransport:()=>mode,setTransport:v=>mode=v,
    getDirectTimer:()=>saved,setDirectTimer:v=>saved=v,
    label:text=>({text}),button:(text,x,y,w,h,click)=>{const b={text,click};buttons.push(b);return b},
    update:(w,t)=>w.text=t,show:(w,v)=>w.visible=v,
    applyScreenPolicy:()=>{},releaseScreen:()=>{},setTimeout:()=>1,clearTimeout:()=>{}}
  const source=readFileSync(new URL('../page/timer.js',import.meta.url),'utf8').replace(/^import .*$/gm,'')
  vm.runInNewContext(source,context);page.build();page.scan()
  scan({dev_addr:new Uint8Array([1,2,3,4,5,6]).buffer,dev_name:''})
  assert.equal(page.items.length,1);assert.match(page.items[0].name,/Без имени/)
  scan({dev_addr:new Uint8Array([1,2,3,4,5,6]).buffer,dev_name:'SP M1A2 Timer 1234'})
  assert.equal(page.items.length,1);assert.equal(page.items[0].profile,timerProfiles[0].id)
  scan({dev_addr:new Uint8Array([2,2,3,4,5,6]).buffer,dev_name:'My timer'})
  page.choose(1);assert.equal(saved,undefined);assert.equal(page.candidate.name,'My timer')
  page.choose(0);assert.equal(saved.profile,timerProfiles[0].id);assert.equal(destination,'page/index')
  page.onDestroy();const length=page.items.length;scan({dev_addr:new Uint8Array(6).buffer,dev_name:'SP M1A2'})
  assert.equal(page.items.length,length)
})
