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
