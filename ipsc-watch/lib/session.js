// Transport-independent full snapshots. Time values are integer milliseconds.
export function initialState() {
  return { runId: null, sequence: -1, phase: 'idle', shots: [], source: null }
}
export function acceptSnapshot(state, packet) {
  if (!packet || packet.version !== 1 || typeof packet.runId !== 'string' ||
      !packet.runId.length || packet.runId.length > 100 ||
      !Number.isSafeInteger(packet.sequence) || packet.sequence < 0 ||
      !['running', 'finished'].includes(packet.phase) ||
      !['demo', 'timer'].includes(packet.source) ||
      !Array.isArray(packet.shots) || packet.shots.length > 1000) return state
  let previous = 0
  for (const time of packet.shots) {
    if (!Number.isSafeInteger(time) || time <= previous || time > 86400000) return state
    previous = time
  }
  // A source must reuse runId until completion. New runs require explicit reset.
  if (state.runId !== null && packet.runId !== state.runId) return state
  if (packet.sequence <= state.sequence || state.phase === 'finished') return state
  if (packet.shots.length < state.shots.length ||
      state.shots.some((time, index) => time !== packet.shots[index])) return state
  if (state.source !== null && packet.source !== state.source) return state
  return { runId: packet.runId, sequence: packet.sequence, phase: packet.phase,
    source: packet.source, shots: packet.shots.slice() }
}
export function metrics(state) {
  const count = state.shots.length
  return { count, total: count ? state.shots[count - 1] : 0,
    split: count > 1 ? state.shots[count - 1] - state.shots[count - 2] : null }
}
export function seconds(ms) { return (ms / 1000).toFixed(2) }
export function keepAwake(mode, phase) {
  return mode === 'training' || (mode === 'run' && phase === 'running')
}
