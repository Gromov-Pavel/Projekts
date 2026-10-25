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
