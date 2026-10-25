import { getDelay } from './settings'
import { decodeState, acceptState, commandPacket } from './wire'

export class PhoneLink {
  constructor(update, request) {
    this.update = update; this.request = request; this.state = null; this.session = null
    this.active = false; this.tick = null; this.epoch = 0; this.sequence = 0
    this.lastSeen = 0; this.pending = null; this.reading = false; this.stopRequested = false
    this.message = 'Нет подключения'
  }
  show(message) { this.message = message; this.update(this) }
  connect() {
    this.close(); this.state = null; this.session = null; this.sequence = 0
    this.active = true; this.show('Связь через Zepp…')
    this.tick = setInterval(() => this.poll(), 1000); this.poll()
  }
  fresh() { return this.active && this.lastSeen > 0 && Date.now() - this.lastSeen < 5000 }
  receive(response) {
    if (response?.error) { this.show(response.error); return }
    const bytes = response?.packet
    if (!Array.isArray(bytes) || bytes.length !== 20 || bytes.some(b => !Number.isInteger(b) || b < 0 || b > 255) ||
      typeof response.session !== 'string' || !/^[0-9a-f]{32}$/.test(response.session)) return
    const decoded = decodeState(new Uint8Array(bytes).buffer)
    if (!decoded) return
    if (response.session !== this.session) {
      this.session = response.session; this.state = null; this.sequence = 0; this.pending = null; this.stopRequested = false
    }
    const previous = this.state, next = acceptState(previous, decoded)
    if (next === previous && (!previous || Object.keys(decoded).some(k => decoded[k] !== previous[k]))) return
    this.lastSeen = Date.now(); this.state = next
    if (this.pending) {
      const done = next.failed || (!this.pending.start && next.run !== this.pending.run) || (this.pending.start
        ? next.run !== this.pending.run && [1, 2].includes(next.phase)
        : next.run === this.pending.run && ![1, 2].includes(next.phase))
      if (done) {
        this.pending = null
        if (this.stopRequested) {
          this.stopRequested = false
          if (!next.failed && next.control && [1, 2].includes(next.phase)) { this.command(false); return }
        }
      }
    }
    this.show(next.revision === 0 ? 'Сверьте код: ' + String(next.run) : next.failed
      ? 'Команда не выполнена. См. телефон' : this.pending ? 'Ожидание телефона…'
      : next.phase === 4 ? 'Источник недоступен' : next.phone ? 'Таймер телефона' : 'Внешний таймер')
  }
  poll() {
    if (!this.active) return
    const now = Date.now()
    if (this.lastSeen && !this.fresh()) { this.pending = null; this.stopRequested = false; this.show('Связь потеряна · данные старые') }
    if (this.pending && now - this.pending.at > 10000) { this.pending = null; this.stopRequested = false; this.show('Нет подтверждения команды') }
    if (this.pending && !this.pending.start && this.fresh() && this.state.run === this.pending.run && [1, 2].includes(this.state.phase) && now - this.pending.lastAttempt >= 1500 && this.pending.attempts < 3) this.send(this.pending)
    if (this.reading) return
    const epoch = this.epoch; this.reading = true
    Promise.resolve().then(() => this.request({method:'IPSC_STATE'})).then(response => {
      if (epoch === this.epoch && this.active) this.receive(response)
    }).catch(() => {
      if (epoch === this.epoch && this.active) this.show('Откройте Zepp на телефоне')
    }).finally(() => { if (epoch === this.epoch) this.reading = false })
  }
  command(start) {
    if (!this.fresh()) return
    if (this.pending) {
      if (!start && this.pending.start) { this.stopRequested = true; this.show('Завершаем…') }
      return
    }
    const pending = {start, delayMs:start ? getDelay() * 1000 : undefined, run:this.state.run, at:Date.now(), lastAttempt:0, attempts:0, session:this.session}
    this.pending = pending; this.send(pending)
  }
  send(pending) {
    if (this.pending !== pending || pending.session !== this.session) return
    const packet = commandPacket(this.state, pending.start, ++this.sequence)
    if (!packet) { this.pending = null; this.stopRequested = false; this.show('Команда недоступна. См. телефон'); return }
    pending.lastAttempt = Date.now(); pending.attempts++
    const epoch = this.epoch, session = this.session
    this.show(pending.start ? 'Ожидание старта…' : 'Завершаем…')
    Promise.resolve().then(() => this.request({method:'IPSC_COMMAND', params:{session,packet:Array.from(new Uint8Array(packet)), ...(pending.start ? {delayMs:pending.delayMs} : {})}}))
      .then(response => {
        if (epoch !== this.epoch || !this.active || session !== this.session || this.pending !== pending) return
        if (response?.error || response?.accepted !== true) {
          if (pending.start) { this.pending = null; this.stopRequested = false; this.show(response?.error || 'Команда не принята') }
          else this.show('Повторяю завершение…')
        } else this.poll()
      }).catch(() => {
        if (epoch === this.epoch && this.active && session === this.session && this.pending === pending) {
          if (pending.start) { this.pending = null; this.stopRequested = false; this.show('Команда не доставлена. См. телефон') }
          else this.show('Повторяю завершение…')
        }
      })
  }
  close() {
    this.epoch++; this.active = false; this.reading = false
    if (this.tick !== null) clearInterval(this.tick)
    this.tick = null; this.pending = null; this.lastSeen = 0; this.stopRequested = false
  }
}
