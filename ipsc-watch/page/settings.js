import { replace } from '@zos/router'
import { getMode, setMode } from '../lib/settings'
import { releaseScreen } from '../lib/screen'
import { label, button, update } from '../lib/ui'
Page({
  build() {
    releaseScreen()
    label('Настройки', 90, 35, 300, 45, 30)
    label('Не гасить экран', 65, 105, 350, 40, 26)
    this.training = button('', 55, 175, 370, 64, () => this.choose('training'))
    this.run = button('', 55, 255, 370, 64, () => this.choose('run'))
    button('Назад', 145, 365, 190, 56, () => replace({ url: 'page/index' }))
    this.refresh()
  },
  choose(mode) { setMode(mode); this.refresh() },
  refresh() {
    const mode = getMode()
    update(this.training, (mode === 'training' ? '● ' : '○ ') + 'Всю тренировку')
    update(this.run, (mode === 'run' ? '● ' : '○ ') + 'Только во время прохода')
  }
})
