#!/bin/sh
# Entrypoint da imagem da ufba.app: liga o modelo embarcado ao diretorio de dados e entrega o controle ao ai-memory.
# O volume do Railway sombreia /data, entao o modelo mora em $UFBA_MODELS_DIR (fora de /data) e aqui criamos, no
# volume, so links simbolicos para os 3 arquivos (o ai-memory segue links e confere o sha256 ao carregar).
# Nunca falha o boot por causa disso: sem o link o ai-memory so cai no comportamento padrao dele (baixa o modelo).
src="${UFBA_MODELS_DIR:-/opt/ai-memory/models}/all-MiniLM-L6-v2"
dst="${AI_MEMORY_DATA_DIR:-/data}/models/all-MiniLM-L6-v2"
for f in model.safetensors tokenizer.json config.json; do
    if [ -f "$src/$f" ] && [ ! -e "$dst/$f" ]; then
        mkdir -p "$dst" 2>/dev/null && ln -sfn "$src/$f" "$dst/$f" 2>/dev/null \
            || echo "ufba-entrypoint: aviso: nao consegui ligar $f ao diretorio de dados; o ai-memory vai baixar o modelo." >&2
    fi
done
exec "${UFBA_AI_MEMORY_BIN:-/usr/local/bin/ai-memory}" "$@"
