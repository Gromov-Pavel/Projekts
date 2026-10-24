import { replace } from '@zos/router'
import { PhoneLink } from '../lib/phone'
import { applyScreenPolicy, releaseScreen } from '../lib/screen'
import { getMode } from '../lib/settings'
import { label, button, update } from '../lib/ui'

Page({
  onInit() {
    this.policy = null
    this.link = new PhoneLink(() => { if (this.status) this.render() })
  },
  build() {
    label('Тренировка', 90, 24, 300, 34, 26)
    this.status = label('Нет подключения', 50, 68, 380, 32, 19, 0xffbb66)
    this.total = label('0.00', 35, 110, 410, 112, 92)
    label('ВРЕМЯ, С', 130, 218, 220, 24, 18, 0x97a5b4)
    label('СПЛИТ, С', 55, 262, 180, 26, 18, 0x97a5b4)
    label('ВЫСТРЕЛЫ', 245, 262, 180, 26, 18, 0x97a5b4)
    this.split = label('—', 55, 292, 180, 54, 40)
    this.count = label('0', 245, 292, 180, 54, 40)
    this.action = button('Подключить', 100, 354, 280, 58, () => {
      if (!this.link.fresh()) { this.link.connect(); return }
      const state = this.link.state
      if (state.phone && state.control && state.phase !== 4) this.link.command(![1, 2].includes(state.phase))
    })
    button('Связь', 100, 416, 125, 38, () => this.link.connect())
    button('Настройки', 240, 416, 140, 38, () => replace({url:'page/settings'}))
    this.render()
  },
  render() {
    const state = this.link.state, fresh = this.link.fresh()
    update(this.total, ((state?.total || 0) / 1000).toFixed(2))
    update(this.count, String(state?.count || 0))
    update(this.split, state?.split == null ? '—' : (state.split / 1000).toFixed(2))
    update(this.status, this.link.message)
    update(this.action, !fresh ? 'Подключить' : state.revision === 0 ? 'Сверьте код' : this.link.pending ? 'Ожидание…'
      : state.phase === 4 ? 'См. телефон' : !state.phone ? 'Старт на таймере' : !state.control ? 'См. телефон'
      : state.phase === 1 ? 'Отмена' : state.phase === 2 ? 'Завершить' : 'Старт')
    const awake = getMode() === 'training' || (fresh && [1, 2].includes(state?.phase))
    if (this.policy !== awake) { applyScreenPolicy(awake); this.policy = awake }
  },
  onDestroy() { this.link.close(); releaseScreen() }
})
