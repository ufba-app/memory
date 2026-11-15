// Infra dos testes do instalador: mundo descartavel (HOME, LOCALAPPDATA, PATH, stubs), servidores falsos, execucao
// do .ps1 (powershell.exe) e do .sh (sh), instantaneo de arvore e busca do canario da chave.
// Regra de ouro: nada aqui toca a instalacao real do ai-memory nem fala com servicos reais.
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import zlib from 'node:zlib';
import { spawn, spawnSync } from 'node:child_process';
import { fileURLToPath } from 'node:url';

export const here = path.dirname(fileURLToPath(import.meta.url));
export const repo = path.resolve(here, '..', '..');
export const isWin = process.platform === 'win32';
export const sha256 = (buf) => crypto.createHash('sha256').update(buf).digest('hex');
export const fwd = (p) => p.replace(/\\/g, '/');
export const STUB_JS = path.join(here, 'stub.mjs');

export function findSh() {
  if (!isWin) return 'sh';
  for (const base of [process.env.ProgramFiles, process.env['ProgramFiles(x86)'], 'C:\\Program Files']) {
    if (!base) continue;
    const p = path.join(base, 'Git', 'usr', 'bin', 'sh.exe');
    if (fs.existsSync(p)) return p;
  }
  return null;
}
export function findPowerShell() {
  if (!isWin) return null;
  const p = path.join(process.env.SystemRoot || 'C:\\Windows', 'System32', 'WindowsPowerShell', 'v1.0', 'powershell.exe');
  return fs.existsSync(p) ? p : null;
}

/** Compila o lancador (ai-memory.exe/claude.exe de teste) uma vez, dentro da pasta descartavel do teste. */
export function buildLauncher(dir) {
  const csc = path.join(process.env.SystemRoot || 'C:\\Windows', 'Microsoft.NET', 'Framework64', 'v4.0.30319', 'csc.exe');
  const out = path.join(dir, 'launcher.exe');
  const r = spawnSync(csc, ['/nologo', `/out:${out}`, path.join(here, 'launcher.cs')], { encoding: 'utf8' });
  if (r.status !== 0) throw new Error('csc falhou: ' + r.stdout + r.stderr);
  return out;
}

// ---------- zip (store, sem dependencias) e tar.gz ----------
export function makeZip(entries) {
  const files = []; const cds = []; let offset = 0;
  for (const [name, data] of entries) {
    const nameB = Buffer.from(name); const crc = zlib.crc32(data) >>> 0;
    const lh = Buffer.alloc(30); lh.writeUInt32LE(0x04034b50, 0); lh.writeUInt16LE(20, 4); lh.writeUInt32LE(crc, 14);
    lh.writeUInt32LE(data.length, 18); lh.writeUInt32LE(data.length, 22); lh.writeUInt16LE(nameB.length, 26);
    files.push(lh, nameB, data);
    const cd = Buffer.alloc(46); cd.writeUInt32LE(0x02014b50, 0); cd.writeUInt16LE(20, 4); cd.writeUInt16LE(20, 6);
    cd.writeUInt32LE(crc, 16); cd.writeUInt32LE(data.length, 20); cd.writeUInt32LE(data.length, 24); cd.writeUInt16LE(nameB.length, 28);
    cd.writeUInt32LE(offset, 42); cds.push(cd, nameB);
    offset += lh.length + nameB.length + data.length;
  }
  const cdBuf = Buffer.concat(cds);
  const end = Buffer.alloc(22); end.writeUInt32LE(0x06054b50, 0); end.writeUInt16LE(entries.length, 8); end.writeUInt16LE(entries.length, 10);
  end.writeUInt32LE(cdBuf.length, 12); end.writeUInt32LE(offset, 16);
  return Buffer.concat([...files, cdBuf, end]);
}
export function makeTarGz(workDir, entries) {
  const srcName = 'tar-' + crypto.randomBytes(4).toString('hex'); const src = path.join(workDir, srcName); fs.mkdirSync(src);
  for (const [name, data, mode] of entries) {
    const f = path.join(src, name); fs.mkdirSync(path.dirname(f), { recursive: true }); fs.writeFileSync(f, data); if (mode) fs.chmodSync(f, mode);
  }
  const out = path.join(workDir, 'artifact.tar.gz');
  const r = spawnSync('tar', ['-czf', 'artifact.tar.gz', '-C', srcName, '.'], { encoding: 'utf8', cwd: workDir });
  if (r.status !== 0) throw new Error('tar falhou: ' + r.stderr);
  return fs.readFileSync(out);
}

// ---------- adaptadores ----------
export const adapters = {
  ps1: {
    name: 'ps1',
    file: path.join(repo, 'installer', 'ufba-memory.ps1'),
    platformKey: 'windows-x64',
    manifestFileKey: 'install.ps1',
    available: () => Boolean(findPowerShell()),
    argv(a) {
      const v = [];
      if (a.uninstall) v.push('-Uninstall');
      if (a.dryRun) v.push('-DryRun');
      if (a.whatIf) v.push('-WhatIf');
      if (a.yes) v.push('-Yes');
      if (a.roots && a.roots.length) v.push('-Root', a.roots.join(','));
      if (a.name) v.push('-ComputerName', a.name);
      return v;
    },
    cmd: (file, args) => [findPowerShell(), ['-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', file, ...args]],
  },
  sh: {
    name: 'sh',
    file: path.join(repo, 'installer', 'ufba-memory.sh'),
    // Windows (Git Bash) finge Linux x64; em Linux e macOS de verdade vale o proprio sistema.
    get platformKey() { return process.platform === 'darwin' ? `macos-${process.arch === 'arm64' ? 'arm64' : 'x64'}` : 'linux-x64'; },
    manifestFileKey: 'install.sh',
    available: () => Boolean(findSh()),
    argv(a) {
      const v = [];
      if (a.uninstall) v.push('uninstall');
      if (a.dryRun || a.whatIf) v.push('--dry-run');
      if (a.yes) v.push('--yes');
      for (const r of a.roots || []) v.push('--root', fwd(r));
      if (a.name) v.push('--computer-name', a.name);
      return v;
    },
    cmd: (file, args) => [findSh(), [fwd(file), ...args]],
  },
};

/** Mundo de um caso de teste: pastas descartaveis, PATH controlado, stubs. */
export class World {
  constructor(rootDir, adapter, launcher) {
    this.adapter = adapter;
    this.dir = fs.mkdtempSync(path.join(rootDir, 'case-'));
    const mk = (n) => { const p = path.join(this.dir, n); fs.mkdirSync(p, { recursive: true }); return p; };
    this.home = mk('home'); this.local = mk('local'); this.appdata = mk('appdata'); this.work = mk('work');
    this.bin = mk('bin'); this.stub = mk('stub'); this.repos = mk('repos');
    this.launcher = launcher;
    this.extraEnv = {};
  }
  /** Poe um stub de `ai-memory`/`claude` numa pasta (executavel de teste). */
  installStubIn(dir, name, windowsExe = this.adapter.name === 'ps1') {
    fs.mkdirSync(dir, { recursive: true });
    if (windowsExe) fs.copyFileSync(this.launcher, path.join(dir, name + '.exe'));
    else fs.writeFileSync(path.join(dir, name), `#!/bin/sh\nexec node "$STUB_JS" ${name} "$@"\n`, { mode: 0o755 });
  }
  stubs(...names) { for (const n of names) this.installStubIn(this.bin, n); return this; }
  removeStub(name) {
    for (const f of [name, name + '.exe']) fs.rmSync(path.join(this.bin, f), { force: true });
  }
  get dataDir() {
    if (this.adapter.name === 'ps1') return path.join(this.local, 'ai-memory');
    return process.platform === 'darwin' ? path.join(this.home, 'Library', 'Application Support', 'ai-memory') : path.join(this.home, '.local', 'share', 'ai-memory');
  }
  get binInstallDir() { return this.adapter.name === 'ps1' ? path.join(this.local, 'Programs', 'ai-memory') : path.join(this.home, '.local', 'lib', 'ai-memory'); }
  get stateFile() { return path.join(this.home, '.ufba', 'computer.json'); }
  get claudeDir() { return path.join(this.home, '.claude'); }
  maestri(name) { const d = path.join(this.home, '.maestri-local', 'accounts', name); fs.mkdirSync(d, { recursive: true }); return d; }
  seedHooks(configDir, extra = {}) {
    fs.mkdirSync(configDir, { recursive: true });
    fs.writeFileSync(path.join(configDir, 'settings.json'), JSON.stringify({ hooks: { SessionStart: [{ command: 'ai-memory hook --event session-start --agent claude-code --server-url https://grimorio.example' }] }, ...extra }, null, 2));
  }
  seedProfile(name, roots, url = 'https://outro.example') {
    fs.mkdirSync(this.dataDir, { recursive: true });
    const f = path.join(this.dataDir, 'servers.json');
    let db = {}; try { db = JSON.parse(fs.readFileSync(f, 'utf8')); } catch { /* novo */ }
    db[name] = { url, roots };
    fs.writeFileSync(f, JSON.stringify(db));
  }
  env(fakes, extra = {}) {
    const sys = process.env.SystemRoot || 'C:\\Windows';
    const node = path.dirname(process.execPath);
    const sh = findSh();
    const pathList = this.adapter.name === 'ps1'
      ? [this.bin, path.join(sys, 'System32'), sys, path.join(sys, 'System32', 'WindowsPowerShell', 'v1.0'), node]
      : [this.bin, ...(isWin ? [path.dirname(sh), path.join(path.dirname(sh), '..', '..', 'mingw64', 'bin')] : ['/usr/bin', '/bin']), node, ...(isWin ? [path.join(sys, 'System32')] : [])];
    const sep = isWin ? ';' : ':';
    const fixPath = this.adapter.name === 'sh' && isWin ? fwd : (x) => x;
    const e = {
      ...(process.env.PROCESSOR_ARCHITECTURE ? { PROCESSOR_ARCHITECTURE: process.env.PROCESSOR_ARCHITECTURE } : {}),
      SystemRoot: sys, windir: sys, ComSpec: process.env.ComSpec || path.join(sys, 'System32', 'cmd.exe'), PATHEXT: process.env.PATHEXT || '.COM;.EXE;.BAT;.CMD',
      USERPROFILE: fixPath(this.home), HOME: fixPath(this.home), LOCALAPPDATA: fixPath(this.local), APPDATA: fixPath(this.appdata),
      TEMP: fixPath(this.work), TMP: fixPath(this.work), TMPDIR: fixPath(this.work),
      XDG_DATA_HOME: fixPath(path.join(this.home, '.local', 'share')), XDG_CONFIG_HOME: fixPath(path.join(this.home, '.config')),
      PATH: pathList.map((p) => path.normalize(p)).map(fixPath).join(sep),
      STUB_DIR: fixPath(this.stub), STUB_JS: fwd(STUB_JS), STUB_AIM_VERSION: '3.4.6',
      UFBA_INSTALLER_TEST: '1', UFBA_NO_BROWSER: '1', UFBA_POLL_SCALE_MS: '5',
      ...(isWin ? { UFBA_INSTALLER_TEST_OS: 'linux', UFBA_INSTALLER_TEST_ARCH: 'x86_64' } : {}),
      ...(fakes ? { UFBA_API_URL: fakes.apiUrl, UFBA_MEMORY_URL: fakes.memUrl } : {}),
      ...this.extraEnv, ...extra,
    };
    if (isWin) e.PATH = e.PATH; // ja no formato certo
    return e;
  }
  /** Manifesto + artefato do ai-memory de teste, servidos pelo fake. */
  async provision(fakes, { aimVersion = '3.4.6', installerHashes = {}, badArtifactHash = false, artifactBytes = null } = {}) {
    let art; let artName;
    if (this.adapter.name === 'ps1') {
      art = artifactBytes ?? makeZip([['ai-memory.exe', fs.readFileSync(this.launcher)], ['hooks/readme.txt', Buffer.from('hooks de teste')]]);
      artName = 'ai-memory-windows-x86_64.zip';
    } else {
      art = artifactBytes ?? makeTarGz(this.work, [['ai-memory', Buffer.from('#!/bin/sh\nexec node "$STUB_JS" ai-memory "$@"\n'), 0o755], ['hooks/readme.txt', Buffer.from('hooks de teste')]]);
      artName = 'ai-memory-test.tar.gz';
    }
    fakes.addFile(artName, art);
    const entry = { url: `${fakes.apiUrl}/artifacts/${artName}`, sha256: badArtifactHash ? 'f'.repeat(64) : sha256(art) };
    const dummy = { url: 'https://example.invalid/x', sha256: '0'.repeat(64) };
    fakes.opts.manifest = {
      schema: 1,
      aiMemory: { version: aimVersion, artifacts: { 'windows-x64': dummy, 'linux-x64': dummy, 'macos-arm64': dummy, 'macos-x64': dummy, [this.adapter.platformKey]: entry } },
      installer: {
        version: '1.0.0', minVersion: '1.0.0',
        files: { 'install.ps1': sha256(fs.readFileSync(adapters.ps1.file)), 'install.sh': sha256(fs.existsSync(adapters.sh.file) ? fs.readFileSync(adapters.sh.file) : Buffer.alloc(0)), ...installerHashes },
      },
    };
    return entry;
  }
  run(fakes, args = {}, opts = {}) { return this.runScript(fakes, this.adapter.file, this.adapter.argv(args), opts); }
  /** Roda QUALQUER script (instalador ou bootstrap) com o mesmo ambiente isolado; `argv` ja no formato do interpretador. */
  runScript(fakes, file, argvIn, { extraEnv = {}, stdin = '' } = {}) {
    const [exe, argv] = this.adapter.cmd(file, argvIn);
    return new Promise((resolve) => {
      const child = spawn(exe, argv, { env: this.env(fakes, extraEnv), cwd: this.work, stdio: ['pipe', 'pipe', 'pipe'], windowsHide: true });
      let out = ''; let err = '';
      child.stdout.on('data', (d) => { out += d; });
      child.stderr.on('data', (d) => { err += d; });
      const timer = setTimeout(() => child.kill(), 120_000);
      child.on('close', (code) => { clearTimeout(timer); resolve({ code, out, err, all: out + '\n' + err }); });
      child.stdin.on('error', () => {}); // o script pode sair antes de ler o stdin (EPIPE)
      child.stdin.end(stdin);
    });
  }
  calls() {
    try { return fs.readFileSync(path.join(this.stub, 'calls.jsonl'), 'utf8').split('\n').filter(Boolean).map((l) => JSON.parse(l)); } catch { return []; }
  }
  state() { try { return JSON.parse(fs.readFileSync(this.stateFile, 'utf8')); } catch { return null; } }
  mcp() { try { return JSON.parse(fs.readFileSync(path.join(this.stub, 'mcp.json'), 'utf8')); } catch { return {}; } }
  cleanup() { fs.rmSync(this.dir, { recursive: true, force: true }); }
}

/** Instantaneo da arvore (caminho -> sha) para comparar antes/depois. */
export function snapshot(dir, skip = []) {
  const out = {};
  const walk = (d) => {
    for (const e of fs.readdirSync(d, { withFileTypes: true })) {
      const p = path.join(d, e.name);
      if (skip.some((s) => p.startsWith(s))) continue;
      if (e.isDirectory()) { out[path.relative(dir, p) + '/'] = 'dir'; walk(p); }
      else out[path.relative(dir, p)] = sha256(fs.readFileSync(p));
    }
  };
  walk(dir);
  return out;
}

/** Procura o texto (a chave canario) em TODOS os arquivos de dir, menos nos caminhos onde o ai-memory guarda a chave. */
export function filesContaining(dir, needle, allowed = []) {
  const hits = [];
  const walk = (d) => {
    for (const e of fs.readdirSync(d, { withFileTypes: true })) {
      const p = path.join(d, e.name);
      if (e.isDirectory()) { walk(p); continue; }
      if (allowed.some((a) => path.resolve(p) === path.resolve(a))) continue;
      const buf = fs.readFileSync(p);
      if (buf.includes(needle) || buf.toString('utf16le').includes(needle)) hits.push(p);
    }
  };
  walk(dir);
  return hits;
}

export const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
export const tmpRoot = () => fs.mkdtempSync(path.join(os.tmpdir(), 'ufba-it-'));
