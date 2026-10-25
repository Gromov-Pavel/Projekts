import { replace } from '@zos/router'
import { getDelay, setDelay, getDelayMode, setDelayMode, getDelayRange, setDelayRange } from '../lib/settings'
import { label, button, update, show } from '../lib/ui'
Page({
  build() {
    label('Задержка старта', 65, 30, 350, 44, 28)
    this.mode = button('', 64, 92, 352, 60, () => {
      setDelayMode(getDelayMode() === 'random' ? 'fixed' : 'random'); this.refresh()
    })
    label('Таймер телефона · 0–60 с', 55, 160, 370, 26, 18, 0x97a5b4)
    this.lowerLabel = label('', 110, 194, 260, 30, 23)
    button('−', 75, 231, 76, 60, () => this.change(true, -1))
    this.lower = label('', 155, 231, 170, 60, 36)
    button('+', 329, 231, 76, 60, () => this.change(true, 1))
    this.upperLabel = label('До, с', 176, 299, 128, 30, 23)
    this.minusUpper = button('−', 75, 336, 76, 60, () => this.change(false, -1))
    this.upper = label('', 155, 336, 170, 60, 36)
    this.plusUpper = button('+', 329, 336, 76, 60, () => this.change(false, 1))
    button('Назад', 145, 413, 190, 48, () => replace({url:'page/settings'}))
    this.refresh()
  },
  change(lower, step) {
    if (getDelayMode() === 'fixed') setDelay(Math.max(0, Math.min(60, getDelay() + step)))
    else {
      const range = getDelayRange()
      if (lower) range.min = Math.max(0, Math.min(range.max, range.min + step))
      else range.max = Math.max(range.min, Math.min(60, range.max + step))
      setDelayRange(range.min, range.max)
    }
    this.refresh()
  },
  refresh() {
    const random = getDelayMode() === 'random', range = getDelayRange()
    update(this.mode, random ? 'Случайная' : 'Фиксированная')
    update(this.lowerLabel, random ? 'От, с' : 'Задержка, с')
    update(this.lower, String(random ? range.min : getDelay()))
    update(this.upper, String(range.max))
    for (const widget of [this.upperLabel,this.minusUpper,this.upper,this.plusUpper]) show(widget,random)
  }
})
