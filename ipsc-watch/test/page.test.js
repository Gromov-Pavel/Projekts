import { test } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import vm from 'node:vm'
import * as session from '../lib/session.js'

test('watch screen updates all six demo shots and restores screen policy on exit', () => {
  let page, tick, cleared = 0, released = 0
  const labels = [], buttons = [], policies = []
  const source = readFileSync(new URL('../page/index.js', import.meta.url),'utf8')
    .replace(/^import .*$/gm,'')
  vm.runInNewContext(source, { ...session,
    Page: p => {page=p}, replace: () => {}, getMode: ()=>'run',
    applyScreenPolicy: v=>policies.push(v), releaseScreen: ()=>released++,
    label: text=>{ const w={text};labels.push(w);return w },
    button: (text,x,y,w,h,click)=>{const b={text,click};buttons.push(b);return b},
    update: (w,text)=>{w.text=text},
    setInterval: callback=>{tick=callback;return 1}, clearInterval: ()=>cleared++
  })
  page.onInit(); page.build()
  assert.equal(labels[1].text,'Нет подключения')
  buttons[0].click()
  assert.equal(labels[1].text,'ДЕМО · выстрелы')
  for(let i=0;i<6;i++) tick()
  assert.equal(labels[2].text,'3.25')
  assert.equal(page.split.text,'0.42')
  assert.equal(page.count.text,'6')
  assert.equal(labels[1].text,'ДЕМО · завершено')
  assert.deepEqual(policies,[false,true,false])
  assert.equal(cleared,1)
  page.onDestroy(); assert.equal(released,1)
})
