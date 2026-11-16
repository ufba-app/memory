# Desenho do release do instalador

Quem gera o quê, e por que cada hash tem um dono só.

## Peças

| Arquivo (no git) | O que é | Vira, no release |
|---|---|---|
| `installer/ufba-memory.ps1`, `installer/ufba-memory.sh` | Os instaladores completos (passos 1 a 10 do desenho, `uninstall`). | `ufba-memory.ps1`, `ufba-memory.sh`, copiados **byte a byte** |
| `install.ps1`, `install.sh` (raiz) | Modelos dos bootstraps (≤ 80 linhas), com os marcadores `@@INSTALLER_VERSION@@` e `@@INSTALLER_SHA256@@`. No git ficam como placeholder e **recusam rodar**. | `install.ps1`, `install.sh` com versão e SHA-256 do instalador correspondente embutidos |
| `VERSION` | Tag do ai-memory oficial (`v3.4.6`). | `manifest.json` → `aiMemory` |
| `tools/build-release.mjs` | Gera tudo acima a partir dos mesmos arquivos. | `manifest.json`, `SHA256SUMS` |

## Quem gera o quê (um só dono do hash)

```
                    CI (release.yml, tag installer-vX.Y.Z)
                    tools/build-release.mjs
  installer/ufba-memory.ps1 ──sha256──┬─> manifest.json  installer.files["install.ps1"]
                                       └─> install.ps1    (marcador @@INSTALLER_SHA256@@ trocado)
  installer/ufba-memory.sh  ──sha256──┬─> manifest.json  installer.files["install.sh"]
                                       └─> install.sh
  assets do release oficial do ai-memory (tag de VERSION, baixados no CI) ──sha256 dos bytes──> manifest.json aiMemory.artifacts
```

Tudo sai do **mesmo passo do mesmo job**: o hash do instalador que está no bootstrap é, por construção, o do arquivo
anexado ao release e o do manifesto. O hash do ai-memory é calculado sobre os bytes **baixados no CI** (o `.sha256`
do mesmo origin do binário não prova nada contra quem controla o origin).

O `installer.version` vem da constante `$InstallerVersion` (`.ps1`) e `IV` (`.sh`), que precisam ser iguais; a tag
`installer-vX.Y.Z` precisa bater com ela, senão o build falha.

## Manifesto (`manifest.json`, `schema: 1`)

```json
{
  "schema": 1,
  "aiMemory": {
    "version": "3.4.6",
    "artifacts": {
      "windows-x64": { "url": "https://github.com/akitaonrails/ai-memory/releases/download/v3.4.6/ai-memory-windows-x86_64.zip", "sha256": "<64 hex>" },
      "linux-x64":   { "url": ".../ai-memory-linux-x86_64.tar.gz",   "sha256": "<64 hex>" },
      "macos-arm64": { "url": ".../ai-memory-macos-aarch64.tar.gz",  "sha256": "<64 hex>" },
      "macos-x64":   { "url": ".../ai-memory-macos-x86_64.tar.gz",   "sha256": "<64 hex>" }
    }
  },
  "installer": {
    "version": "1.0.0",
    "minVersion": "1.0.0",
    "files": { "install.ps1": "<sha256 de installer/ufba-memory.ps1>", "install.sh": "<sha256 de installer/ufba-memory.sh>" }
  }
}
```

Atenção ao nome: `installer.files["install.ps1"]` é o hash do instalador **completo** (`ufba-memory.ps1`), não do bootstrap
(o bootstrap embute esse mesmo hash e o confere).

Quem serve: a API (`GET https://api.ufba.app/memory/install-manifest`) busca `releases/latest/download/manifest.json` deste
repositório (só `github.com`), valida o formato, guarda 10 minutos e serve o último bom se a origem cair.

## Cadeia de confiança na máquina da pessoa

1. `memory.ufba.app/install.ps1|sh` (bootstrap pequeno) baixa `ufba-memory.*` **do release do GitHub** (`installer-vX.Y.Z`, imutável)
   e confere o SHA-256 embutido. Comprometer só a ufba.app ou só o GitHub não basta.
2. O instalador pede o manifesto à API e confere que o **próprio** hash é o `installer.files[...]` do manifesto, e que a
   versão dele é ≥ `minVersion`. Divergiu: aborta antes de qualquer escrita ou login.
3. No modo `fresh`, baixa o ai-memory da URL do manifesto e confere o SHA-256 do manifesto antes de extrair (também
   recusa caminho absoluto ou `..` dentro do arquivo). Divergiu: aborta, nada instalado.
4. A API só entrega a chave depois do login de dispositivo; o instalador só diz `confirm` depois de gravar a chave.

Risco residual aceito: comprometer o CI **ou** o GitHub e a ufba.app ao mesmo tempo. A assinatura minisign dos releases
(chave pública no bootstrap) é a etapa 9.

## Como publicar

1. Altere o instalador e suba a constante de versão (`$InstallerVersion` e `IV`).
2. `git tag installer-v1.1.0 && git push origin installer-v1.1.0`. O workflow `release` roda os testes sem rede, gera o
   release e o publica (não sobrescreve release existente).
3. Atualizar o ai-memory = trocar o `VERSION` (isso reconstrói a imagem do servidor) **e** publicar um release novo do
   instalador (o manifesto é gerado nele). Suba `minVersion` quando um instalador antigo não puder mais rodar.
4. `memory.ufba.app/install.ps1|sh` devem servir os arquivos `install.ps1|sh` do **último** release. Quem serve é uma
   regra de redirecionamento (302) do Cloudflare, na zona `ufba.app` (Rules, Redirect Rules, "Redirecionamentos do
   ufba.app"), para `https://github.com/ufba-app/memory/releases/latest/download/install.ps1|sh`. Não há nada a
   fazer a cada release: `latest` já aponta para o mais novo. Teste com `curl -I https://memory.ufba.app/install.sh`.

Localmente, sem rede e com artefatos de teste: `node tools/build-release.mjs --out dist --artifacts-dir <pasta>`.

## Testes de release

`test/release.test.mjs` cobre: forma do manifesto, um dono do hash (manifesto = bootstrap = arquivo do release),
placeholder recusado, hash errado recusado sem executar nada, e bootstrap + instalador ponta a ponta contra servidores
falsos em 127.0.0.1.
