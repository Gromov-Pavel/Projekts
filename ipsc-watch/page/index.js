import { BasePage } from '@zeppos/zml/base-page'
import { replace } from '@zos/router'
import { PhoneLink } from '../lib/phone'
import { DirectTimerLink } from '../lib/direct'
import { applyScreenPolicy, releaseScreen } from '../lib/screen'
import { getMode, getTransport } from '../lib/settings'
import { label, update, actionButton, actionColor, settingsIcon } from '../lib/ui'

Page(BasePage({
  onInit() {
    this.policy = null
    const update = () => { if (this.status) this.render() }
    this.link = getTransport() === 'direct' ? new DirectTimerLink(update)
      : new PhoneLink(update, data => this.request(data, {timeout:4000}))
  },
  build() {
    settingsIcon(() => replace({url:'page/settings'}))
    this.status = label('Нет подключения', 40, 104, 400, 38, 18, 0xffbb66)
    this.total = label('0.00', 35, 142, 410, 92, 82)
    label('ВРЕМЯ, С', 130, 231, 220, 24, 18, 0x97a5b4)
    label('СПЛИТ, С', 55, 266, 180, 24, 18, 0x97a5b4)
    label('ВЫСТРЕЛЫ', 245, 266, 180, 24, 18, 0x97a5b4)
    this.split = label('—', 55, 295, 180, 50, 40)
    this.count = label('0', 245, 295, 180, 50, 40)
    this.gap = label('', 30, 346, 420, 18, 14, 0xffbb66)
    this.action = actionButton('Подключить', () => {
      if (!this.link.fresh()) { if (!this.link.active) this.link.connect(); else this.link.poll(); return }
      const state = this.link.state
      if (this.link.pending) { if (this.link.pending.start) this.link.command(false); return }
      if (!state.phone && !state.control) { this.externalNotice = true; this.render(); return }
      if (state.control && state.phase !== 4) this.link.command(![1, 2].includes(state.phase))
    })
    this.render()
    this.link.connect()
  },
  render() {
    const state = this.link.state, fresh = this.link.fresh()
    update(this.total, ((state?.total || 0) / 1000).toFixed(2))
    update(this.count, String(state?.count || 0))
    update(this.split, state?.split == null ? '—' : (state.split / 1000).toFixed(2))
    let status = this.link.message
    if (!this.link.direct && fresh && state.revision !== 0 && !state.failed && !this.link.pending) {
      if (state.phase === 4) status = state.phone ? 'Откройте таймер на телефоне' : 'Подключите внешний таймер'
      else if (!state.phone) status = state.phase === 3 ? 'Серия завершена'
        : [1, 2].includes(state.phase) ? 'Серия идёт · внешний таймер' : 'Внешний таймер · готов'
    }
    if (fresh && state.revision !== 0 && !state.phone && !state.control && this.externalNotice && [0, 3].includes(state.phase)) status = 'Старт на самом таймере'
    if (fresh && [1, 2].includes(state.phase)) this.externalNotice = false
    update(this.status, status)
    update(this.gap, state?.partial ? 'НЕПОЛНЫЙ ПРОХОД · БЫЛ ОБРЫВ' : '')
    const stopping = this.link.stopRequested || (this.link.pending && !this.link.pending.start)
    const running = fresh && state.revision !== 0 && [1, 2].includes(state.phase)
    const ready = fresh && state.revision !== 0 && state.control && state.phase !== 4
    update(this.action, !fresh ? (this.link.active ? 'Подключаем…' : 'Подключить')
      : state.revision === 0 ? 'Сверьте код' : stopping ? 'Останавливаем…'
      : this.link.pending ? 'Запускаем…' : state.phase === 4 ? 'См. телефон'
      : !state.phone && !state.control ? (running ? 'Серия идёт' : 'СТАРТ') : !state.control ? 'См. телефон'
      : running ? 'Стоп' : 'СТАРТ')
    actionColor(this.action, Boolean(running || stopping), Boolean(ready))
    const awake = getMode() === 'training' || (this.link.direct && this.link.active && !fresh) || (this.link.active && (!state || state.revision === 0 || this.link.pending)) || (fresh && [1, 2].includes(state?.phase))
    if (this.policy !== awake) { applyScreenPolicy(awake); this.policy = awake }
  },
  onDestroy() { this.link.close(); releaseScreen() }
}))
