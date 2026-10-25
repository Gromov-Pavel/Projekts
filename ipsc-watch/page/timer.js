import * as ble from '@zos/ble'
import { replace } from '@zos/router'
import { identifyTimer, timerProfiles } from '../lib/timers'
import { getTransport, setTransport, getDirectTimer, setDirectTimer } from '../lib/settings'
import { label, button, update, show } from '../lib/ui'
import { applyScreenPolicy, releaseScreen } from '../lib/screen'

Page({
  build() {
    applyScreenPolicy(true);this.items=[];this.offset=0;this.closed=false;this.scanning=false
    label('Подключение',70,26,340,40,28)
    this.mode=button('',50,78,380,52,()=>{
      setTransport(getTransport()==='direct'?'phone':'direct');this.stopScan();this.refresh()
    })
    this.status=label('',42,136,396,52,18,0xffbb66)
    this.rows=[0,1].map(i=>button('',45,197+i*64,390,56,()=>this.choose(this.offset+i)))
    this.search=button('Поиск',50,331,180,52,()=>{if(this.candidate){this.candidate=null;this.offset=0;this.refresh()}else this.scan()})
    this.next=button('Дальше',250,331,180,52,()=>{this.offset=(this.offset+2)%(this.candidate?timerProfiles.length:this.items.length);this.refresh()})
    button('Назад',145,400,190,54,()=>replace({url:'page/settings'}))
    this.refresh()
  },
  refresh() {
    const direct=getTransport()==='direct', saved=getDirectTimer()
    update(this.mode,direct?'Напрямую к таймеру':'Через телефон')
    update(this.status,!direct?'Связь через Zepp и IPSC на телефоне':this.candidate?'Протокол для '+this.candidate.name:
      this.scanning?'Поиск · '+this.items.length+' рядом':this.items.length?'Найдено: '+this.items.length:saved?'Выбран: '+saved.name:'Отключите таймер от телефона')
    const items=this.candidate?timerProfiles:this.items
    this.rows.forEach((row,i)=>{const item=items[this.offset+i];show(row,direct&&Boolean(item));if(item)update(row,item.name||item.label)})
    update(this.search,this.candidate?'К списку':'Поиск')
    show(this.search,direct);show(this.next,direct&&items.length>2)
  },
  choose(index) {
    let item
    if(this.candidate) {const profile=timerProfiles[index];if(!profile)return;item={...this.candidate,profile:profile.id}}
    else {item=this.items[index];if(!item)return;if(!item.profile){this.stopScan();this.candidate=item;this.offset=0;this.refresh();return}}
    setDirectTimer(item);setTransport('direct');this.stopScan();replace({url:'page/index'})
  },
  scan() {
    this.stopScan();this.items=[];this.candidate=null;this.offset=0;this.scanning=true;this.refresh()
    try {
      const ok=ble.mstStartScan(result=>{
        if(this.closed||!this.scanning)return
        const profile=identifyTimer(result.dev_name,result.service_uuid_array||[])
        if(!(result.dev_addr instanceof ArrayBuffer)||result.dev_addr.byteLength!==6)return
        const address=Array.from(new Uint8Array(result.dev_addr))
        const existing=this.items.find(item=>item.address.every((b,i)=>b===address[i]))
        const name=result.dev_name||profile?.label||'Без имени · '+address.slice(-2).map(b=>b.toString(16).padStart(2,'0')).join(':')
        if(existing){if(result.dev_name)existing.name=name;if(profile)existing.profile=profile.id}
        else if(this.items.length<60)this.items.push({name,address,profile:profile?.id||null})
        if(this.offset===0)this.items.sort((a,b)=>Number(Boolean(b.profile))-Number(Boolean(a.profile)))
        this.refresh()
      })
      if(!ok){this.stopScan();update(this.status,'Bluetooth недоступен');return}
      this.timeout=setTimeout(()=>{this.stopScan();this.refresh();if(!this.items.length)update(this.status,'Не найден. Освободите связь телефона')},12000)
    }catch(_){this.stopScan();update(this.status,'Ошибка поиска. Повторите')}
  },
  stopScan() {this.scanning=false;clearTimeout(this.timeout);try{ble.mstStopScan()}catch(_){}},
  onDestroy() {this.closed=true;this.stopScan();releaseScreen()}
})
