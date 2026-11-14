#!/usr/bin/env node
// Gera o release do instalador a partir dos MESMOS arquivos (um so dono do hash):
//   dist/ufba-memory.ps1, dist/ufba-memory.sh   instaladores completos (copiados, byte a byte)
//   dist/install.ps1, dist/install.sh           bootstraps com versao e SHA-256 do instalador embutidos
//   dist/manifest.json                          manifesto (schema 1) servido pela API em /memory/install-manifest
//   dist/SHA256SUMS                             hashes de tudo, para quem prefere conferir na mao
// Sem dependencias, Node 22. Os artefatos do ai-memory vem de --artifacts-dir (testes/dry, sem rede) ou de --download
// (CI: baixa os assets do release oficial akitaonrails/ai-memory na tag de VERSION e calcula o sha256 dos BYTES
// baixados; o `.sha256` do mesmo origin nao e prova de nada).
//
// Uso: node tools/build-release.mjs [--out dist] [--tag installer-v1.0.0] [--artifacts-dir <pasta> | --download]
//                                   [--min-version 1.0.0] [--ai-memory-base <url>]
import fs from 'node:fs';
import path from 'node:path';
import crypto from 'node:crypto';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
export const ASSETS = {
  'windows-x64': 'ai-memory-windows-x86_64.zip',
  'linux-x64': 'ai-memory-linux-x86_64.tar.gz',
  'macos-arm64': 'ai-memory-macos-aarch64.tar.gz',
  'macos-x64': 'ai-memory-macos-x86_64.tar.gz',
};
const MARKERS = ['@@INSTALLER_VERSION@@', '@@INSTALLER_SHA256@@'];
export const sha256 = (buf) => crypto.createHash('sha256').update(buf).digest('hex');
const read = (rel, base = root) => fs.readFileSync(path.join(base, rel));

export function installerVersion(base = root) {
  const ps = /\$InstallerVersion\s*=\s*'([^']+)'/.exec(read('installer/ufba-memory.ps1', base).toString('utf8'));
  const sh = /^\s*IV='([^']+)'/m.exec(read('installer/ufba-memory.sh', base).toString('utf8'));
  if (!ps || !sh) throw new Error('nao achei a versao do instalador (InstallerVersion no .ps1 / IV no .sh)');
  if (ps[1] !== sh[1]) throw new Error(`versoes diferentes: .ps1=${ps[1]} .sh=${sh[1]}`);
  return ps[1];
}

function stamp(template, name, version, hash) {
  const lines = template.split('\n').length - (template.endsWith('\n') ? 1 : 0);
  if (lines > 80) throw new Error(`${name} tem ${lines} linhas (maximo 80)`);
  for (const m of MARKERS) if (!template.includes(m)) throw new Error(`${name} sem o marcador ${m}`);
  const out = template.split('@@INSTALLER_VERSION@@').join(version).split('@@INSTALLER_SHA256@@').join(hash);
  for (const m of MARKERS) if (out.includes(m)) throw new Error(`${name}: marcador ${m} sobrou`);
  return out;
}

async function download(url) {
  if (!url.startsWith('https://')) throw new Error('so https: ' + url);
  const res = await fetch(url, { redirect: 'follow' });
  if (!res.ok) throw new Error(`HTTP ${res.status} em ${url}`);
  return Buffer.from(await res.arrayBuffer());
}

/**
 * @param {{out?:string, tag?:string, artifactsDir?:string, download?:boolean, minVersion?:string, aiMemoryBase?:string, base?:string}} o
 */
export async function buildRelease(o = {}) {
  const base = o.base ?? root;
  const out = path.resolve(o.out ?? path.join(base, 'dist'));
  const aiTag = read('VERSION', base).toString('utf8').trim();
  if (!/^v\d+\.\d+\.\d+$/.test(aiTag)) throw new Error(`VERSION invalida: ${aiTag}`);
  const version = installerVersion(base);
  if (o.tag && o.tag !== `installer-v${version}`) throw new Error(`a tag ${o.tag} nao bate com a versao do instalador (${version})`);

  const ps1 = read('installer/ufba-memory.ps1', base);
  const sh = read('installer/ufba-memory.sh', base);
  const files = { 'install.ps1': sha256(ps1), 'install.sh': sha256(sh) };

  const artifacts = {};
  const aiBase = (o.aiMemoryBase ?? `https://github.com/akitaonrails/ai-memory/releases/download/${aiTag}`).replace(/\/$/, '');
  for (const [plat, asset] of Object.entries(ASSETS)) {
    let buf;
    if (o.artifactsDir) {
      const f = path.join(o.artifactsDir, asset);
      if (!fs.existsSync(f)) throw new Error(`falta ${asset} em ${o.artifactsDir}`);
      buf = fs.readFileSync(f);
    } else if (o.download) buf = await download(`${aiBase}/${asset}`);
    else throw new Error('informe --artifacts-dir <pasta> ou --download');
    artifacts[plat] = { url: `${aiBase}/${asset}`, sha256: sha256(buf) };
  }

  const manifest = {
    schema: 1,
    aiMemory: { version: aiTag.slice(1), artifacts },
    installer: { version, minVersion: o.minVersion ?? '1.0.0', files },
  };

  fs.mkdirSync(out, { recursive: true });
  const outputs = {
    'ufba-memory.ps1': ps1,
    'ufba-memory.sh': sh,
    'install.ps1': Buffer.from(stamp(read('install.ps1', base).toString('utf8'), 'install.ps1', version, files['install.ps1'])),
    'install.sh': Buffer.from(stamp(read('install.sh', base).toString('utf8'), 'install.sh', version, files['install.sh'])),
    'manifest.json': Buffer.from(JSON.stringify(manifest, null, 2) + '\n'),
  };
  for (const [name, buf] of Object.entries(outputs)) fs.writeFileSync(path.join(out, name), buf);
  const sums = Object.entries(outputs).map(([n, b]) => `${sha256(b)}  ${n}`).join('\n') + '\n';
  fs.writeFileSync(path.join(out, 'SHA256SUMS'), sums);
  return { out, manifest, version, aiTag, outputs: Object.keys(outputs) };
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const a = process.argv.slice(2);
  const opt = (n) => { const i = a.indexOf(n); return i >= 0 ? a[i + 1] : undefined; };
  buildRelease({
    out: opt('--out'), tag: opt('--tag'), artifactsDir: opt('--artifacts-dir'), download: a.includes('--download'),
    minVersion: opt('--min-version'), aiMemoryBase: opt('--ai-memory-base'),
  }).then((r) => console.log(`release ${r.version} (ai-memory ${r.aiTag}) gerado em ${r.out}: ${r.outputs.join(', ')}`))
    .catch((e) => { console.error('build-release: ' + e.message); process.exit(1); });
}
