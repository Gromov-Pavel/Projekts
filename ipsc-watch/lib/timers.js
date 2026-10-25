// Wire facts and sources: docs/timer-support.md. No third-party application code.
export const timerProfiles = [
  {id:'special-pie-legacy-experimental',label:'Special Pie M1A2 / M1A2+',
    service:'0000fff0-0000-1000-8000-00805f9b34fb',notify:'0000fff1-0000-1000-8000-00805f9b34fb',write:'0000fff2-0000-1000-8000-00805f9b34fb'},
  {id:'sg-v3',label:'SG Sport / GO (API 3)',service:'7520ffff-14d2-4cda-8b6b-697c554c9311',
    notify:'75200001-14d2-4cda-8b6b-697c554c9311',write:'75200000-14d2-4cda-8b6b-697c554c9311'},
  {id:'protimer-v2',label:'ProTimer BT / PT Link (v2)',service:'26cc3fc0-6241-f5b4-5347-63a3097f6764',
    notify:'26cc3fc1-6241-f5b4-5347-63a3097f6764',write:'26cc3fc2-6241-f5b4-5347-63a3097f6764'},
  {id:'rangetech',label:'RangeTech',service:'958de860-ee25-4627-9cf8-7821b18cbd29',
    notify:'958de862-ee25-4627-9cf8-7821b18cbd29',write:'958de861-ee25-4627-9cf8-7821b18cbd29'},
  {id:'amg-nus',label:'AMG (COMM / PS / SK)',service:'6e400001-b5a3-f393-e0a9-e50e24dcca9e',
    notify:'6e400003-b5a3-f393-e0a9-e50e24dcca9e',write:'6e400002-b5a3-f393-e0a9-e50e24dcca9e'},
]
export function uuid(value) {
  const s=String(value || '').toLowerCase()
  return s.length===4 ? '0000'+s+'-0000-1000-8000-00805f9b34fb' : s
}
export function identifyTimer(name, services=[]) {
  const n=String(name || '').toLowerCase()
  if (/^sp m1a2|^special pie|^m1a2/.test(n)) return timerProfiles[0]
  if (/^sg-sst4[ab]/.test(n)) return timerProfiles[1]
  if (/^pt link/.test(n)) return timerProfiles[2]
  if (/^rangetech timer/.test(n)) return timerProfiles[3]
  if (/^amg(?: |$)|^ps /.test(n)) return timerProfiles[4]
  // FFF0 is widely reused; only the unique SG service is safe to recognize by UUID.
  return timerProfiles.find(p=>['sg-v3','protimer-v2','rangetech'].includes(p.id) && services.some(s=>uuid(s)===p.service)) || null
}
export function controlPacket(id,start) {
  if (id===timerProfiles[0].id) return new Uint8Array([248,249,start?52:24,249,248])
  if (id==='sg-v3') return new Uint8Array([1,start?0:3])
  const text=id==='protimer-v2'?JSON.stringify({t:start?'start-string':'stop-string'})
    :id==='rangetech'?(start?'B000000':'C000000'):id==='amg-nus'?(start?'COM START':'COM STOP'):null
  if(text!==null)return new Uint8Array(Array.from(text,c=>c.charCodeAt(0)))
  throw new Error('Неизвестный протокол')
}
export class TimerDecoder {
  constructor(id) { this.id=id;this.buffer=[];this.text='';this.session=null;this.index=-1;this.time=-1;this.stopped=false }
  begin(session,out) {
    if(!Number.isSafeInteger(session)||session<0||session===this.session)return
    this.session=session;this.index=this.time=-1;this.stopped=false;out.push({kind:'start',session})
  }
  hit(session,index,time,out) {
    if(this.stopped||!Number.isSafeInteger(session)||session!==this.session||!Number.isSafeInteger(index)||index<0||index<=this.index||
      !Number.isSafeInteger(time)||time<=0||time<=this.time)return
    this.index=index;this.time=time;out.push({kind:'shot',session,index,time})
  }
  end(session,out) {
    if(session!==null&&session===this.session&&!this.stopped){this.stopped=true;out.push({kind:'stop',session})}
  }
  messages(bytes,out) {
    const text=String.fromCharCode(...bytes)
    if(this.id==='rangetech') {
      const begin=/^![^:]+:BEEP\|(\d+)$/.exec(text)
      if(begin)this.begin(Number(begin[1]),out)
      if(/^![^:]+:BUTTONUP$/.test(text))this.end(this.session,out)
      const shot=/^!SHOT(\d+)\|(\d+)\|(\d+)$/.exec(text)
      if(shot)this.hit(Number(shot[3]),Number(shot[2]),Number(shot[1]),out)
      return
    }
    this.text+=text
    if(this.text.length>4096){this.text='';return}
    let depth=0,quoted=false,escaped=false,start=-1,used=0
    for(let i=0;i<this.text.length;i++) {
      const c=this.text[i]
      if(quoted){if(escaped)escaped=false;else if(c==='\\')escaped=true;else if(c==='"')quoted=false;continue}
      if(c==='"'&&depth){quoted=true;continue}
      if(c==='{'){if(!depth)start=i;depth++}
      if(c==='}'&&depth&&!--depth) {
        used=i+1
        try {
          const m=JSON.parse(this.text.slice(start,i+1)), session=m.start
          if(m.t==='string-started')this.begin(session,out)
          if(m.t==='string-stopped')this.end(session,out)
          if(m.t==='shot')this.hit(session,m.index,m.timeInMs,out)
        }catch(_){}
      }
    }
    this.text=this.text.slice(used || (start<0?this.text.length:start))
  }
  add(bytes) {
    const out=[]
    if (bytes.length>4096 || Array.from(bytes).some(b=>!Number.isInteger(b)||b<0||b>255)) {this.buffer=[];return out}
    if(['protimer-v2','rangetech'].includes(this.id)){this.messages(bytes,out);return out}
    if(this.id==='amg-nus') {
      // AMG screen notifications are complete records, not length-prefixed streams.
      const f=Array.from(bytes), n=offset=>f[offset]*256+f[offset+1]
      if(f[0]===3&&f.length===11) {
        if(f[1]===1)this.begin(n(9),out);else if(f[1]===0)this.end(n(9),out)
      } else if((f[0]===1&&f.length===14)||(f[0]===2&&f.length===16)) {
        const small=f[0]===1, session=n(small?12:14), index=small?f[2]:n(2), time=n(small?4:6)*10
        if(f[1]&4)this.begin(session,out)
        this.hit(session,index,time,out)
        if(f[1]&8)this.end(session,out)
      }
      return out
    }
    this.buffer.push(...bytes)
    if(this.buffer.length>4096){this.buffer=[];return out}
    const sg=this.id==='sg-v3', pie=this.id===timerProfiles[0].id
    if(!sg && !pie){this.buffer=[];return out}
    while(this.buffer.length >= (sg?2:3)) {
      const b=this.buffer, type=b[sg?1:2]
      let length
      if(sg) {
        if(![2,5,7,11].includes(b[0])) {b.shift();continue}
        length=b[0]+1
      } else {
        if(b[0]!==248||b[1]!==249||![52,24,54].includes(type)){b.shift();continue}
        length=type===54?10:6
      }
      if(b.length<length) break
      if(!sg && (b[length-2]!==249||b[length-1]!==248)){b.shift();continue}
      const f=b.splice(0,length)
      const number=(offset,size)=>{let v=0;for(let i=offset;i<offset+size;i++)v=v*256+f[i];return v}
      const session=sg?number(2,4):f[3]
      if((!sg&&type===52)||(sg&&type===0&&length===8)) {
        if(this.session===session)continue
        this.session=session;this.index=this.time=-1;this.stopped=false
        out.push({kind:'start',session})
      } else if((!sg&&type===24)||(sg&&type===3&&length===8)) {
        if(session!==this.session||this.stopped)continue
        this.stopped=true;out.push({kind:'stop',session})
        if(!sg)this.session=null
      } else if((!sg&&type===54&&f[3]===0&&f[5]<100)||(sg&&type===4&&length===12)) {
        if(this.session===null||this.stopped||(sg&&session!==this.session))continue
        const index=sg?number(6,2):f[6], time=sg?number(8,4):(f[4]*100+f[5])*10
        if(index<=this.index||time<=0||time<=this.time)continue
        this.index=index;this.time=time;out.push({kind:'shot',session:this.session,index,time})
      }
    }
    return out
  }
}
