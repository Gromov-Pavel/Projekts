import { BaseSideService } from '@zeppos/zml/base-side'

// Identity is confined to this Side Service; authorization still requires matching the phone's code.
const client = Array.from({length:32}, () => Math.floor(Math.random() * 16).toString(16)).join('')
async function forward(req, res) {
  const command = req.method === 'IPSC_COMMAND'
  try {
    if (command && (!Array.isArray(req.params?.packet) || req.params.packet.length !== 12 || !/^[0-9a-f]{32}$/.test(req.params.session || ''))) {
      res(null, {error:'Неверная команда'}); return
    }
    const options = {
      url:'http://127.0.0.1:19373/v1/' + (command ? 'command' : 'state'),
      method:command ? 'POST' : 'GET', timeout:2500,
      headers:{'X-IPSC-Bridge':'1','X-IPSC-Client':client,'Content-Type':'application/json'},
    }
    if (command) {
      options.headers['X-IPSC-Session'] = req.params.session
      options.body = JSON.stringify({packet:req.params.packet})
    }
    const response = await fetch(options)
    const body = typeof response.body === 'string' ? JSON.parse(response.body) : response.body
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
