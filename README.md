# ufba-app/memory

Memória compartilhada do ufba.app: o [ai-memory](https://github.com/akitaonrails/ai-memory) oficial, sem alterações,
compilado com o console de gestão (`management-ui`). Roda em `https://memory.ufba.app` (Railway, serviço `memory`).

Este repositório só tem a receita de build: o workflow `image` compila a tag do arquivo `VERSION` e publica
`ghcr.io/ufba-app/ai-memory:<versão>`. Para atualizar, troque o `VERSION` e, depois do build, a tag da imagem no
serviço do Railway.

## Como o serviço está configurado

- Sem IA no servidor: nenhuma chave de LLM nem de embeddings. Quem lê e escreve é a IA de cada pessoa, pelo MCP.
- Dados num volume em `/data` (wiki em markdown com git + índice SQLite). Um único servidor por volume.
- Autenticação obrigatória: token de root e usuários com senha e chaves `aim_`.
- Wiki em `/web`, console de usuários em `/manage`, MCP em `/mcp`.

Variáveis (Railway): `AI_MEMORY_AUTH_TOKEN` (segredo), `AI_MEMORY_ALLOWED_HOSTS`, `AI_MEMORY_AUTH__SECURE_COOKIE=true`,
`AI_MEMORY_ENABLE_MANAGEMENT_UI=true`, `RAILWAY_RUN_UID=0`, `PORT=49374`.
