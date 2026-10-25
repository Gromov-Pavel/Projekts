export const SERVICE = 'dfc00001-8e4f-4d3c-9628-37cf53e51b18'
export const STATE = 'dfc00002-8e4f-4d3c-9628-37cf53e51b18'
export const COMMAND = 'dfc00003-8e4f-4d3c-9628-37cf53e51b18'
export const sameUuid = (a, b) => String(a).replace(/-/g, '').toLowerCase() === String(b).replace(/-/g, '').toLowerCase()

export function decodeState(data) {
  if (!(data instanceof ArrayBuffer) || data.byteLength !== 20) return null
  const b = new DataView(data), flags = b.getUint8(1), phase = flags & 15
  if (b.getUint8(0) !== 1 || phase > 4 || (flags & 128)) return null
  const count = b.getUint16(2, true), total = b.getUint32(12, true), rawSplit = b.getUint32(16, true)
  const split = rawSplit === 0xffffffff ? null : rawSplit
  if (b.getUint32(8, true) === 0 && (flags !== 4 || count !== 0 ||
    b.getUint32(4, true) < 100000 || b.getUint32(4, true) > 999999)) return null
  if (count > 10000 || total > 86400000 || (count === 0 && total !== 0) ||
    (count > 0 && total === 0) || (count < 2 && split !== null) ||
    (count >= 2 && (split === null || split <= 0 || split > total))) return null
  return {run: b.getUint32(4, true), revision: b.getUint32(8, true), phase,
    phone: !!(flags & 16), control: !!(flags & 32), failed: !!(flags & 64), count, total, split}
}

export function acceptState(previous, next) {
  if (!next) return previous
  if (previous && next.revision <= previous.revision) return previous
  if (previous && previous.revision > 0 && next.run === previous.run &&
    (next.phone !== previous.phone || next.count < previous.count || next.total < previous.total ||
      (next.count === previous.count && (next.total !== previous.total || next.split !== previous.split)) ||
      (previous.phase === 3 && [1, 2].includes(next.phase)))) return previous
  return next
}

export function commandPacket(state, start, id) {
  if (!state || !state.control || id < 1 || id > 65535 ||
    (start ? [1, 2, 4].includes(state.phase) : ![1, 2].includes(state.phase))) return null
  const data = new ArrayBuffer(12), b = new DataView(data)
  b.setUint8(0, 1); b.setUint8(1, start ? 1 : 2)
  b.setUint16(2, id, true); b.setUint32(4, state.run, true)
  b.setUint32(8, state.revision, true)
  return data
}
