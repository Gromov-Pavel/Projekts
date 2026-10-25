import { replace } from '@zos/router'
import { getMode, setMode, getDelay, setDelay } from '../lib/settings'
import { releaseScreen } from '../lib/screen'
import { label, button, update } from '../lib/ui'
Page({
  build() {
    releaseScreen()
    label('Настройки', 90, 30, 300, 45, 30)
    label('Версия 0.6.0', 90, 79, 300, 24, 18, 0x97a5b4)
    label('Задержка старта', 65, 112, 350, 36, 25)
    button('−', 84, 160, 76, 64, () => this.delay(-1))
    this.delayValue = label('', 164, 160, 152, 64, 36)
    button('+', 320, 160, 76, 64, () => this.delay(1))
    label('Таймер телефона · 0–60 с', 55, 234, 370, 30, 18, 0x97a5b4)
    this.training = button('', 55, 282, 370, 54, () => this.choose('training'))
    this.run = button('', 55, 346, 370, 54, () => this.choose('run'))
    button('Назад', 145, 413, 190, 48, () => replace({ url: 'page/index' }))
    this.refresh()
  },
  delay(step) { setDelay(Math.max(0, Math.min(60, getDelay() + step))); this.refresh() },
  choose(mode) { setMode(mode); this.refresh() },
  refresh() {
    const mode = getMode()
    update(this.delayValue, getDelay() + ' с')
    update(this.training, (mode === 'training' ? '● ' : '○ ') + 'Экран: всю тренировку')
    update(this.run, (mode === 'run' ? '● ' : '○ ') + 'Экран: только проход')
  }
})
