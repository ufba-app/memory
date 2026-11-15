// Testes do release: tools/build-release.mjs (manifesto + bootstraps do MESMO artefato) e dos bootstraps
// install.ps1 / install.sh (recusam placeholder e hash errado; com hash certo baixam, conferem e executam).
import { test, describe, before, after } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { adapters, World, buildLauncher, tmpRoot, sha256, repo, isWin } from './lib/harness.mjs';
import { startFakes } from './lib/servers.mjs';
import { buildRelease, ASSETS } from '../tools/build-release.mjs';

// A tag do teste acompanha a versao do instalador (o build recusa tag que nao bate).
const INSTALLER_VERSION = /IV='([0-9.]+)'/.exec(fs.readFileSync(path.join(repo, 'installer', 'ufba-memory.sh'), 'utf8'))[1];
const TAG = `installer-v${INSTALLER_VERSION}`;
const root = tmpRoot();
let launcher = null;
let dist = null;
before(async () => {
  if (isWin) launcher = buildLauncher(root);
  const art = path.join(root, 'artifacts'); fs.mkdirSync(art);
  for (const f of Object.values(ASSETS)) fs.writeFileSync(path.join(art, f), `conteudo de teste de ${f}`);
  dist = (await buildRelease({ out: path.join(root, 'dist'), artifactsDir: art, tag: TAG }));
});
after(() => { fs.rmSync(root, { recursive: true, force: true }); });

describe('tools/build-release.mjs', () => {
  test('manifesto: schema 1, ordem das chaves, 4 plataformas, hashes dos bytes dos artefatos', () => {
    const m = JSON.parse(fs.readFileSync(path.join(dist.out, 'manifest.json'), 'utf8'));
    assert.deepEqual(Object.keys(m), ['schema', 'aiMemory', 'installer']);
    assert.equal(m.schema, 1);
    assert.equal(m.aiMemory.version, fs.readFileSync(path.join(repo, 'VERSION'), 'utf8').trim().slice(1));
    assert.deepEqual(Object.keys(m.aiMemory.artifacts), ['windows-x64', 'linux-x64', 'macos-arm64', 'macos-x64']);
    for (const [plat, a] of Object.entries(m.aiMemory.artifacts)) {
      assert.match(a.sha256, /^[0-9a-f]{64}$/);
      assert.equal(a.sha256, sha256(Buffer.from(`conteudo de teste de ${ASSETS[plat]}`)));
      assert.match(a.url, new RegExp(`^https://github\\.com/akitaonrails/ai-memory/releases/download/v${m.aiMemory.version.replace(/\./g, '\\.')}/${ASSETS[plat]}$`));
    }
    assert.deepEqual(Object.keys(m.installer), ['version', 'minVersion', 'files']);
    assert.deepEqual(Object.keys(m.installer.files), ['install.ps1', 'install.sh']);
  });

  test('um so dono do hash: manifesto, bootstrap e arquivo do release usam os mesmos bytes do instalador', () => {
    const m = JSON.parse(fs.readFileSync(path.join(dist.out, 'manifest.json'), 'utf8'));
    for (const [boot, inst, key] of [['install.ps1', 'ufba-memory.ps1', 'install.ps1'], ['install.sh', 'ufba-memory.sh', 'install.sh']]) {
      const src = fs.readFileSync(path.join(repo, 'installer', inst));
      const released = fs.readFileSync(path.join(dist.out, inst));
      assert.deepEqual(released, src, 'o release copia o instalador byte a byte');
      assert.equal(m.installer.files[key], sha256(src));
      const text = fs.readFileSync(path.join(dist.out, boot), 'utf8');
      assert.ok(text.includes(sha256(src)), `${boot} embute o hash do instalador`);
      assert.ok(text.includes(`'${m.installer.version}'`));
      assert.ok(!text.includes('@@INSTALLER_'), 'nenhum marcador sobra');
      assert.ok(text.split('\n').length <= 81, 'bootstrap com no maximo 80 linhas');
    }
    const sums = fs.readFileSync(path.join(dist.out, 'SHA256SUMS'), 'utf8');
    for (const f of dist.outputs) assert.match(sums, new RegExp(`${sha256(fs.readFileSync(path.join(dist.out, f)))}  ${f.replace('.', '\\.')}`));
  });

  test('modelos no git ficam com placeholder e tem no maximo 80 linhas', () => {
    for (const f of ['install.ps1', 'install.sh']) {
      const t = fs.readFileSync(path.join(repo, f), 'utf8');
      assert.ok(t.includes('@@INSTALLER_SHA256@@') && t.includes('@@INSTALLER_VERSION@@'));
      assert.ok(t.trimEnd().split('\n').length <= 80);
    }
  });

  test('tag que nao bate com a versao do instalador, ou artefato faltando, falham', async () => {
    await assert.rejects(buildRelease({ out: path.join(root, 'x1'), artifactsDir: path.join(root, 'artifacts'), tag: 'installer-v9.9.9' }), /nao bate/);
    fs.mkdirSync(path.join(root, 'vazio'));
    await assert.rejects(buildRelease({ out: path.join(root, 'x2'), artifactsDir: path.join(root, 'vazio') }), /falta ai-memory/);
    await assert.rejects(buildRelease({ out: path.join(root, 'x3') }), /--artifacts-dir/);
  });

  test('a linha de comando funciona (sem rede, com artefatos de teste)', () => {
    const r = spawnSync(process.execPath, [path.join(repo, 'tools', 'build-release.mjs'), '--out', path.join(root, 'cli'), '--artifacts-dir', path.join(root, 'artifacts'), '--tag', TAG], { encoding: 'utf8' });
    assert.equal(r.status, 0, r.stderr);
    assert.ok(fs.existsSync(path.join(root, 'cli', 'manifest.json')));
  });
});

describe('o instalador do .ps1 comeca com BOM UTF-8 (o PowerShell 5.1 le arquivo sem BOM como ANSI)', () => {
  test('BOM presente', () => { assert.deepEqual([...fs.readFileSync(adapters.ps1.file).subarray(0, 3)], [0xef, 0xbb, 0xbf]); });
});

for (const adapter of Object.values(adapters)) {
  const skip = adapter.available() ? false : `${adapter.name}: interpretador nao disponivel nesta maquina (roda no CI)`;
  const bootName = adapter.name === 'ps1' ? 'install.ps1' : 'install.sh';
  const instName = adapter.name === 'ps1' ? 'ufba-memory.ps1' : 'ufba-memory.sh';
  const argv = (...a) => (adapter.name === 'ps1' ? a.map((x) => ({ yes: '-Yes', dry: '-DryRun' })[x]) : a.map((x) => ({ yes: '--yes', dry: '--dry-run' })[x]));
  describe(`bootstrap ${bootName}`, { skip, concurrency: false }, () => {
    const scenario = (name, fn) => test(name, async () => {
      const w = new World(root, adapter, launcher);
      const fakes = await startFakes({});
      try { await w.provision(fakes); await fn(w, fakes); } finally { await fakes.close(); w.cleanup(); }
    });
    const env = (fakes) => ({ UFBA_RELEASE_BASE: `${fakes.apiUrl}/artifacts` });

    scenario('recusa o modelo com placeholder (o arquivo do git) e nao executa nada', async (w, fakes) => {
      const r = await w.runScript(fakes, path.join(repo, bootName), [], { extraEnv: env(fakes) });
      assert.notEqual(r.code, 0, r.all);
      assert.match(r.all, /placeholder/);
      assert.equal(fakes.state.requests.length, 0, 'nem chegou a fazer download');
    });

    scenario('recusa hash errado: baixa mas NAO executa', async (w, fakes) => {
      const sentinel = path.join(w.work, 'executou.txt');
      const evil = adapter.name === 'ps1' ? `Set-Content -Path '${sentinel}' -Value x\r\n` : `echo x > "${sentinel.replace(/\\/g, '/')}"\n`;
      fakes.addFile(`${TAG}/${instName}`, Buffer.from(evil));
      const r = await w.runScript(fakes, path.join(dist.out, bootName), argv('yes'), { extraEnv: env(fakes) });
      assert.notEqual(r.code, 0, r.all);
      assert.match(r.all, /NAO confere/);
      assert.equal(fs.existsSync(sentinel), false, 'o instalador adulterado nao rodou');
    });

    scenario('hash certo: baixa o instalador versionado, confere e executa (dry-run ponta a ponta)', async (w, fakes) => {
      fakes.addFile(`${TAG}/${instName}`, fs.readFileSync(path.join(dist.out, instName)));
      w.stubs('claude'); fs.mkdirSync(w.claudeDir, { recursive: true });
      const r = await w.runScript(fakes, path.join(dist.out, bootName), argv('yes', 'dry'), { extraEnv: env(fakes) });
      assert.equal(r.code, 0, r.all);
      assert.match(r.out, /SIMULACAO|Simulacao/);
      assert.ok(fakes.state.requests.some((q) => q.path === '/memory/install-manifest'), 'o instalador conferiu o manifesto (hash dele mesmo)');
    });

    scenario('conferencia estatica: override de URL so com UFBA_INSTALLER_TEST e padrao https do GitHub (rodar sem teste iria a rede real)', async (w, fakes) => {
      // Sem UFBA_INSTALLER_TEST=1 o UFBA_RELEASE_BASE e ignorado: o bootstrap iria ao GitHub de verdade, entao so
      // conferimos o texto (nada de rede aqui).
      const t = fs.readFileSync(path.join(repo, bootName), 'utf8');
      assert.match(t, /UFBA_INSTALLER_TEST/);
      assert.match(t, /https:\/\/github\.com\/ufba-app\/memory\/releases\/download/);
    });
  });
}
