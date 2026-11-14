// Testes do instalador (.ps1 e .sh) contra servidores FALSOS em 127.0.0.1 e stubs de `ai-memory` e `claude`.
// Cada caso roda num mundo descartavel (HOME, LOCALAPPDATA, PATH proprios). Nada toca a instalacao real.
import { test, describe, before, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { adapters, World, buildLauncher, tmpRoot, snapshot, filesContaining, sha256, isWin } from './lib/harness.mjs';
import { startFakes } from './lib/servers.mjs';

const root = tmpRoot();
let launcher = null;
before(() => { if (isWin) launcher = buildLauncher(root); });
after(() => { fs.rmSync(root, { recursive: true, force: true }); });

for (const adapter of Object.values(adapters)) {
  if (process.env.UFBA_TEST_ONLY && process.env.UFBA_TEST_ONLY !== adapter.name) continue;
  const skip = adapter.available() ? false : `${adapter.name}: interpretador nao disponivel nesta maquina (roda no CI)`;
  describe(`instalador ${adapter.name}`, { skip, concurrency: false }, () => {
    const cases = [];
    /** Cria mundo + fakes, roda `fn`, limpa tudo. */
    const scenario = (name, opts, fn) => test(name, async () => {
      const w = new World(root, adapter, launcher);
      const fakes = await startFakes(opts);
      try { await w.provision(fakes); await fn(w, fakes); } finally { await fakes.close(); w.cleanup(); }
    });
    const keyOf = (fakes) => fakes.state.issuedKeys.at(-1);
    // powershell.exe cria homeAppDataRoaming sozinho ao iniciar (ruido do interpretador, nao do instalador)
    const dataSnapshot = (w) => snapshot(w.dir, [w.stub, path.join(w.home, 'AppData')]);
    const call = (w, name, pred = () => true) => w.calls().filter((c) => c.name === name && pred(c));
    const argsOf = (c) => c.args.join(' ');

    scenario('fresh: instala o ai-memory, grava hooks por stdin/ambiente, registra o MCP e confirma depois de gravar', {}, async (w, fakes) => {
      w.stubs('claude'); fs.mkdirSync(w.claudeDir, { recursive: true });
      const r = await w.run(fakes, { yes: true });
      assert.equal(r.code, 0, r.all);
      assert.match(r.out, /Modo: fresh/);
      assert.ok(fs.existsSync(path.join(w.binInstallDir, adapter.name === 'ps1' ? 'ai-memory.exe' : 'ai-memory')), 'binario instalado');
      const hooks = call(w, 'ai-memory', (c) => c.args.includes('install-hooks'));
      assert.equal(hooks.length, 1);
      const h = argsOf(hooks[0]);
      assert.match(h, /--data-dir /); assert.match(h, new RegExp(`--server-url ${fakes.memUrl}`)); assert.match(h, /--capture-mode allowlist/); assert.match(h, /--apply/);
      assert.equal(hooks[0].hasAuthEnv, true, 'a chave entra pelo ambiente do filho');
      assert.equal(hooks[0].claudeConfigDir, null, 'conta padrao nao seta CLAUDE_CONFIG_DIR');
      const mcp = call(w, 'claude', (c) => c.args[1] === 'add');
      assert.equal(mcp.length, 1);
      assert.equal(argsOf(mcp[0]), `mcp add --transport http --scope user ufba ${fakes.apiUrl}/mcp`);
      assert.equal(w.calls().filter((c) => /install-(mcp|instructions|skills)/.test(argsOf(c))).length, 0, 'nunca install-mcp/instructions/skills');
      const confirm = fakes.state.events.find((e) => e.what === 'confirm');
      assert.ok(confirm, 'confirmou');
      assert.ok(confirm.t >= hooks[0].t, 'confirmou DEPOIS de gravar a chave');
      assert.ok(fakes.state.events.some((e) => e.what === 'identity_ok'), 'auto-teste /identity');
      const st = w.state();
      assert.equal(st.install_mode, 'fresh'); assert.equal(st.computer_id, fakes.state.events.find((e) => e.what === 'computer_created').id);
      assert.match(r.out, /Para desfazer/);
      assert.equal(fakes.state.computers.size, 1);
      assert.equal([...fakes.state.computers.values()][0].install_mode, 'fresh');
    });

    scenario('fresh com contas do Maestri: lista, aceita todas com --yes e usa CLAUDE_CONFIG_DIR por conta', {}, async (w, fakes) => {
      w.stubs('claude'); fs.mkdirSync(w.claudeDir, { recursive: true });
      const a = w.maestri('conta-a'); const b = w.maestri('conta-b');
      const r = await w.run(fakes, { yes: true });
      assert.equal(r.code, 0, r.all);
      assert.match(r.out, /Maestri: conta-a/); assert.match(r.out, /Maestri: conta-b/);
      const hooks = call(w, 'ai-memory', (c) => c.args.includes('install-hooks'));
      assert.equal(hooks.length, 3);
      const real = (x) => x && fs.realpathSync.native(x);
      const dirs = hooks.map((c) => real(c.claudeConfigDir));
      assert.ok(dirs.includes(real(a)) && dirs.includes(real(b)) && dirs.includes(null), JSON.stringify(dirs));
      assert.equal(call(w, 'claude', (c) => c.args[1] === 'add').length, 3);
      assert.equal(Object.keys(w.mcp()).length, 3);
      assert.equal(w.state().targets.length, 3);
    });

    scenario('profile (com hooks existentes): registra o perfil por stdin, NAO roda install-hooks e nao toca nos hooks', {}, async (w, fakes) => {
      w.stubs('claude', 'ai-memory'); w.seedHooks(w.claudeDir);
      const before = fs.readFileSync(path.join(w.claudeDir, 'settings.json'));
      const r = await w.run(fakes, { yes: true, roots: [w.repos] });
      assert.equal(r.code, 0, r.all);
      assert.match(r.out, /Modo: profile/);
      assert.equal(call(w, 'ai-memory', (c) => c.args.includes('install-hooks')).length, 0, 'install-hooks nunca em profile');
      const add = call(w, 'ai-memory', (c) => c.args.includes('server') && c.args.includes('add'));
      assert.equal(add.length, 1);
      const a = argsOf(add[0]);
      assert.match(a, /--data-dir /); assert.match(a, /server add ufba/); assert.match(a, new RegExp(`--url ${fakes.memUrl}`)); assert.match(a, /--auth-token-stdin/);
      assert.equal(add[0].args.includes('--root'), true);
      assert.equal(add[0].hasAuthEnv, false, 'chave de perfil nao vai por ambiente');
      const key = keyOf(fakes);
      assert.equal(add[0].stdin.sha256, sha256(key + (add[0].stdin.bytes === key.length + 2 ? '\r\n' : '\n')), 'a chave exata entrou por stdin');
      assert.deepEqual(fs.readFileSync(path.join(w.claudeDir, 'settings.json')), before, 'hooks intactos');
      assert.ok(fs.existsSync(path.join(w.dataDir, 'auth-tokens', 'ufba')));
      assert.equal(w.state().install_mode, 'profile');
      assert.match(r.out, /server_resolution|captura para a ufba\.app/);
      assert.equal(call(w, 'claude', (c) => c.args[1] === 'add').length, 1);
    });

    scenario('profile com cliente menor que 3.4.6: para, explica e nao altera nada (nem faz login)', {}, async (w, fakes) => {
      w.stubs('claude', 'ai-memory'); w.seedHooks(w.claudeDir);
      const snap = dataSnapshot(w);
      const r = await w.run(fakes, { yes: true, roots: [w.repos] }, { extraEnv: { STUB_AIM_VERSION: '3.4.5' } });
      assert.equal(r.code, 3, r.all);
      assert.match(r.out, /3\.4\.5/); assert.match(r.out, /nunca atualiza/); assert.match(r.out, /Nada foi alterado/);
      assert.deepEqual(dataSnapshot(w), snap);
      assert.equal(fakes.state.events.filter((e) => e.what === 'device_authorization').length, 0);
      assert.equal(call(w, 'ai-memory', (c) => c.args.includes('add') || c.args.includes('install-hooks')).length, 0);
    });

    scenario('detecta ai-memory existente fora do PATH (pasta de instalacao padrao) e para se for antigo', {}, async (w, fakes) => {
      w.stubs('claude'); w.seedHooks(w.claudeDir);
      const dir = adapter.name === 'ps1' ? path.join(w.local, 'Programs', 'ai-memory') : path.join(w.home, '.local', 'lib', 'ai-memory');
      if (adapter.name === 'ps1') w.installStubIn(dir, 'ai-memory');
      else { w.installStubIn(dir, 'ai-memory'); }
      const r = await w.run(fakes, { yes: true, roots: [w.repos] }, { extraEnv: { STUB_AIM_VERSION: '3.4.5' } });
      assert.equal(r.code, 3, r.all);
      assert.match(r.out, /Modo: profile/); assert.match(r.out, /3\.4\.5/);
      assert.equal(fakes.state.events.filter((e) => e.what === 'device_authorization').length, 0);
    });

    scenario('profile: agente sem hooks do ai-memory -> para e orienta, sem login', {}, async (w, fakes) => {
      w.stubs('claude', 'ai-memory'); fs.mkdirSync(w.claudeDir, { recursive: true });
      const r = await w.run(fakes, { yes: true, roots: [w.repos] });
      assert.equal(r.code, 3, r.all);
      assert.match(r.out, /SEM hooks/); assert.match(r.out, /install-hooks/);
      assert.equal(fakes.state.events.filter((e) => e.what === 'device_authorization').length, 0);
    });

    scenario('profile: --root e obrigatorio em --yes (com outro perfil ja registrado)', {}, async (w, fakes) => {
      w.stubs('claude', 'ai-memory'); w.seedHooks(w.claudeDir); w.seedProfile('grimorio', [w.repos]);
      const r = await w.run(fakes, { yes: true });
      assert.notEqual(r.code, 0, r.all);
      assert.match(r.all, /-Root|--root/i);
      assert.equal(fakes.state.events.filter((e) => e.what === 'device_authorization').length, 0);
      assert.equal(call(w, 'ai-memory', (c) => c.args.includes('add')).length, 0);
    });

    scenario('profile: segundo perfil com --root passa; rodar de novo sem --root mantem os roots', {}, async (w, fakes) => {
      w.stubs('claude', 'ai-memory'); w.seedHooks(w.claudeDir); w.seedProfile('grimorio', [w.repos]);
      const r1 = await w.run(fakes, { yes: true, roots: [w.repos] });
      assert.equal(r1.code, 0, r1.all);
      const r2 = await w.run(fakes, { yes: true });
      assert.equal(r2.code, 0, r2.all);
      const adds = call(w, 'ai-memory', (c) => c.args.includes('add'));
      assert.equal(adds.length, 2);
      assert.equal(adds[1].args.includes('--root'), false, 'segunda vez sem --root: a doc diz que os roots sao mantidos');
    });

    for (const [label, mode] of [['fresh', 'fresh'], ['profile', 'profile']]) {
      scenario(`dry-run (${label}): nao escreve nada (arvore identica) e nao faz login`, {}, async (w, fakes) => {
        w.stubs('claude'); if (mode === 'profile') { w.stubs('ai-memory'); w.seedHooks(w.claudeDir); } else fs.mkdirSync(w.claudeDir, { recursive: true });
        const snap = dataSnapshot(w);
        const r = await w.run(fakes, { yes: true, dryRun: true, roots: [w.repos] });
        assert.equal(r.code, 0, r.all);
        assert.match(r.out, /SIMULACAO|Simulacao/);
        assert.deepEqual(dataSnapshot(w), snap, 'a arvore nao mudou');
        assert.equal(fakes.state.events.filter((e) => e.what === 'device_authorization').length, 0);
        assert.equal(fakes.state.files.size > 0 && fakes.state.requests.filter((q) => q.path.startsWith('/artifacts/')).length, 0, 'nem baixou o ai-memory');
        assert.equal(call(w, 'claude', (c) => c.args[1] === 'add').length, 0);
      });
    }
    if (adapter.name === 'ps1') {
      scenario('-WhatIf equivale a -DryRun', {}, async (w, fakes) => {
        w.stubs('claude'); fs.mkdirSync(w.claudeDir, { recursive: true });
        const snap = dataSnapshot(w);
        const r = await w.run(fakes, { yes: true, whatIf: true });
        assert.equal(r.code, 0, r.all); assert.deepEqual(dataSnapshot(w), snap);
      });
    }

    scenario('idempotencia: rodar duas vezes (fresh) reaproveita o computador por rotacao e nao duplica nada', {}, async (w, fakes) => {
      w.stubs('claude'); fs.mkdirSync(w.claudeDir, { recursive: true });
      const r1 = await w.run(fakes, { yes: true }); assert.equal(r1.code, 0, r1.all);
      const id1 = w.state().computer_id; const key1 = keyOf(fakes);
      const r2 = await w.run(fakes, { yes: true }); assert.equal(r2.code, 0, r2.all);
      assert.equal(w.state().computer_id, id1); assert.equal(w.state().install_mode, 'fresh', 'o modo nao vira profile na segunda rodada');
      assert.equal(fakes.state.computers.size, 1); assert.equal(fakes.state.computers.get(id1).rotations, 1);
      assert.notEqual(keyOf(fakes), key1);
      assert.equal(Object.values(w.mcp()).reduce((n, m) => n + Object.keys(m).length, 0), 1, 'MCP registrado uma vez so');
      assert.ok(fakes.state.requests.filter((q) => q.path === '/memory/computers').at(-1).body.computer_id === id1, 'mandou o computer_id');
      assert.equal(fakes.state.requests.filter((q) => q.path.startsWith('/artifacts/')).length, 1, 'nao baixou o ai-memory de novo');
    });

    scenario('resposta perdida com computer.json existente: repete com o mesmo computer_id e rotaciona (sem duplicar)', {}, async (w, fakes) => {
      w.stubs('claude'); fs.mkdirSync(w.claudeDir, { recursive: true });
      assert.equal((await w.run(fakes, { yes: true })).code, 0);
      const id = w.state().computer_id;
      fakes.opts.lostResponses = 1;
      const r = await w.run(fakes, { yes: true });
      assert.equal(r.code, 0, r.all);
      assert.ok(fakes.state.events.some((e) => e.what === 'response_lost'));
      assert.equal(fakes.state.computers.size, 1); assert.equal(w.state().computer_id, id);
      assert.equal(fakes.state.computers.get(id).rotations, 2);
      assert.equal(fakes.state.computers.get(id).confirmed, true);
    });

    scenario('resposta perdida na PRIMEIRA instalacao: conclui; so um computador fica confirmado (o orfao e varrido pela API)', {}, async (w, fakes) => {
      w.stubs('claude'); fs.mkdirSync(w.claudeDir, { recursive: true });
      fakes.opts.lostResponses = 1;
      const r = await w.run(fakes, { yes: true });
      assert.equal(r.code, 0, r.all);
      const confirmed = [...fakes.state.computers.values()].filter((c) => c.confirmed);
      assert.equal(confirmed.length, 1); assert.equal(w.state().computer_id, confirmed[0].id);
      assert.equal(fakes.state.computers.size, 2, 'DIVERGENCIA conhecida: o id novo nao e idempotente sem computer_id conhecido');
    });

    scenario('5xx na API: tenta de novo e conclui; 3 falhas seguidas abortam sem gravar chave nem confirmar', { computers5xx: 2 }, async (w, fakes) => {
      w.stubs('claude'); fs.mkdirSync(w.claudeDir, { recursive: true });
      const ok = await w.run(fakes, { yes: true });
      assert.equal(ok.code, 0, ok.all);
      assert.equal(fakes.state.events.filter((e) => e.what === 'computers_5xx').length, 2);
    });
    scenario('3 falhas 5xx seguidas: aborta sem gravar a chave e sem confirmar', { computers5xx: 3 }, async (w, fakes) => {
      w.stubs('claude'); fs.mkdirSync(w.claudeDir, { recursive: true });
      const r = await w.run(fakes, { yes: true });
      assert.notEqual(r.code, 0, r.all);
      assert.equal(call(w, 'ai-memory', (c) => c.args.includes('install-hooks')).length, 0);
      assert.equal(fakes.state.events.filter((e) => e.what === 'confirm').length, 0);
    });

    scenario('falha ao gravar a chave (install-hooks): NAO confirma e orienta a rodar de novo', {}, async (w, fakes) => {
      w.stubs('claude'); fs.mkdirSync(w.claudeDir, { recursive: true });
      const r = await w.run(fakes, { yes: true }, { extraEnv: { STUB_FAIL: 'install-hooks' } });
      assert.notEqual(r.code, 0, r.all);
      assert.match(r.all, /NAO confirmei/);
      assert.equal(fakes.state.events.filter((e) => e.what === 'confirm').length, 0);
      assert.ok(w.state()?.computer_id, 'computer_id guardado para a reinstalacao virar rotacao');
    });

    scenario('hash do instalador diverge do manifesto: aborta sem instalar e sem login', {}, async (w, fakes) => {
      w.stubs('claude'); fs.mkdirSync(w.claudeDir, { recursive: true });
      await w.provision(fakes, { installerHashes: { 'install.ps1': 'a'.repeat(64), 'install.sh': 'a'.repeat(64) } });
      const snap = dataSnapshot(w);
      const r = await w.run(fakes, { yes: true });
      assert.notEqual(r.code, 0, r.all);
      assert.match(r.all, /hash/i);
      assert.deepEqual(dataSnapshot(w), snap);
      assert.equal(fakes.state.events.filter((e) => e.what === 'device_authorization').length, 0);
    });
    scenario('hash do ai-memory diverge do manifesto: aborta sem instalar o binario e sem login', {}, async (w, fakes) => {
      w.stubs('claude'); fs.mkdirSync(w.claudeDir, { recursive: true });
      await w.provision(fakes, { badArtifactHash: true });
      const r = await w.run(fakes, { yes: true });
      assert.notEqual(r.code, 0, r.all);
      assert.match(r.all, /SHA-256|sha256/i);
      assert.equal(fs.existsSync(w.binInstallDir), false);
      assert.equal(fakes.state.events.filter((e) => e.what === 'device_authorization').length, 0);
    });
    scenario('manifesto com versao minima do instalador maior: aborta', {}, async (w, fakes) => {
      w.stubs('claude'); fs.mkdirSync(w.claudeDir, { recursive: true });
      fakes.opts.manifest.installer.minVersion = '9.0.0';
      const r = await w.run(fakes, { yes: true });
      assert.notEqual(r.code, 0, r.all); assert.match(r.all, /antigo demais|minimo|mínimo|too old/i);
    });
    scenario('memory_url devolvido pela API diferente do esperado: aborta antes de gravar', { memoryUrlOverride: 'https://outro.example' }, async (w, fakes) => {
      w.stubs('claude'); fs.mkdirSync(w.claudeDir, { recursive: true });
      const r = await w.run(fakes, { yes: true });
      assert.notEqual(r.code, 0, r.all);
      assert.equal(call(w, 'ai-memory', (c) => c.args.includes('install-hooks')).length, 0);
    });

    scenario('login: access_denied e expired_token terminam com mensagem e sem computador', { deny: true }, async (w, fakes) => {
      w.stubs('claude'); fs.mkdirSync(w.claudeDir, { recursive: true });
      const r = await w.run(fakes, { yes: true });
      assert.equal(r.code, 4, r.all); assert.match(r.out, /negada/);
      assert.equal(fakes.state.computers.size, 0);
    });
    scenario('login: expired_token', { expire: true }, async (w, fakes) => {
      w.stubs('claude'); fs.mkdirSync(w.claudeDir, { recursive: true });
      const r = await w.run(fakes, { yes: true });
      assert.equal(r.code, 4, r.all); assert.match(r.out, /expirou/);
      assert.equal(fakes.state.computers.size, 0);
    });
    scenario('login: slow_down aumenta o intervalo e o fluxo completo ainda conclui', { slowDownAtPoll: 2, approveAfterPolls: 4 }, async (w, fakes) => {
      w.stubs('claude'); fs.mkdirSync(w.claudeDir, { recursive: true });
      const r = await w.run(fakes, { yes: true });
      assert.equal(r.code, 0, r.all); assert.equal(fakes.state.slowDownSent, 1);
      assert.match(r.out, /BCDF-GHJK/);
    });

    scenario('canario: a chave nunca aparece em saida, log, computer.json nem em arquivo fora dos arquivos de chave do ai-memory', {}, async (w, fakes) => {
      w.stubs('claude'); fs.mkdirSync(w.claudeDir, { recursive: true }); w.maestri('conta-a');
      const r = await w.run(fakes, { yes: true });
      assert.equal(r.code, 0, r.all);
      const key = keyOf(fakes); assert.match(key, /^aim_CANARY_/);
      assert.equal(r.all.includes(key), false, 'saida');
      const allowed = ['auth-token', 'auth-header'].map((n) => path.join(w.dataDir, n));
      assert.deepEqual(filesContaining(w.dir, key, allowed), [], 'arquivos');
      assert.ok(fs.existsSync(allowed[0]), 'a chave foi gravada onde o ai-memory a guarda');
      // profile
      const w2 = new World(root, adapter, launcher);
      try {
        w2.stubs('claude', 'ai-memory'); w2.seedHooks(w2.claudeDir);
        const r2 = await w2.run(fakes, { yes: true, roots: [w2.repos] });
        assert.equal(r2.code, 0, r2.all);
        const key2 = keyOf(fakes);
        assert.equal(r2.all.includes(key2), false);
        assert.deepEqual(filesContaining(w2.dir, key2, [path.join(w2.dataDir, 'auth-tokens', 'ufba')]), []);
      } finally { w2.cleanup(); }
      assert.ok(!JSON.stringify(w.calls()).includes('aim_'), 'o log do stub nao tem a chave');
    });

    scenario('desinstalar (fresh): remove MCP, hooks, chave gravada, programa e computer.json', {}, async (w, fakes) => {
      w.stubs('claude'); fs.mkdirSync(w.claudeDir, { recursive: true });
      assert.equal((await w.run(fakes, { yes: true })).code, 0);
      const r = await w.run(fakes, { uninstall: true, yes: true });
      assert.equal(r.code, 0, r.all);
      assert.equal(Object.values(w.mcp()).reduce((n, m) => n + Object.keys(m).length, 0), 0);
      assert.equal(JSON.parse(fs.readFileSync(path.join(w.claudeDir, 'settings.json'), 'utf8')).hooks, undefined);
      assert.equal(fs.existsSync(path.join(w.dataDir, 'auth-token')), false);
      assert.equal(fs.existsSync(w.binInstallDir), false);
      assert.equal(fs.existsSync(w.stateFile), false);
      assert.match(r.out, /revoga|remova este computador|Computadores conectados/);
    });
    scenario('desinstalar (profile): remove so o perfil ufba e o MCP; os hooks da pessoa ficam como estavam', {}, async (w, fakes) => {
      w.stubs('claude', 'ai-memory'); w.seedHooks(w.claudeDir); w.seedProfile('grimorio', [w.repos]);
      assert.equal((await w.run(fakes, { yes: true, roots: [w.repos] })).code, 0);
      const hooksBefore = fs.readFileSync(path.join(w.claudeDir, 'settings.json'));
      const r = await w.run(fakes, { uninstall: true, yes: true });
      assert.equal(r.code, 0, r.all);
      const db = JSON.parse(fs.readFileSync(path.join(w.dataDir, 'servers.json'), 'utf8'));
      assert.deepEqual(Object.keys(db), ['grimorio']);
      assert.deepEqual(fs.readFileSync(path.join(w.claudeDir, 'settings.json')), hooksBefore);
      assert.equal(call(w, 'ai-memory', (c) => c.args[0] === 'uninstall' || c.args.includes('uninstall')).length, 0, 'nunca "ai-memory uninstall" em profile');
      assert.equal(Object.values(w.mcp()).reduce((n, m) => n + Object.keys(m).length, 0), 0);
      assert.equal(fs.existsSync(w.stateFile), false);
    });
    scenario('desinstalar sem ter instalado: avisa e nao faz nada', {}, async (w, fakes) => {
      const snap = dataSnapshot(w);
      const r = await w.run(fakes, { uninstall: true, yes: true });
      assert.equal(r.code, 0, r.all); assert.match(r.out, /Nada para desinstalar/);
      assert.deepEqual(dataSnapshot(w), snap);
    });

    scenario('sem agente compativel: para e orienta (nada alterado)', {}, async (w, fakes) => {
      const snap = dataSnapshot(w);
      const r = await w.run(fakes, { yes: true });
      assert.equal(r.code, 3, r.all); assert.deepEqual(dataSnapshot(w), snap);
    });
  });
}
