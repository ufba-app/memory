// Servidores FALSOS (127.0.0.1, sem dependencias) que imitam o contrato da API da ufba.app e o /identity do memory.
// Nada aqui fala com a internet. A chave emitida e um canario (`aim_CANARY_...`) facil de procurar.
import http from 'node:http';
import crypto from 'node:crypto';

const hex = (n) => crypto.randomBytes(n).toString('hex');
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

function readBody(req) {
  return new Promise((resolve) => {
    const chunks = [];
    req.on('data', (c) => chunks.push(c));
    req.on('end', () => resolve(Buffer.concat(chunks)));
  });
}
const send = (res, status, obj, headers = {}) => {
  const body = obj === undefined ? '' : typeof obj === 'string' ? obj : JSON.stringify(obj);
  res.writeHead(status, { 'content-type': 'application/json', ...headers });
  res.end(body);
};

/**
 * opts:
 *  approveAfterPolls  consultas ao /token antes da aprovacao (padrao 2)
 *  slowDownAtPoll     numero da consulta que responde slow_down (0 = nunca)
 *  deny / expire      access_denied / expired_token no polling
 *  lostResponses      quantas respostas de POST /memory/computers sao perdidas DEPOIS de processadas
 *  computers5xx       quantos POST /memory/computers respondem 503 ANTES de processar
 *  confirm5xx         quantos POST confirm respondem 503
 *  computerLimit      responde 409 computer_limit_reached
 *  manifest           objeto do manifesto (ou funcao (state) => objeto)
 *  manifestStatus     status do manifesto (padrao 200)
 *  memoryUrlOverride  memory_url devolvido pela API (para testar o que nao bate)
 */
export async function startFakes(opts = {}) {
  const o = { approveAfterPolls: 2, slowDownAtPoll: 0, lostResponses: 0, computers5xx: 0, confirm5xx: 0, ...opts };
  const state = {
    requests: [], devices: new Map(), tokens: new Map(), computers: new Map(), files: new Map(),
    issuedKeys: [], activeKeys: new Map(), slowDownSent: 0, polls: 0, lost: 0, fivexx: 0, confirm5xxSent: 0,
    events: [], manifestFetches: 0,
  };
  const ev = (what, extra = {}) => state.events.push({ t: Date.now(), what, ...extra });
  let memUrl = '';
  let apiUrl = '';

  const api = http.createServer(async (req, res) => {
    const url = new URL(req.url, 'http://x');
    const raw = await readBody(req);
    const text = raw.toString('utf8');
    const ct = String(req.headers['content-type'] || '');
    let body = {};
    try { body = ct.includes('json') ? JSON.parse(text || '{}') : Object.fromEntries(new URLSearchParams(text)); } catch { /* invalido */ }
    state.requests.push({ t: Date.now(), method: req.method, path: url.pathname, hasAuth: Boolean(req.headers.authorization), body: url.pathname === '/token' ? { ...body, device_code: '(omitido)' } : { ...body } });
    const bearer = /^Bearer\s+(\S+)$/i.exec(String(req.headers.authorization || ''))?.[1];

    if (req.method === 'GET' && url.pathname === '/memory/install-manifest') {
      state.manifestFetches++;
      const m = typeof o.manifest === 'function' ? o.manifest(state) : o.manifest;
      return send(res, o.manifestStatus ?? 200, m ?? { error: 'memory_unavailable', message: 'Manifesto indisponível.' });
    }
    if (req.method === 'GET' && url.pathname.startsWith('/artifacts/')) {
      const f = state.files.get(url.pathname.slice('/artifacts/'.length));
      if (!f) return send(res, 404, { error: 'not_found' });
      res.writeHead(200, { 'content-type': 'application/octet-stream' });
      return res.end(f);
    }
    if (req.method === 'POST' && url.pathname === '/oauth/device_authorization') {
      if (body.client_id !== 'ufba-installer') return send(res, 400, { error: 'invalid_client', error_description: 'client_id desconhecido' });
      if (body.scope !== 'memory:connect') return send(res, 400, { error: 'invalid_scope', error_description: 'use scope=memory:connect' });
      if (!['windows', 'macos', 'linux'].includes(body.os)) return send(res, 400, { error: 'invalid_request', message: 'os invalido' });
      const device_code = hex(32);
      const user_code = 'BCDF-GHJK';
      state.devices.set(device_code, { user_code, polls: 0, status: 'pending', computerName: body.computer_name, os: body.os });
      ev('device_authorization', { os: body.os, computerName: body.computer_name });
      return send(res, 200, {
        device_code, user_code, verification_uri: 'https://ufba.app/device',
        verification_uri_complete: `https://ufba.app/device?user_code=${user_code}`, expires_in: 600, interval: 1,
      });
    }
    if (req.method === 'POST' && url.pathname === '/token') {
      if (body.grant_type !== 'urn:ietf:params:oauth:grant-type:device_code') return send(res, 400, { error: 'unsupported_grant_type' });
      const d = state.devices.get(body.device_code);
      if (!d || body.client_id !== 'ufba-installer') return send(res, 400, { error: 'invalid_grant', error_description: 'device_code inválido' });
      if (d.status === 'issued') return send(res, 400, { error: 'invalid_grant', error_description: 'device_code já usado' });
      d.polls++; state.polls++;
      ev('poll', { n: d.polls });
      if (o.expire) return send(res, 400, { error: 'expired_token', error_description: 'o código expirou; peça outro' });
      if (o.slowDownAtPoll && d.polls === o.slowDownAtPoll) { state.slowDownSent++; return send(res, 400, { error: 'slow_down', error_description: 'consulte mais devagar' }); }
      if (d.polls < o.approveAfterPolls) return send(res, 400, { error: 'authorization_pending', error_description: 'aguardando a aprovação' });
      if (o.deny) return send(res, 400, { error: 'access_denied', error_description: 'a pessoa negou o pedido' });
      const access_token = 'tok_' + hex(24);
      d.status = 'issued';
      state.tokens.set(access_token, { consumed: false, expiresAt: Date.now() + 600_000, userId: 'u' + hex(4) });
      ev('token_issued');
      return send(res, 200, { access_token, token_type: 'Bearer', expires_in: 600, scope: 'memory:connect' });
    }
    if (url.pathname.startsWith('/memory/computers')) {
      const tk = bearer ? state.tokens.get(bearer) : null;
      if (!tk || tk.consumed || tk.expiresAt < Date.now()) {
        return send(res, 401, { error: 'session_expired', message: 'A autorização do instalador expirou. Rode o instalador de novo.' });
      }
      if (req.method === 'POST' && url.pathname === '/memory/computers') {
        if (state.fivexx < o.computers5xx) { state.fivexx++; ev('computers_5xx'); return send(res, 503, { error: 'memory_unavailable', message: 'A memória está indisponível no momento. Tente de novo em instantes.' }); }
        if (o.computerLimit) return send(res, 409, { error: 'computer_limit_reached', message: 'Você já tem 10 computadores conectados. Remova um para conectar outro.' });
        const known = typeof body.computer_id === 'string' && UUID.test(body.computer_id) ? state.computers.get(body.computer_id) : null;
        const key = 'aim_CANARY_' + hex(16);
        let id;
        if (known && !known.revoked) { id = known.id; state.activeKeys.delete(known.key); known.key = key; known.rotations++; known.confirmed = false; ev('computer_rotated', { id }); }
        else { id = crypto.randomUUID(); state.computers.set(id, { id, key, confirmed: false, rotations: 0, revoked: false, ...body, userId: tk.userId, username: 'u' + tk.userId.slice(1) }); ev('computer_created', { id }); }
        const c = state.computers.get(id);
        Object.assign(c, { name: body.name, os: body.os, agents: body.agents, client_version: body.client_version, install_mode: body.install_mode, username: 'u' + tk.userId.slice(1) });
        state.activeKeys.set(key, c.username);
        state.issuedKeys.push(key);
        const payload = { computer_id: id, username: c.username, memory_url: o.memoryUrlOverride ?? memUrl, key };
        if (state.lost < o.lostResponses) { state.lost++; ev('response_lost', { id }); req.socket.destroy(); return; }
        return send(res, 200, payload, { 'cache-control': 'no-store' });
      }
      const m = /^\/memory\/computers\/([^/]+)\/confirm$/.exec(url.pathname);
      if (req.method === 'POST' && m) {
        if (state.confirm5xxSent < o.confirm5xx) { state.confirm5xxSent++; return send(res, 503, { error: 'memory_unavailable', message: 'indisponível' }); }
        const c = state.computers.get(m[1]);
        if (!c) return send(res, 404, { error: 'computer_not_found', message: 'Computador não encontrado.' });
        c.confirmed = true; tk.consumed = true; ev('confirm', { id: c.id });
        res.writeHead(204); return res.end();
      }
    }
    return send(res, 404, { error: 'not_found', message: 'rota desconhecida' });
  });

  const memory = http.createServer(async (req, res) => {
    await readBody(req);
    state.requests.push({ t: Date.now(), method: req.method, path: new URL(req.url, 'http://x').pathname, server: 'memory', hasAuth: Boolean(req.headers.authorization) });
    if (req.url === '/identity') {
      const k = /^Bearer\s+(\S+)$/i.exec(String(req.headers.authorization || ''))?.[1];
      const user = k ? state.activeKeys.get(k) : null;
      if (!user) return send(res, 401, { error: 'unauthorized' });
      ev('identity_ok', { user });
      return send(res, 200, { version: '3.4.6', level: 'user', operator: `user:${user}`, distinguishes_operators: true });
    }
    return send(res, 404, { error: 'not_found' });
  });

  await new Promise((r) => api.listen(0, '127.0.0.1', r));
  await new Promise((r) => memory.listen(0, '127.0.0.1', r));
  apiUrl = `http://127.0.0.1:${api.address().port}`;
  memUrl = `http://127.0.0.1:${memory.address().port}`;
  return {
    apiUrl, memUrl, state, opts: o,
    addFile: (name, buf) => state.files.set(name, buf),
    close: () => new Promise((r) => { api.closeAllConnections?.(); memory.closeAllConnections?.(); api.close(() => memory.close(() => r())); }),
  };
}
