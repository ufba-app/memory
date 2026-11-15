// Testes do entrypoint da imagem (docker/entrypoint.sh) e da conferencia dos pins do modelo, sem Docker:
// o que so roda no CI (build da imagem de verdade) fica marcado no workflow `image`.
import { test } from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import { spawnSync } from 'node:child_process';
import { repo, findSh, tmpRoot, fwd } from './lib/harness.mjs';

const sh = findSh();
const skip = sh ? false : 'sh nao disponivel';
const root = tmpRoot();
process.on('exit', () => fs.rmSync(root, { recursive: true, force: true }));
const FILES = ['model.safetensors', 'tokenizer.json', 'config.json'];

function world() {
  const d = fs.mkdtempSync(path.join(root, 'ep-'));
  const opt = path.join(d, 'opt', 'all-MiniLM-L6-v2'); fs.mkdirSync(opt, { recursive: true });
  for (const f of FILES) fs.writeFileSync(path.join(opt, f), 'modelo:' + f);
  const data = path.join(d, 'data'); fs.mkdirSync(data);
  const bin = path.join(d, 'ai-memory'); fs.writeFileSync(bin, '#!/bin/sh\necho "args: $*"\n', { mode: 0o755 });
  const run = (extra = {}) => spawnSync(sh, [fwd(path.join(repo, 'docker', 'entrypoint.sh')), 'serve', '--x'], {
    encoding: 'utf8', env: { ...process.env, UFBA_MODELS_DIR: fwd(path.join(d, 'opt')), AI_MEMORY_DATA_DIR: fwd(data), UFBA_AI_MEMORY_BIN: fwd(bin), ...extra },
  });
  return { d, data, run, dst: path.join(data, 'models', 'all-MiniLM-L6-v2') };
}

test('entrypoint: liga os 3 arquivos do modelo ao diretorio de dados e entrega os argumentos ao ai-memory', { skip }, () => {
  const w = world(); const r = w.run();
  assert.equal(r.status, 0, r.stderr);
  assert.match(r.stdout, /args: serve --x/);
  for (const f of FILES) assert.equal(fs.readFileSync(path.join(w.dst, f), 'utf8'), 'modelo:' + f);
});

test('entrypoint: nao sobrescreve arquivo que ja esta no volume e conserta link quebrado', { skip }, () => {
  const w = world();
  fs.mkdirSync(w.dst, { recursive: true });
  fs.writeFileSync(path.join(w.dst, 'config.json'), 'ja baixado');
  const r = w.run();
  assert.equal(r.status, 0, r.stderr);
  assert.equal(fs.readFileSync(path.join(w.dst, 'config.json'), 'utf8'), 'ja baixado');
  assert.equal(fs.readFileSync(path.join(w.dst, 'model.safetensors'), 'utf8'), 'modelo:model.safetensors');
});

test('entrypoint: volume sem permissao de escrita nao derruba o boot', { skip }, () => {
  const w = world();
  const r = w.run({ AI_MEMORY_DATA_DIR: fwd(path.join(w.d, 'nao', 'existe', '\0x').replace('\0x', '')) });
  assert.equal(r.status, 0, r.stderr);
  assert.match(r.stdout, /args: serve --x/);
});

test('check-model-pins: confere com o upstream e acusa mudanca de hash', { skip }, () => {
  const w = world();
  const rs = path.join(w.d, 'local.rs');
  const pins = fs.readFileSync(path.join(repo, 'Dockerfile'), 'utf8').match(/^ARG SHA256_\w+=([0-9a-f]{64})/gm).map((l) => l.split('=')[1]);
  const upstream = (h) => `pub const MODEL_FILES: [(&str, &str); 3] = [\n    ("model.safetensors", "${h[0]}"),\n    ("tokenizer.json", "${h[1]}"),\n    ("config.json", "${h[2]}"),\n];\nconst MODEL_BASE_URL: &str =\n    "https://huggingface.co/sentence-transformers/all-MiniLM-L6-v2/resolve/main";\n`;
  fs.writeFileSync(rs, upstream(pins));
  const run = () => spawnSync(sh, [fwd(path.join(repo, 'docker', 'check-model-pins.sh')), fwd(rs), fwd(path.join(repo, 'Dockerfile'))], { encoding: 'utf8' });
  assert.equal(run().status, 0, run().stderr);
  fs.writeFileSync(rs, upstream([pins[0], pins[1], 'a'.repeat(64)]));
  const bad = run();
  assert.notEqual(bad.status, 0); assert.match(bad.stderr, /mudou/);
});
