import { LocalStorage } from '@zos/storage'
const storage = new LocalStorage()
export function getMode() { return storage.getItem('screenMode') === 'training' ? 'training' : 'run' }
export function setMode(mode) { storage.setItem('screenMode', mode === 'training' ? 'training' : 'run') }

export function getDelay() {
  const raw = storage.getItem('startDelay')
  if (raw === undefined || raw === null || raw === '') return 3
  const value = Number(raw)
  return Number.isInteger(value) && value >= 0 && value <= 60 ? value : 3
}
export function setDelay(value) {
  if (Number.isInteger(value) && value >= 0 && value <= 60) storage.setItem('startDelay', value)
}

export function getDelayMode() { return storage.getItem('delayMode') === 'random' ? 'random' : 'fixed' }
export function setDelayMode(mode) {
  if (mode === 'random' || mode === 'fixed') storage.setItem('delayMode', mode)
}
export function getDelayRange() {
  try {
    const range = JSON.parse(storage.getItem('randomDelayRange') || 'null')
    if (range && Number.isInteger(range.min) && Number.isInteger(range.max) &&
      range.min >= 0 && range.max <= 60 && range.min <= range.max) return {min:range.min,max:range.max}
  } catch (_) {}
  return {min:3,max:6}
}
export function setDelayRange(min, max) {
  if (Number.isInteger(min) && Number.isInteger(max) && min >= 0 && max <= 60 && min <= max)
    storage.setItem('randomDelayRange', JSON.stringify({min,max}))
}
export function getStartDelayMs() {
  if (getDelayMode() === 'fixed') return getDelay() * 1000
  const range = getDelayRange()
  return range.min * 1000 + Math.floor(Math.random() * ((range.max - range.min) * 1000 + 1))
}
