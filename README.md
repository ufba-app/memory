# ufba-app/memory

Memória compartilhada do ufba.app: o [ai-memory](https://github.com/akitaonrails/ai-memory) oficial, sem alterações,
compilado com o console de gestão (`management-ui`). Roda em `https://memory.ufba.app` (Railway, serviço `memory`).

Este repositório tem duas coisas:

1. a **receita da imagem do servidor** (workflow `image`), e
2. o **instalador** que conecta o computador de uma pessoa a essa memória (`memory.ufba.app/install.ps1` e `memory.ufba.app/install.sh`).

Desenho do release (manifesto, bootstrap, quem gera o quê): [docs/release.md](docs/release.md).

---

## Instalar (para quem usa)

Windows (PowerShell 5.1 ou mais novo, sem administrador):

```powershell
irm https://memory.ufba.app/install.ps1 | iex
```

Linux e macOS (sem sudo):

```sh
curl -fsSL https://memory.ufba.app/install.sh | sh
```

Com opções (veja "Opções" abaixo):

```powershell
& ([scriptblock]::Create((irm https://memory.ufba.app/install.ps1))) -Yes -Root C:\dev\ufba
```
```sh
curl -fsSL https://memory.ufba.app/install.sh | sh -s -- --yes --root ~/dev/ufba
```

O instalador mostra um código no terminal; você abre o link, entra com o Google @ufba.br, confere que o código é o
mesmo e aprova. A chave deste computador é criada na hora, vai direto para a configuração do ai-memory e **nunca**
passa por argumento de comando, variável de ambiente persistente, log, arquivo de estado ou tela.

### Opções

| PowerShell | sh | O que faz |
|---|---|---|
| `-DryRun` (ou `-WhatIf`) | `--dry-run` | Mostra o plano e **não escreve nada** (não faz login, não baixa nada). |
| `-Yes` | `--yes` | Aceita todos os agentes encontrados e não pergunta nada. No modo perfil exige `-Root`/`--root`. |
| `-Root <pasta>[,<pasta>]` | `--root <pasta>` (repete) | Pasta onde ficam os repositórios da ufba.app (só no modo perfil). |
| `-ComputerName <nome>` | `--computer-name <nome>` | Nome mostrado na lista de computadores conectados (padrão: nome da máquina). |
| `-Uninstall` | `uninstall` | Desfaz o que o instalador fez (veja "Desfazer"). |

Não existe `--mode`: o modo é **detectado** (próxima seção).

## fresh e profile (o instalador nunca sobrescreve o seu servidor padrão)

| Modo | Quando | O que faz |
|---|---|---|
| `fresh` | Não há ai-memory na máquina | Instala o ai-memory **3.4.6** (versão fixa, SHA-256 conferido contra o manifesto), grava os hooks com a ufba.app como servidor padrão e `--capture-mode allowlist` (repositório sem marcador **nunca** captura). |
| `profile` | Já existe ai-memory | **Não toca** no servidor, na chave nem no modo de captura que você já tem, e **não roda `install-hooks`**. Só registra o perfil nomeado `ufba` (`ai-memory server add ufba … --auth-token-stdin`) e só repositórios cujo `.ai-memory.toml` diz `server = "ufba"` (e que estão dentro da pasta `--root`) capturam para a ufba.app. |

Como o instalador decide, sem varrer o disco: `ai-memory` no PATH, `%LOCALAPPDATA%\Programs\ai-memory`,
`%LOCALAPPDATA%\ai-memory` (Windows; `~/.local/bin`, `~/.local/lib/ai-memory`, `~/.local/share/ai-memory` no Linux e
`~/Library/Application Support/ai-memory` no macOS), `servers.toml` e hooks do ai-memory nas configurações dos
agentes. Qualquer sinal = `profile`. Se o instalador já tinha instalado o ai-memory (`~/.ufba/computer.json` diz
`fresh`), rodar de novo continua `fresh`.

No modo `profile` o instalador **para e explica, sem alterar nada**, quando:

- o seu ai-memory é **menor que 3.4.6** (uma versão antiga ignora o perfil e mandaria a captura para o servidor padrão);
  o instalador nunca atualiza o ai-memory de ninguém;
- há sinais de ai-memory mas o programa não foi encontrado;
- o agente não tem hooks do ai-memory. O instalador nunca roda `install-hooks` no modo `profile`; ele mostra as duas opções, e depois é só rodar o instalador de novo:
  1. **(recomendada) só nos repos da ufba:** dentro de cada repo do ufba-app, `ai-memory install-hooks --agent claude-code --scope project --apply`, e rode o instalador de novo (dentro desse repo ou com `--root` apontando para a pasta dos repos). Os hooks valem só naquele repo. O instalador **só reconhece** esses hooks (`.claude/settings.local.json` do repo onde ele roda e dos repos git até 2 níveis abaixo do `--root`, somente leitura), registra o perfil e lista quais repos já capturam para a ufba.app; ele não instala hooks, não mexe no `.git` nem no Claude Code global. Para capturar, o repo precisa do `.ai-memory.toml` com `server = "ufba"`.
  2. **Global, só com marcador:** `ai-memory install-hooks --agent claude-code --apply --capture-mode allowlist`. Atenção: o modo `allowlist` vale também para o seu servidor pessoal; repositórios sem `.ai-memory.toml` deixam de capturar.

### Instalação não é o seu servidor padrão

A ufba.app entra na sua máquina como **um servidor a mais**, escolhido por repositório (`server = "ufba"` no marcador).
Em `profile` o seu servidor padrão (por exemplo, o seu grimório) continua exatamente como estava: repositórios sem
`server` vão para ele, como antes. Só em `fresh` a ufba.app vira o servidor padrão, porque não havia outro.

Para um repositório capturar para a ufba.app, ponha na raiz dele (dentro da pasta `--root`):

```toml
# .ai-memory.toml
workspace = "ufba-app"
project   = "api"
server    = "ufba"        # NOME do perfil, nunca URL
```

## O que muda na máquina

O instalador **só escreve** em:

| Onde | O quê | Modo |
|---|---|---|
| Pasta do ai-memory (`%LOCALAPPDATA%\Programs\ai-memory` ou `~/.local/lib/ai-memory`, com link em `~/.local/bin/ai-memory`) | O programa ai-memory 3.4.6 (Windows: também a entrada no PATH do usuário) | só `fresh` |
| Pasta de dados do ai-memory (sempre passada com `--data-dir`) | `servers.toml` e `auth-tokens/ufba` (`profile`) ou `auth-token`/`auth-header` e a configuração dos hooks (`fresh`), tudo gravado **pelo próprio ai-memory** | os dois |
| Configuração dos agentes (`~/.claude/settings.json`, e a de cada conta do Maestri) | Hooks do ai-memory, com o backup que o próprio ai-memory faz | só `fresh` |
| Configuração de MCP do Claude Code (escopo `user`), por conta | `claude mcp add --transport http --scope user ufba https://api.ufba.app/mcp` | os dois |
| `~/.ufba/computer.json` | Id do computador, modo, caminhos e contas conectadas. **Sem segredo.** Serve para reinstalar/consertar virar rotação da chave | os dois |
| Uma pasta temporária (apagada ao fim) | Download do ai-memory | só `fresh` |
| Dentro da pasta `--root`, por alguns segundos | Uma pasta `.ufba-selftest-*` com um marcador de teste, apagada em seguida (auto-teste de captura) | só `profile` |

O instalador **nunca** roda `install-mcp`, `install-instructions` nem instala skills, `CLAUDE.md` ou `AGENTS.md`, não
envia telemetria e não pede administrador/`sudo`. Agentes procurados (lista fechada): `claude`/`~/.claude`
(ou o `CLAUDE_CONFIG_DIR` que você já usa) e cada subpasta de `~/.maestri-local/accounts/` (cada uma é um
`CLAUDE_CONFIG_DIR`); o instalador **lista e pergunta** por conta (`--yes` aceita todas).

## Variáveis de ambiente

Produção: nenhuma é necessária. As URLs são fixas (`https://api.ufba.app`, `https://memory.ufba.app`), HTTPS é
obrigatório e o TLS é 1.2 ou mais novo (inclusive no PowerShell 5.1). `UFBA_NO_BROWSER=1` não abre o navegador.

Só para teste (valem **apenas** com `UFBA_INSTALLER_TEST=1`; sem ela são ignoradas com um aviso):
`UFBA_API_URL`, `UFBA_MEMORY_URL` (aceitam `http://127.0.0.1`), `UFBA_POLL_SCALE_MS`, `UFBA_INSTALLER_TEST_OS`,
`UFBA_INSTALLER_TEST_ARCH`, `UFBA_RELEASE_BASE` (bootstrap).

## Conferir o hash antes de rodar (alternativa a `| iex`)

Se você prefere ler antes de executar, baixe o instalador **do release** (versionado e imutável), confira o hash e rode.
Os hashes ficam no `SHA256SUMS` do mesmo release e no manifesto (`installer.files`).

Windows:

```powershell
$base = 'https://github.com/ufba-app/memory/releases/download/installer-v1.0.3'
Invoke-WebRequest "$base/ufba-memory.ps1" -OutFile ufba-memory.ps1
Invoke-WebRequest "$base/SHA256SUMS" -OutFile SHA256SUMS
(Get-FileHash .\ufba-memory.ps1 -Algorithm SHA256).Hash.ToLower()   # compare com a linha ufba-memory.ps1 do SHA256SUMS
Get-Content .\ufba-memory.ps1                                        # leia
powershell -NoProfile -ExecutionPolicy Bypass -File .\ufba-memory.ps1 -DryRun
```

Linux e macOS:

```sh
base=https://github.com/ufba-app/memory/releases/download/installer-v1.0.3
curl -fsSLO "$base/ufba-memory.sh" && curl -fsSLO "$base/SHA256SUMS"
grep ' ufba-memory.sh$' SHA256SUMS | sha256sum -c -     # no macOS: shasum -a 256 -c -
less ufba-memory.sh
sh ufba-memory.sh --dry-run
```

O instalador ainda confere o **próprio** hash contra o manifesto que a API serve (`/memory/install-manifest`) e aborta
se não bater. Assinatura dos releases (minisign) fica para uma etapa posterior.

## Desfazer

```powershell
& ([scriptblock]::Create((irm https://memory.ufba.app/install.ps1))) -Uninstall      # ou: .\ufba-memory.ps1 -Uninstall
```
```sh
curl -fsSL https://memory.ufba.app/install.sh | sh -s -- uninstall                    # ou: sh ufba-memory.sh uninstall
```

Remove **só o que o instalador instalou**, lendo `~/.ufba/computer.json`:

- o registro do MCP `ufba` em cada conta conectada;
- `profile`: o perfil `ufba` do ai-memory. **Nunca** remove os seus hooks nem o seu servidor padrão;
- `fresh`: os hooks do ai-memory dessas contas, a chave gravada, o programa ai-memory e a entrada no PATH;
- o `~/.ufba/computer.json`.

A chave deste computador continua válida no servidor até alguém revogá-la: abra a ufba.app, vá em "Computadores
conectados" e remova o computador. Os dados que já estão no servidor não são apagados. `-DryRun`/`--dry-run` mostra o que seria removido.

## Limites conhecidos

- **Agentes sem hook nativo não roteiam perfil.** Só o hook nativo (`ai-memory hook`) escolhe o perfil por marcador.
  Os scripts (`codex`, `cursor`, `gemini-cli`, `antigravity-cli`, `copilot-cli`, `cline`) e as integrações TypeScript
  (`pi`, `omp`, `openclaw`, `opencode`) não emitem nada num repositório com `server`. O instalador **não** conecta esses
  agentes (se encontrar `~/.codex`, `~/.gemini` ou `~/.cursor`, só avisa).
- Nesta versão o instalador conecta o **Claude Code** (conta padrão e contas do Maestri). Os outros agentes com hook
  nativo no Windows (`grok`, `droid`, `qwen-code`, `kiro-cli`, `devin`) ainda não têm detecção nem registro de MCP aqui.
- O caminho `~/.maestri-local/accounts/` é confirmado no Windows; em Linux/macOS é a mesma convenção, a confirmar.
- Em `profile` a pasta de dados é a padrão do ai-memory. Quem usa `--data-dir` próprio não é detectado como `profile`.
- Windows ARM64 usa o build x86_64 (emulado). Linux ARM64 ainda não tem build no manifesto.
- Uma resposta perdida na **primeira** instalação (antes de existir `computer_id`) deixa um computador órfão no
  servidor; a API o revoga sozinha em 10 minutos. Nas reinstalações o mesmo `computer_id` troca a chave sem duplicar.
- O instalador precisa de `curl` (e `tar`) no Linux/macOS e do PowerShell 5.1+ no Windows.

## Desenvolvimento

Sem dependências; Node 22.

```sh
node --test "test/*.test.mjs"          # tudo (o que depende de PowerShell só roda no Windows)
UFBA_TEST_ONLY=sh node --test "test/installer.test.mjs"
node tools/build-release.mjs --out dist --artifacts-dir <pasta com os 4 assets do ai-memory>   # sem rede
```

Os testes sobem servidores **falsos** em `127.0.0.1` (API e memory) e usam `ai-memory` e `claude` falsos que registram os
argumentos recebidos, o que entrou por stdin e **falham se a chave aparecer em argumento**. Cada caso roda com
`HOME`/`USERPROFILE`/`LOCALAPPDATA`/`PATH` próprios, numa pasta temporária. Nunca falam com `api.ufba.app` nem
`memory.ufba.app`. CI: `installer-test` (Windows, Linux e macOS) e `release`.

---

## O servidor

Este repositório só tem a receita de build: o workflow `image` compila a tag do arquivo `VERSION` e publica
`ghcr.io/ufba-app/ai-memory:<versão>`. Para atualizar, troque o `VERSION` e, depois do build, a tag da imagem no
serviço do Railway. **Trocar o `VERSION` também muda a versão que o instalador instala** (o manifesto vem do release
do instalador: publique um release novo depois).

### Como o serviço está configurado

- Sem IA no servidor: nenhuma chave de LLM nem de embeddings. Quem lê e escreve é a IA de cada pessoa, pelo MCP.
- Dados num volume em `/data` (wiki em markdown com git + índice SQLite). Um único servidor por volume.
- Autenticação obrigatória: token de root e usuários com senha e chaves `aim_`.
- Wiki em `/web`, console de usuários em `/manage`, MCP em `/mcp`.

Variáveis (Railway): `AI_MEMORY_AUTH_TOKEN` (segredo), `AI_MEMORY_ALLOWED_HOSTS`, `AI_MEMORY_AUTH__SECURE_COOKIE=true`,
`AI_MEMORY_ENABLE_MANAGEMENT_UI=true`, `RAILWAY_RUN_UID=0`, `PORT=49374`.

### Modelo do embedder dentro da imagem

O ai-memory 3.4.6 usa embeddings locais (candle, `all-MiniLM-L6-v2`, ~87 MB) **por padrão** e, sem o modelo, o
**baixa do Hugging Face** na primeira subida (e só liga a busca semântica no reinício seguinte). Isso contradiz
"nenhuma chamada externa do servidor". Lendo o código da tag `v3.4.6`:

- O modelo mora em `<data_dir>/models/all-MiniLM-L6-v2/{model.safetensors,tokenizer.json,config.json}`; o caminho é
  **fixo** no código (`models_dir: self.data_dir.join("models")`, `crates/ai-memory-cli/src/config.rs`) e **não há variável
  de ambiente nem opção de config** para mudá-lo (nem cache do `hf-hub`/`fastembed`: é candle com download próprio).
- Cada arquivo é conferido contra um sha256 fixado no código (`crates/ai-memory-llm/src/local.rs`, `MODEL_FILES`); com os
  três arquivos presentes o servidor nunca toca na rede.
- No Railway o volume em `/data` **sombreia** o que a imagem tiver em `/data`.

Solução (sem mexer no upstream): a imagem final é uma camada sobre a oficial (`Dockerfile` deste repo).

1. Um estágio baixa os três arquivos e confere o sha256 (`sha256sum -c`) para `/opt/ai-memory/models/all-MiniLM-L6-v2/`
   (fora de `/data`).
2. O `docker/entrypoint.sh` cria, em `/data/models/all-MiniLM-L6-v2/`, links simbólicos para esses arquivos (só os que
   faltam; não sobrescreve nada que já esteja no volume e nunca derruba o boot) e entrega o controle ao `ai-memory`.
3. O workflow `image` ficou em duas etapas: o ai-memory oficial vira `ghcr.io/ufba-app/ai-memory:<versão>-base` e a camada
   final publica `<versão>` e `latest`. Antes, `docker/check-model-pins.sh` **falha o build** se o upstream da tag trocou
   a URL, os arquivos ou os sha256 do modelo (os do `Dockerfile` precisam acompanhar).

Alternativa mais próxima, se um dia for preciso: `AI_MEMORY_EMBEDDING_PROVIDER=none` (só busca textual, sem vetores).
Não executado aqui: o build da imagem (sem Docker nesta máquina); testados sem Docker: `entrypoint.sh` e `check-model-pins.sh`.
