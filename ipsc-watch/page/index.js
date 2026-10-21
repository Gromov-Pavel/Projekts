import { replace } from '@zos/router'
import { initialState, acceptSnapshot, metrics, seconds, keepAwake } from '../lib/session'
import { applyScreenPolicy, releaseScreen } from '../lib/screen'
import { getMode } from '../lib/settings'
import { label, button, update } from '../lib/ui'

const DEMO = [1250, 1640, 2020, 2460, 2830, 3250]
Page({
  onInit() { this.state = initialState(); this.timer = null; this.policy = null },
  build() {
    label('Тренировка', 90, 24, 300, 34, 26)
    this.status = label('Нет подключения', 65, 68, 350, 28, 20, 0xffbb66)
    this.total = label('0.00', 35, 110, 410, 112, 92)
    label('ВРЕМЯ, С', 130, 218, 220, 24, 18, 0x97a5b4)
    label('СПЛИТ, С', 55, 262, 180, 26, 18, 0x97a5b4)
    label('ВЫСТРЕЛЫ', 245, 262, 180, 26, 18, 0x97a5b4)
    this.split = label('—', 55, 292, 180, 54, 40)
    this.count = label('0', 245, 292, 180, 54, 40)
    this.demoButton = button('Демо', 72, 365, 158, 52, () => this.toggleDemo())
    button('Настройки', 245, 365, 163, 52, () => {
      this.stopDemo(); replace({ url: 'page/settings' })
    })
    this.render()
  },
  render() {
    const m = metrics(this.state)
    update(this.total, seconds(m.total)); update(this.count, String(m.count))
    update(this.split, m.split === null ? '—' : seconds(m.split))
    update(this.status, this.state.source === 'demo'
      ? (this.state.phase === 'finished' ? 'ДЕМО · завершено' : 'ДЕМО · выстрелы')
      : 'Нет подключения')
    const awake = keepAwake(getMode(), this.state.phase)
    if (this.policy !== awake) { applyScreenPolicy(awake); this.policy = awake }
  },
  toggleDemo() {
    if (this.timer !== null) { this.stopDemo(); return }
    this.state = acceptSnapshot(initialState(), { version: 1, runId: 'demo',
      sequence: 0, phase: 'running', source: 'demo', shots: [] })
    update(this.demoButton, 'Стоп демо'); this.render()
    let count = 0
    this.timer = setInterval(() => {
      count += 1
      this.state = acceptSnapshot(this.state, { version: 1, runId: 'demo',
        sequence: count, phase: count === DEMO.length ? 'finished' : 'running',
        source: 'demo', shots: DEMO.slice(0, count) })
      this.render()
      if (count === DEMO.length) { clearInterval(this.timer); this.timer = null; update(this.demoButton, 'Ещё демо') }
    }, 800)
  },
  stopDemo() {
    if (this.timer !== null) { clearInterval(this.timer); this.timer = null }
    if (this.state.phase === 'running') this.state = { ...this.state, phase: 'finished' }
    if (this.demoButton) update(this.demoButton, 'Демо')
    if (this.status) this.render()
  },
  onDestroy() { if (this.timer !== null) clearInterval(this.timer); releaseScreen() }
})
