import { test } from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import vm from 'node:vm'

test('live page shows phone metrics, switches controls and releases Zepp link on exit', () => {
  let page, closed = 0, released = 0, connected = 0
  const labels = [], buttons = [], commands = [], awake = []
  const source = readFileSync(new URL('../page/index.js', import.meta.url),'utf8')
    .replace(/^import .*$/gm,'')
  class PhoneLink {
    constructor(update) { this.update=update; this.state=null; this.message='Нет подключения' }
    fresh() { return this.state!==null }
    connect() { connected++;this.active=true }
    poll() {}
    command(start) { commands.push(start) }
    close() { closed++ }
  }
  vm.runInNewContext(source, { PhoneLink,
    BasePage:p=>p, Page: p => {page=p}, replace:()=>{}, getMode:()=>'run',getTransport:()=>'phone',
    applyScreenPolicy:value=>awake.push(value), releaseScreen:()=>released++,
    label:text=>{const w={text};labels.push(w);return w},
    settingsIcon:click=>{buttons.push({text:'⚙',click})},
    button:(text,x,y,w,h,click)=>{const b={text,click};buttons.push(b);return b},
    actionButton:(text,click)=>{const b={text,click};buttons.unshift(b);return b},
    actionColor:(w,stop,ready)=>{w.stop=stop;w.ready=ready},
    update:(w,text)=>{w.text=text}
  })
  page.onInit(); page.build(); buttons[0].click(); assert.equal(connected,1)
  page.link.state={revision:0,phase:4,total:0,count:0};page.link.update();assert.equal(awake.at(-1),true)
  page.link.pending={start:true};page.link.state.phase=0;buttons[0].click();assert.deepEqual(commands,[false]);commands.length=0;page.link.pending=null
  page.link.state={total:1640,split:390,count:2,phase:2,phone:true,control:true}
  page.link.message='Таймер телефона'; page.link.update()
  assert.equal(page.total.text,'1.64'); assert.equal(page.split.text,'0.39')
  assert.equal(page.count.text,'2'); assert.equal(buttons[0].text,'Стоп')
  assert.equal(buttons[0].stop,true); buttons[0].click(); assert.deepEqual(commands,[false])
  page.link.state.phase=1; page.render(); assert.equal(buttons[0].text,'Стоп')
  page.link.state.phase=3; page.render(); assert.equal(buttons[0].ready,true); assert.equal(buttons[0].stop,false); buttons[0].click(); assert.deepEqual(commands,[false,true])
  page.link.state.phone=false; page.link.state.control=false; page.render()
  assert.equal(buttons[0].text,'СТАРТ'); assert.deepEqual(commands,[false,true])
  assert.equal(page.status.text,'Серия завершена')
  buttons[0].click(); assert.match(page.status.text,/Старт на самом таймере/)
  page.link.state={revision:10,phase:2,total:0,count:0,phone:false,control:false}; page.render()
  assert.equal(page.status.text,'Серия идёт · внешний таймер'); assert.equal(buttons[0].text,'Серия идёт')
  assert.equal(page.total.text,'0.00'); buttons[0].click(); assert.deepEqual(commands,[false,true])
  page.link.state.phase=0; page.render(); assert.equal(page.status.text,'Внешний таймер · готов')
  page.link.state.control=true; page.render(); assert.equal(buttons[0].ready,true)
  buttons[0].click(); assert.equal(commands.at(-1),true)
  page.link.state.phase=2; page.render(); assert.equal(buttons[0].text,'Стоп')
  buttons[0].click(); assert.equal(commands.at(-1),false)
  page.onDestroy(); assert.equal(closed,1); assert.equal(released,1)
})
