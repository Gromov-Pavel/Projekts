import { setPageBrightTime, resetPageBrightTime, pauseDropWristScreenOff,
  resetDropWristScreenOff } from '@zos/display'
export function applyScreenPolicy(awake) {
  if (awake) {
    setPageBrightTime({ brightTime: 2147483000 })
    pauseDropWristScreenOff({ duration: 0 })
  } else releaseScreen()
}
export function releaseScreen() {
  resetPageBrightTime()
  resetDropWristScreenOff()
}
