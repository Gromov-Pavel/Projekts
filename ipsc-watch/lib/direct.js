import * as ble from '@zos/ble'
import { timerProfiles, uuid, TimerDecoder, controlPacket } from './timers'
import { getDirectTimer } from './settings'

const params=(p,extra)=>typeof p==='object'&&p!==null?p:extra
export class DirectTimerLink {
  constructor(update) {
    this.update=update;this.direct=true;this.epoch=0;this.connection=null;this.profile=null
    this.active=false;this.subscribed=false;this.pending=null;this.stopRequested=false
    this.state=null;this.message='Выберите таймер в настройках';this.timeout=null;this.tick=null
  }
  show(message) {this.message=message;this.update(this)}
  fresh() {return this.connection!==null&&this.profile!==null&&this.subscribed}
  setStage(stage,message) {
    clearTimeout(this.timeout);this.stage=stage;const epoch=this.epoch
    this.show(message)
    this.timeout=setTimeout(()=>{
      if(epoch!==this.epoch||this.stage!==stage)return
      const error=stage==='scan'?'Выбранный таймер не найден':stage==='connect'?'Таймер не ответил на подключение'
        :stage==='profile'?'Нет ответа профиля':'Нет ответа подписки'
      this.fail(error)
    },20000)
  }
  connect() {
    this.close()
    const saved=getDirectTimer(), definition=timerProfiles.find(p=>p.id===saved?.profile)
    if(!saved||!definition){this.show('Выберите таймер в настройках');return}
    this.definition=definition;this.decoder=new TimerDecoder(definition.id)
    this.state=null;this.active=true;const epoch=this.epoch
    this.setStage('scan','Поиск выбранного таймера…')
    try {
      // Connect from a fresh native scan result, as in the Zepp BLE sample.
      // Saved bytes select exactly one device; no nearest-device fallback.
      if(!ble.mstStartScan(result=>{
        if(epoch!==this.epoch||this.stage!=='scan'||!(result.dev_addr instanceof ArrayBuffer)||result.dev_addr.byteLength!==6)return
        const address=result.dev_addr
        if(!new Uint8Array(address).every((b,i)=>b===saved.address[i]))return
        ble.mstStopScan();this.setStage('connect','Соединение с таймером…')
        if(!ble.mstConnect(address,c=>{
        if(epoch!==this.epoch){if(c.connected===0)ble.mstDisconnect(c.connect_id);return}
        if(c.connected!==0){this.fail(c.connected===2?'Связь с таймером потеряна':'Ошибка подключения: '+c.connected);return}
        this.connection=c.connect_id;this.setStage('profile','Настраиваем протокол…')
        ble.mstOnPrepare((p,s)=>{
          if(epoch!==this.epoch)return
          const value=params(p,{profile:p,status:s})
          if(value.status!==0){this.fail('Ошибка профиля: '+value.status);return}
          this.profile=value.profile;this.setStage('subscribe','Включаем приём выстрелов…')
          if(!ble.mstWriteDescriptor(this.profile,definition.notify,'2902',new Uint8Array([1,0]).buffer,2))this.fail('Не удалось включить приём')
        })
        ble.mstOnDescWriteComplete((p,u,d,s)=>{
          if(epoch!==this.epoch)return
          const value=params(p,{profile:p,chara:u,status:s})
          if(value.profile!==this.profile||uuid(value.chara||value.uuid)!==definition.notify)return
          if(value.status!==0){this.fail('Ошибка подписки: '+value.status);return}
          if(this.subscribed)return
          clearTimeout(this.timeout);this.timeout=null;this.subscribed=true;this.stage='ready'
          this.state={revision:1,run:0,phase:0,phone:false,control:true,failed:false,count:0,total:0,split:null}
          this.tick=setInterval(()=>this.poll(),500);this.show('Напрямую · '+saved.name)
        })
        ble.mstOnCharaNotification((p,u,d)=>{
          if(epoch!==this.epoch)return
          const value=params(p,{profile:p,uuid:u,data:d})
          if(value.profile===this.profile&&uuid(value.uuid)===definition.notify&&value.data instanceof ArrayBuffer)
            this.receive(new Uint8Array(value.data))
        })
        ble.mstOnCharaWriteComplete((p,u,s)=>{
          if(epoch!==this.epoch)return
          const value=params(p,{profile:p,uuid:u,status:s})
          if(value.profile===this.profile&&uuid(value.uuid)===definition.write&&value.status!==0){
            this.pending=null;this.stopRequested=false;this.show('Команда отклонена таймером')
          }
        })
        const chars=[{uuid:definition.notify,permission:32,desc:1,len:1,list:[{uuid:'2902',permission:32}]},
          {uuid:definition.write,permission:32,desc:0,len:0}]
        if(!ble.mstBuildProfile({pair:false,id:this.connection,profile:'ipsc-timer',dev:address,len:1,
          list:[{uuid:true,size:1,len:1,list:[{uuid:definition.service.replace(/^0000([0-9a-f]{4})-0000-1000-8000-00805f9b34fb$/i,'$1').toUpperCase(),permission:0,serv:0,len1:2,len2:2,list:chars}]}]}))this.fail('Не удалось создать BLE-профиль')
        }))this.fail('Подключение BLE недоступно')
      }))this.fail('Поиск BLE недоступен')
    }catch(_){this.fail('Ошибка Bluetooth. Повторите')}
  }
  fail(message){this.close();this.show(message)}
  receive(bytes) {
    if(!this.fresh())return
    for(const event of this.decoder.add(bytes)) {
      const s=this.state
      if(event.kind==='start'){
        this.state={...s,revision:s.revision+1,run:s.run+1,phase:2,count:0,total:0,split:null}
        if(this.pending?.start)this.pending=null
      }else if(event.kind==='shot'){
        this.state={...s,revision:s.revision+1,count:s.count+1,total:event.time,split:s.count?event.time-s.total:null}
      }else if(event.kind==='stop'){
        this.state={...s,revision:s.revision+1,phase:3}
        this.pending=null;this.stopRequested=false
      }
    }
    if(this.stopRequested&&!this.pending&&this.state.phase===2){this.stopRequested=false;this.command(false)}
    this.show(this.pending?'Ожидаем таймер…':this.state.phase===2?'Серия идёт · напрямую':this.state.phase===3?'Серия завершена':'Таймер · напрямую')
  }
  poll() {
    if(this.pending && Date.now()-this.pending.at>10000){this.pending=null;this.stopRequested=false;this.show('Нет подтверждения. Проверьте таймер')}
  }
  command(start) {
    if(!this.fresh())return
    if(this.pending){if(!start&&this.pending.start)this.stopRequested=true;this.update(this);return}
    if(start&&[1,2].includes(this.state.phase))return
    if(!start&&![1,2].includes(this.state.phase))return
    const bytes=controlPacket(this.definition.id,start)
    this.pending={start,at:Date.now()};this.show(start?'Запускаем…':'Останавливаем…')
    try {ble.mstWriteCharacteristic(this.profile,this.definition.write,bytes.buffer,bytes.length)}
    catch(_){this.pending=null;this.stopRequested=false;this.show('Не удалось отправить команду')}
  }
  close() {
    this.epoch++;clearTimeout(this.timeout);clearInterval(this.tick);this.timeout=this.tick=null
    try{ble.mstStopScan()}catch(_){}
    try{if(this.profile!==null)ble.mstDestroyProfileInstance(this.profile)}catch(_){}
    try{if(this.connection!==null)ble.mstDisconnect(this.connection)}catch(_){}
    try{ble.mstOffAllCb()}catch(_){}
    this.connection=this.profile=null;this.active=this.subscribed=false;this.pending=null;this.stopRequested=false
  }
}
