import { LocalStorage } from '@zos/storage'
const storage = new LocalStorage()
export function getMode() { return storage.getItem('screenMode') === 'training' ? 'training' : 'run' }
export function setMode(mode) { storage.setItem('screenMode', mode === 'training' ? 'training' : 'run') }
