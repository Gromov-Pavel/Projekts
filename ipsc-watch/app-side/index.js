import { BaseSideService, settingsLib } from '@zeppos/zml/base-side'

// Pair credentials live in this app's Zepp storage, never in logs or watch packets.
let identity
function credentials() {
  if (identity) return identity
  try {
    const saved = JSON.parse(settingsLib.getItem('ipsc-pair-v1') || 'null')
    if (saved && /^[0-9a-f]{32}$/.test(saved.client) && (!saved.trust || /^[0-9a-f]{64}$/.test(saved.trust))) identity = saved
  } catch (_) {}
  if (!identity) {
    identity = {client:Array.from({length:32}, () => Math.floor(Math.random() * 16).toString(16)).join('')}
    settingsLib.setItem('ipsc-pair-v1', JSON.stringify(identity))
  }
  return identity
}
async function forward(req, res) {
  const command = req.method === 'IPSC_COMMAND'
  try {
    if (command && (!Array.isArray(req.params?.packet) || req.params.packet.length !== 12 || !/^[0-9a-f]{32}$/.test(req.params.session || ''))) {
      res(null, {error:'Неверная команда'}); return
    }
    if (command && req.params.delayMs !== undefined && (!Number.isInteger(req.params.delayMs) || req.params.delayMs < 0 || req.params.delayMs > 60000)) {
      res(null, {error:'Задержка должна быть от 0 до 60 с'}); return
    }
    const pair = credentials()
    const options = {
      url:'http://127.0.0.1:19373/v1/' + (command ? 'command' : 'state'),
      method:command ? 'POST' : 'GET', timeout:2500,
      headers:{'X-IPSC-Bridge':'1','X-IPSC-Client':pair.client,'Content-Type':'application/json'},
    }
    if (pair.trust) options.headers['X-IPSC-Trust'] = pair.trust
    if (command) {
      options.headers['X-IPSC-Session'] = req.params.session
      options.body = JSON.stringify({packet:req.params.packet, ...(req.params.delayMs === undefined ? {} : {delayMs:req.params.delayMs})})
    }
    const response = await fetch(options)
    const body = typeof response.body === 'string' ? JSON.parse(response.body) : response.body
    if (body && /^[0-9a-f]{64}$/.test(body.trust || '')) {
      pair.trust = body.trust
      settingsLib.setItem('ipsc-pair-v1', JSON.stringify(pair))
      delete body.trust
    }
    res(null, body && typeof body === 'object' ? body : {error:'Нет ответа IPSC'})
  } catch (error) {
    console.log("IPSC loopback fetch failed", String(error?.message || error))
    res(null, {error:'Включите связь в IPSC на телефоне'})
  }
}
AppSideService(BaseSideService({
  onInit() {},
  onRequest(req, res) {
    if (req.method === 'IPSC_STATE' || req.method === 'IPSC_COMMAND') return forward(req, res)
    res(null, {error:'Неизвестный запрос'})
  },
  onRun() {}, onDestroy() {},
}))
