import * as ble from '@zos/ble'
import { SERVICE, STATE, COMMAND, sameUuid, decodeState, acceptState, commandPacket } from './wire'

// API reference and official 3.0-feature sample differ on callback arguments.
const prepareArgs = (p, status) => typeof p === 'object' ? p : {profile:p, status}
const valueArgs = (p, uuid, data, status) => typeof p === 'object' ? p : {profile:p, uuid, data, status}

export class PhoneLink {
  constructor(update) {
    this.update = update; this.state = null; this.connection = null; this.profile = null
    this.tick = null; this.scanTimeout = null; this.epoch = 0; this.sequence = 0; this.connecting = false
    this.lastSeen = 0; this.pending = null; this.reading = false; this.readAt = 0
    this.subscribed = false; this.subscribing = false; this.subAt = 0; this.message = 'Нет подключения'
  }
  show(message) { this.message = message; this.update(this) }
  connect() {
    this.close(); const epoch = this.epoch
    this.state = null; this.sequence = 0; this.show('Поиск телефона…')
    try {
      const ok = ble.mstStartScan(result => {
        if (epoch !== this.epoch || this.connection !== null || this.connecting) return
        if (!result.service_uuid_array?.some(u => sameUuid(u, SERVICE))) return
        ble.mstStopScan(); this.connecting = true
        this.show('Соединение…')
        const started = ble.mstConnect(result.dev_addr, connection => {
          if (epoch !== this.epoch) {
            if (connection.connected === 0) ble.mstDisconnect(connection.connect_id)
            return
          }
          if (connection.connected !== 0) { this.close(); this.show('Связь потеряна'); return }
          this.connection = connection.connect_id
          ble.mstOnPrepare((p, s) => {
            if (epoch !== this.epoch) return
            const prepared = prepareArgs(p, s)
            if (prepared.status !== 0) { this.close(); this.show('Ошибка BLE-профиля'); return }
            this.profile = prepared.profile; this.lastSeen = 0
            clearTimeout(this.scanTimeout); this.scanTimeout = null
            this.show('Подтвердите на телефоне')
            if (this.tick !== null) clearInterval(this.tick)
            this.tick = setInterval(() => this.poll(), 1000); this.poll()
          })
          ble.mstOnCharaValueArrived((p, u, d, s) => {
            if (epoch !== this.epoch) return
            const value = valueArgs(p, u, d, s)
            if (value.profile !== this.profile || !sameUuid(value.uuid, STATE)) return
            this.reading = false
            if (value.status === 0) this.receive(value.data)
          })
          ble.mstOnCharaNotification((p, u, d) => {
            if (epoch !== this.epoch) return
            const value = valueArgs(p, u, d, 0)
            if (value.profile === this.profile && sameUuid(value.uuid, STATE)) this.receive(value.data)
          })
          ble.mstOnDescWriteComplete((p, u, desc, s) => {
            if (epoch !== this.epoch) return
            const value = typeof p === 'object' ? p : {profile:p, chara:u, status:s}
            if (value.profile === this.profile && sameUuid(value.chara || value.uuid, STATE)) {
              this.subscribing = false; this.subscribed = value.status === 0
            }
          })
          ble.mstOnCharaWriteComplete((p, u, s) => {
            if (epoch !== this.epoch) return
            const value = typeof p === 'object' ? p : {profile:p, uuid:u, status:s}
            if (value.profile === this.profile && sameUuid(value.uuid, COMMAND) && value.status !== 0) {
              this.pending = null; this.show('Команда отклонена телефоном')
            }
          })
          const built = ble.mstBuildProfile({pair:true, id:this.connection, profile:'ipsc-phone',
            dev:result.dev_addr, len:1, list:[{uuid:true, size:1, len:1, list:[{
              uuid:SERVICE, permission:0, serv:0, len1:2, len2:2, list:[
                {uuid:STATE, permission:32, desc:1, len:1, list:[{uuid:'2902', permission:32}]},
                {uuid:COMMAND, permission:32, desc:0, len:0},
              ],
            }]}]})
          if (!built) { this.close(); this.show('Не удалось создать BLE-профиль') }
        })
        if (!started) { this.close(); this.show('Подключение недоступно') }
      }, {service_uuid:SERVICE})
      if (!ok) { this.close(); this.show('Разрешите Bluetooth на часах'); return }
      this.scanTimeout = setTimeout(() => {
        if (epoch === this.epoch && this.profile === null) { this.close(); this.show('Телефон не найден. Повторите') }
      }, 20000)
    } catch (_) { this.close(); this.show('Ошибка Bluetooth. Повторите') }
  }
  receive(data) {
    const decoded = decodeState(data)
    if (!decoded) return
    const previous = this.state, next = acceptState(previous, decoded)
    // Identical reads serve as a heartbeat; old differing frames cannot refresh it.
    if (next === previous && (!previous || Object.keys(decoded).some(k => decoded[k] !== previous[k]))) return
    this.lastSeen = Date.now()
    this.state = next
    if (next.revision > 0 && !this.subscribed && !this.subscribing) {
      this.subscribing = true; this.subAt = Date.now()
      const bytes = new Uint8Array([1, 0])
      if (!ble.mstWriteDescriptor(this.profile, STATE, '2902', bytes.buffer, 2)) this.subscribing = false
    }
    if (this.pending) {
      const done = next.failed || (this.pending.start
        ? next.run !== this.pending.run && [1, 2].includes(next.phase)
        : next.run === this.pending.run && ![1, 2].includes(next.phase))
      if (done) this.pending = null
    }
    this.show(next.revision === 0 ? 'Сверьте код: ' + String(next.run) : next.failed ? 'Команда не выполнена. См. телефон' : this.pending ? 'Ожидание телефона…'
      : next.phase === 4 ? 'Источник недоступен' : next.phone ? 'Таймер телефона' : 'Внешний таймер')
  }
  fresh() { return this.profile !== null && this.lastSeen > 0 && Date.now() - this.lastSeen < 5000 }
  poll() {
    if (this.profile === null) return
    const now = Date.now()
    if (this.subscribing && now - this.subAt > 3000) this.subscribing = false
    if (this.lastSeen && !this.fresh()) {
      this.pending = null; this.show('Связь потеряна · данные старые')
    }
    if (this.pending && now - this.pending.at > 10000) {
      this.pending = null; this.show('Нет подтверждения команды')
    }
    if (this.reading && now - this.readAt < 3000) return
    this.reading = true; this.readAt = now
    try { ble.mstReadCharacteristic(this.profile, STATE) }
    catch (_) { this.reading = false; this.show('Ошибка чтения телефона') }
  }
  command(start) {
    if (!this.fresh() || this.pending) return
    const packet = commandPacket(this.state, start, ++this.sequence)
    if (!packet) { this.show('Команда недоступна. См. телефон'); return }
    this.pending = {start, run:this.state.run, at:Date.now()}
    this.show('Ожидание телефона…')
    try { ble.mstWriteCharacteristic(this.profile, COMMAND, packet, packet.byteLength) }
    catch (_) { this.pending = null; this.show('Не удалось отправить команду') }
  }
  close() {
    this.epoch++
    if (this.tick !== null) clearInterval(this.tick)
    if (this.scanTimeout !== null) clearTimeout(this.scanTimeout)
    this.tick = this.scanTimeout = null
    try { ble.mstStopScan() } catch (_) {}
    try { if (this.connection !== null) ble.mstDisconnect(this.connection) } catch (_) {}
    try { if (this.profile !== null) ble.mstDestroyProfileInstance(this.profile) } catch (_) {}
    try { ble.mstOffAllCb() } catch (_) {}
    this.connection = this.profile = null; this.pending = null; this.lastSeen = 0; this.connecting = false
    this.reading = this.subscribed = this.subscribing = false
  }
}
