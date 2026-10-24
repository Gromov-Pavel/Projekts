import { BasePage } from '@zeppos/zml/base-page'
import { replace } from '@zos/router'
import { PhoneLink } from '../lib/phone'
import { applyScreenPolicy, releaseScreen } from '../lib/screen'
import { getMode } from '../lib/settings'
import { label, button, update, actionButton, actionColor } from '../lib/ui'

Page(BasePage({
  onInit() {
    this.policy = null
    this.link = new PhoneLink(() => { if (this.status) this.render() }, data => this.request(data, {timeout:4000}))
  },
  build() {
    button('⚙', 204, 25, 72, 62, () => replace({url:'page/settings'}))
    this.status = label('Нет подключения', 50, 94, 380, 48, 19, 0xffbb66)
    this.total = label('0.00', 35, 142, 410, 92, 82)
    label('ВРЕМЯ, С', 130, 231, 220, 24, 18, 0x97a5b4)
    label('СПЛИТ, С', 55, 266, 180, 24, 18, 0x97a5b4)
    label('ВЫСТРЕЛЫ', 245, 266, 180, 24, 18, 0x97a5b4)
    this.split = label('—', 55, 295, 180, 50, 40)
    this.count = label('0', 245, 295, 180, 50, 40)
    this.action = actionButton('Подключить', () => {
      if (!this.link.fresh()) { if (!this.link.active) this.link.connect(); else this.link.poll(); return }
      const state = this.link.state
      if (this.link.pending) { if (this.link.pending.start) this.link.command(false); return }
      if (state.phone && state.control && state.phase !== 4) this.link.command(![1, 2].includes(state.phase))
    })
    this.render()
  },
  render() {
    const state = this.link.state, fresh = this.link.fresh()
    update(this.total, ((state?.total || 0) / 1000).toFixed(2))
    update(this.count, String(state?.count || 0))
    update(this.split, state?.split == null ? '—' : (state.split / 1000).toFixed(2))
    let status = this.link.message
    if (fresh && state.revision !== 0 && !state.failed && !this.link.pending) {
      if (state.phase === 4) status = state.phone ? 'Откройте таймер на телефоне' : 'Подключите внешний таймер'
      else if (!state.phone) status = state.phase === 3 ? 'Серия завершена'
        : [1, 2].includes(state.phase) ? 'Серия идёт · внешний таймер' : 'Внешний таймер · готов'
    }
    update(this.status, status)
    const stopping = this.link.stopRequested || (this.link.pending && !this.link.pending.start)
    const running = fresh && state.revision !== 0 && [1, 2].includes(state.phase)
    const ready = fresh && state.revision !== 0 && state.phone && state.control && state.phase !== 4
    update(this.action, !fresh ? (this.link.active ? 'Подключаем…' : 'Подключить')
      : state.revision === 0 ? 'Сверьте код' : stopping ? 'Останавливаем…'
      : this.link.pending ? 'Запускаем…' : state.phase === 4 ? 'См. телефон'
      : !state.phone ? (running ? 'Серия идёт' : 'СТАРТ') : !state.control ? 'См. телефон'
      : running ? 'Стоп' : 'СТАРТ')
    actionColor(this.action, Boolean(running || stopping), Boolean(ready))
    const awake = getMode() === 'training' || (this.link.active && (!state || state.revision === 0 || this.link.pending)) || (fresh && [1, 2].includes(state?.phase))
    if (this.policy !== awake) { applyScreenPolicy(awake); this.policy = awake }
  },
  onDestroy() { this.link.close(); releaseScreen() }
}))
