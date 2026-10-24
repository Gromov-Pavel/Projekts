import { test } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import vm from 'node:vm'

test('live page shows phone metrics, switches controls and releases Bluetooth on exit', () => {
  let page, closed = 0, released = 0, connected = 0
  const labels = [], buttons = [], commands = []
  const source = readFileSync(new URL('../page/index.js', import.meta.url),'utf8')
    .replace(/^import .*$/gm,'')
  class PhoneLink {
    constructor(update) { this.update=update; this.state=null; this.message='Нет подключения' }
    fresh() { return this.state!==null }
    connect() { connected++ }
    command(start) { commands.push(start) }
    close() { closed++ }
  }
  vm.runInNewContext(source, { PhoneLink,
    Page: p => {page=p}, replace:()=>{}, getMode:()=>'run',
    applyScreenPolicy:()=>{}, releaseScreen:()=>released++,
    label:text=>{const w={text};labels.push(w);return w},
    button:(text,x,y,w,h,click)=>{const b={text,click};buttons.push(b);return b},
    update:(w,text)=>{w.text=text}
  })
  page.onInit(); page.build(); buttons[0].click(); assert.equal(connected,1)
  page.link.state={total:1640,split:390,count:2,phase:2,phone:true,control:true}
  page.link.message='Таймер телефона'; page.link.update()
  assert.equal(page.total.text,'1.64'); assert.equal(page.split.text,'0.39')
  assert.equal(page.count.text,'2'); assert.equal(buttons[0].text,'Завершить')
  buttons[0].click(); assert.deepEqual(commands,[false])
  page.link.state.phase=1; page.render(); assert.equal(buttons[0].text,'Отмена')
  page.link.state.phase=3; page.render(); buttons[0].click(); assert.deepEqual(commands,[false,true])
  page.link.state.phone=false; page.render(); buttons[0].click()
  assert.equal(buttons[0].text,'Старт на таймере'); assert.deepEqual(commands,[false,true])
  page.onDestroy(); assert.equal(closed,1); assert.equal(released,1)
})
