import {test} from 'node:test'
import assert from 'node:assert/strict'
import {readFileSync} from 'node:fs'
import vm from 'node:vm'

test('watch delay persists zero and sixty and rejects invalid settings', () => {
  const saved = new Map()
  class LocalStorage {getItem(k){return saved.get(k)} setItem(k,v){saved.set(k,v)}}
  const source=readFileSync(new URL('../lib/settings.js',import.meta.url),'utf8').replace(/^import .*$/gm,'').replace(/^export /gm,'')
  const context={LocalStorage};vm.createContext(context);vm.runInContext(source,context)
  assert.equal(context.getDelay(),3)
  context.setDelay(0);assert.equal(context.getDelay(),0)
  context.setDelay(60);assert.equal(context.getDelay(),60)
  context.setDelay(61);context.setDelay(-1);context.setDelay(NaN);assert.equal(context.getDelay(),60)
  saved.set('startDelay','');assert.equal(context.getDelay(),3)
  saved.set('startDelay','corrupt');assert.equal(context.getDelay(),3)
})

test('settings gear has a large hit area and no rectangular background', () => {
  let options, event, clicked=0
  const source=readFileSync(new URL('../lib/ui.js',import.meta.url),'utf8').replace(/^import .*$/gm,'').replace(/^export /gm,'')
  const context={ui:{widget:{TEXT:'text'},align:{CENTER_H:0,CENTER_V:0},event:{CLICK_UP:'up'},
    createWidget:(type,o)=>{assert.equal(type,'text');options=o;return {addEventListener:(e,fn)=>{event=e;fn()}}}}}
  vm.createContext(context);vm.runInContext(source,context);context.settingsIcon(()=>clicked++)
  assert.equal(options.text,'⚙');assert.equal(options.text_size,76);assert.ok(options.w>=100)
  assert.equal(options.normal_color,undefined);assert.equal(event,'up');assert.equal(clicked,1)
})

test('random delay persists a valid range and samples only within its bounds', () => {
  const saved = new Map()
  class LocalStorage {getItem(k){return saved.get(k)} setItem(k,v){saved.set(k,v)}}
  const source=readFileSync(new URL('../lib/settings.js',import.meta.url),'utf8').replace(/^import .*$/gm,'').replace(/^export /gm,'')
  const context={LocalStorage};vm.createContext(context);vm.runInContext(source,context)
  assert.equal(context.getDelayMode(),'fixed');assert.equal(context.getStartDelayMs(),3000)
  context.setDelayMode('random')
  assert.equal(context.getDelayRange().min,3);assert.equal(context.getDelayRange().max,6)
  vm.runInContext('Math.random=()=>0',context);assert.equal(context.getStartDelayMs(),3000)
  vm.runInContext('Math.random=()=>0.999999',context);assert.equal(context.getStartDelayMs(),6000)
  context.setDelayRange(6,3);context.setDelayRange(-1,60)
  assert.equal(context.getDelayRange().min,3);assert.equal(context.getDelayRange().max,6)
  context.setDelayRange(0,0);assert.equal(context.getStartDelayMs(),0)
  const reloaded={LocalStorage};vm.createContext(reloaded);vm.runInContext(source,reloaded)
  assert.equal(reloaded.getDelayMode(),'random');assert.equal(reloaded.getStartDelayMs(),0)
  context.setDelayMode('fixed');context.setDelay(5);assert.equal(context.getStartDelayMs(),5000)
})

test('delay settings switch modes, keep controls usable and prevent crossed bounds', () => {
  const saved = new Map(), buttons=[]
  class LocalStorage {getItem(k){return saved.get(k)} setItem(k,v){saved.set(k,v)}}
  let page
  const context={LocalStorage,replace:()=>{},Page:p=>{page=p},
    label:text=>({text}), button:(text,x,y,w,h,click)=>{const b={text,click,x,y,w,h};buttons.push(b);return b},
    update:(w,text)=>{w.text=text},show:(w,visible)=>{w.visible=visible}}
  vm.createContext(context)
  const settings=readFileSync(new URL('../lib/settings.js',import.meta.url),'utf8').replace(/^import .*$/gm,'').replace(/^export /gm,'')
  vm.runInContext(settings,context)
  const source=readFileSync(new URL('../page/delay.js',import.meta.url),'utf8').replace(/^import .*$/gm,'')
  vm.runInContext(source,context);page.build()
  assert.equal(page.mode.text,'Фиксированная');assert.equal(page.upper.visible,false)
  page.mode.click();assert.equal(page.mode.text,'Случайная')
  assert.equal(page.lower.text,'3');assert.equal(page.upper.text,'6');assert.equal(page.upper.visible,true)
  page.change(true,20);assert.equal(page.lower.text,'6')
  page.change(false,-20);assert.equal(page.upper.text,'6')
  page.change(true,-20);assert.equal(page.lower.text,'0')
  page.change(false,100);assert.equal(page.upper.text,'60')
  page.mode.click();assert.equal(page.lower.text,'3');assert.equal(page.upper.visible,false)
  for (const b of buttons) {assert.ok(b.x>=0 && b.y>=0 && b.x+b.w<=480 && b.y+b.h<=480);assert.ok(b.h>=48)}
})
