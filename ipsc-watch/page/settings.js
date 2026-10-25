import { replace } from '@zos/router'
import { getMode, setMode, getDelay, getDelayMode, getDelayRange } from '../lib/settings'
import { releaseScreen } from '../lib/screen'
import { label, button, update } from '../lib/ui'
Page({
  build() {
    releaseScreen()
    label('Настройки', 90, 30, 300, 45, 30)
    label('Версия 0.7.0', 90, 79, 300, 24, 18, 0x97a5b4)
    this.delay = button('', 55, 126, 370, 84, () => replace({url:'page/delay'}))
    this.delayMode = label('', 55, 218, 370, 30, 18, 0x97a5b4)
    this.training = button('', 55, 282, 370, 54, () => this.choose('training'))
    this.run = button('', 55, 346, 370, 54, () => this.choose('run'))
    button('Назад', 145, 413, 190, 48, () => replace({ url: 'page/index' }))
    this.refresh()
  },
  choose(mode) { setMode(mode); this.refresh() },
  refresh() {
    const mode = getMode(), random = getDelayMode() === 'random', range = getDelayRange()
    update(this.delay, 'Задержка: ' + (random ? range.min + '–' + range.max : getDelay()) + ' с')
    update(this.delayMode, (random ? 'Случайная' : 'Фиксированная') + ' · таймер телефона')
    update(this.training, (mode === 'training' ? '● ' : '○ ') + 'Экран: всю тренировку')
    update(this.run, (mode === 'run' ? '● ' : '○ ') + 'Экран: только проход')
  }
})
