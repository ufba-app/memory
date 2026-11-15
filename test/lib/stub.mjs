// Duble de `ai-memory` e `claude` para os testes do instalador. Tudo vai para STUB_DIR, nunca para a maquina real.
// Uso: node stub.mjs <ai-memory|claude> <args...>. Registra cada chamada em STUB_DIR/calls.jsonl SEM a chave:
// so o que entrou por stdin (tamanho e sha256) e se o ambiente trazia AI_MEMORY_AUTH_TOKEN.
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';

const [name, ...rawArgs] = process.argv.slice(2);
const STATE = process.env.STUB_DIR;
if (!STATE) { console.error('STUB: STUB_DIR nao definido'); process.exit(97); }
const home = process.env.USERPROFILE || process.env.HOME;
const sha = (b) => crypto.createHash('sha256').update(b).digest('hex');
const fail = (code, msg) => { console.error(msg); process.exit(code); };

// Quem passar a chave (aim_...) em argumento leva falha dura.
for (const a of rawArgs) if (/aim_/i.test(a)) fail(99, 'STUB: a chave apareceu em argumento da linha de comando');

const argv = [...rawArgs];
let dataDir = null;
for (let i = 0; i < argv.length;) {
  if (argv[i] === '--data-dir') { dataDir = argv[i + 1]; argv.splice(i, 2); }
  else if (argv[i] === '--language') { argv.splice(i, 2); }
  else i++;
}
const hasAuthEnv = Boolean(process.env.AI_MEMORY_AUTH_TOKEN);
let stdinInfo = null;
const readStdin = () => { const b = fs.readFileSync(0); stdinInfo = { bytes: b.length, sha256: sha(b) }; return b.toString('utf8'); };
const entry = () => ({ t: Date.now(), name, args: rawArgs, cwd: process.cwd(), claudeConfigDir: process.env.CLAUDE_CONFIG_DIR || null, hasAuthEnv, dataDir, stdin: stdinInfo });
const log = () => fs.appendFileSync(path.join(STATE, 'calls.jsonl'), JSON.stringify(entry()) + '\n');
const failing = (process.env.STUB_FAIL || '').split(',').filter(Boolean);
const cmd = argv.slice(0, 2).join(' ');
const jread = (f, d) => { try { return JSON.parse(fs.readFileSync(f, 'utf8')); } catch { return d; } };
const jwrite = (f, v) => { fs.mkdirSync(path.dirname(f), { recursive: true }); fs.writeFileSync(f, JSON.stringify(v, null, 2)); };
const norm = (p) => path.resolve(p).replace(/\\/g, '/').toLowerCase();

if (hasAuthEnv && !(name === 'ai-memory' && argv[0] === 'install-hooks')) {
  log(); fail(98, 'STUB: AI_MEMORY_AUTH_TOKEN so pode estar no ambiente de install-hooks');
}

if (name === 'claude') {
  const key = process.env.CLAUDE_CONFIG_DIR || 'default';
  const f = path.join(STATE, 'mcp.json');
  const db = jread(f, {});
  db[key] = db[key] || {};
  if (argv[0] === 'mcp' && argv[1] === 'get') {
    log(); if (!db[key][argv[2]]) fail(1, 'No MCP server found with name: ' + argv[2]);
    console.log(`${argv[2]}: ${db[key][argv[2]]}`); process.exit(0);
  }
  if (argv[0] === 'mcp' && argv[1] === 'add') {
    log(); if (failing.includes('mcp-add')) fail(1, 'STUB: falha forcada em mcp add');
    const rest = argv.slice(2); const pos = [];
    for (let i = 0; i < rest.length; i++) { if (rest[i].startsWith('--')) { i++; continue; } pos.push(rest[i]); }
    db[key][pos[0]] = pos[1]; jwrite(f, db); console.log('Added HTTP MCP server ' + pos[0]); process.exit(0);
  }
  if (argv[0] === 'mcp' && argv[1] === 'remove') { log(); delete db[key][argv[argv.length - 1]]; jwrite(f, db); console.log('Removed'); process.exit(0); }
  log(); fail(2, 'STUB claude: comando nao suportado: ' + argv.join(' '));
}

// ---- ai-memory ----
const version = process.env.STUB_AIM_VERSION || '3.4.6';
const serversFile = () => path.join(dataDir, 'servers.json');
const hooksFile = () => path.join(process.env.CLAUDE_CONFIG_DIR || path.join(home, '.claude'), 'settings.json');

if (argv[0] === '--version') { log(); console.log('ai-memory ' + version); process.exit(0); }

if (cmd === 'server add') {
  if (!dataDir) { log(); fail(2, 'STUB: --data-dir obrigatorio'); }
  const nm = argv[2]; const rest = argv.slice(3); let url = null; const roots = []; let stdinFlag = false;
  for (let i = 0; i < rest.length; i++) {
    if (rest[i] === '--url') url = rest[++i];
    else if (rest[i] === '--root') roots.push(rest[++i]);
    else if (rest[i] === '--auth-token-stdin') stdinFlag = true;
    else if (rest[i] === '--auth-token') { log(); fail(99, 'STUB: --auth-token proibido'); }
  }
  if (!stdinFlag) { log(); fail(2, 'STUB: so aceito --auth-token-stdin'); }
  const tok = readStdin().split(/\r?\n/)[0];
  log();
  if (failing.includes('server-add')) fail(1, 'STUB: falha forcada em server add');
  const db = jread(serversFile(), {}); const prev = db[nm];
  db[nm] = { url, roots: roots.length ? roots : prev ? prev.roots : [] };
  jwrite(serversFile(), db);
  fs.mkdirSync(path.join(dataDir, 'auth-tokens'), { recursive: true });
  fs.writeFileSync(path.join(dataDir, 'auth-tokens', nm), tok);
  console.log('Registered server profile `' + nm + '`.'); process.exit(0);
}
if (cmd === 'server list') {
  log(); const db = jread(serversFile(), {});
  console.log(JSON.stringify(Object.entries(db).map(([n, p]) => ({ name: n, url: p.url, roots: p.roots, token: 'present' })), null, 2)); process.exit(0);
}
if (cmd === 'server remove') {
  log(); const db = jread(serversFile(), {}); delete db[argv[2]]; jwrite(serversFile(), db);
  fs.rmSync(path.join(dataDir, 'auth-tokens', argv[2]), { force: true }); console.log('Removed'); process.exit(0);
}
if (argv[0] === 'install-hooks') {
  log();
  if (failing.includes('install-hooks')) fail(1, 'STUB: falha forcada em install-hooks');
  if (!dataDir) fail(2, 'STUB: --data-dir obrigatorio');
  if (!process.env.AI_MEMORY_AUTH_TOKEN) fail(2, 'STUB: sem AI_MEMORY_AUTH_TOKEN no ambiente');
  if (!argv.includes('--apply')) fail(2, 'STUB: esperava --apply');
  fs.mkdirSync(dataDir, { recursive: true });
  fs.writeFileSync(path.join(dataDir, 'auth-token'), process.env.AI_MEMORY_AUTH_TOKEN);
  fs.writeFileSync(path.join(dataDir, 'auth-header'), 'Authorization: Bearer ' + process.env.AI_MEMORY_AUTH_TOKEN);
  const f = hooksFile(); const cur = jread(f, {});
  if (fs.existsSync(f)) fs.copyFileSync(f, f + '.bak-stub');
  cur.hooks = { SessionStart: [{ command: `ai-memory hook --event session-start --agent claude-code --data-dir "${dataDir}"` }] };
  jwrite(f, cur); console.log('hooks applied'); process.exit(0);
}
if (argv[0] === 'uninstall') {
  log(); const f = hooksFile(); const cur = jread(f, null);
  if (cur) { delete cur.hooks; jwrite(f, cur); }
  console.log('hooks removed'); process.exit(0);
}
if (argv[0] === 'hook' && argv.includes('--check-capture')) {
  readStdin(); log();
  const db = jread(serversFile(), {});
  let dir = process.cwd(); let server = null;
  for (;;) {
    const f = path.join(dir, '.ai-memory.toml');
    if (fs.existsSync(f)) { const m = /server\s*=\s*"([^"]+)"/.exec(fs.readFileSync(f, 'utf8')); server = m ? m[1] : null; break; }
    const up = path.dirname(dir); if (up === dir) break; dir = up;
  }
  let res = 'install-default';
  if (server) {
    const p = db[server];
    if (!p) res = 'rejected-unknown-profile';
    else if (!p.roots.length) res = 'rejected-roots-required';
    else res = p.roots.some((r) => norm(process.cwd()).startsWith(norm(r) + '/')) ? 'marker' : 'rejected-outside-roots';
  }
  console.log(JSON.stringify({ server_resolution: res, policy_admits_capture: res === 'marker' })); process.exit(0);
}
log(); fail(2, 'STUB ai-memory: comando nao suportado: ' + argv.join(' '));
