#!/bin/sh
# Confere que o Dockerfile desta camada pinou o MESMO modelo (URL e sha256) que o ai-memory da tag do VERSION espera.
# Uso: docker/check-model-pins.sh <upstream>/crates/ai-memory-llm/src/local.rs Dockerfile
set -eu
local_rs=$1; dockerfile=$2
up_hashes=$(sed -n '/pub const MODEL_FILES/,/^];/p' "$local_rs" | grep -oE '"[0-9a-f]{64}"' | tr -d '"' | tr '\n' ' ')
df_hashes=$(grep -E '^ARG SHA256_' "$dockerfile" | sed 's/.*=//' | tr '\n' ' ')
up_url=$(grep -oE 'https://huggingface\.co/[^"]+' "$local_rs" | head -n 1)
df_url=$(grep -E '^ARG MODEL_BASE_URL=' "$dockerfile" | sed 's/.*=//')
up_names=$(sed -n '/pub const MODEL_FILES/,/^];/p' "$local_rs" | grep -oE '"[a-z_.]+\.(safetensors|json)"' | tr -d '"' | tr '\n' ' ')
[ "$up_hashes" = "$df_hashes" ] || { echo "check-model-pins: sha256 do modelo mudou no upstream: [$up_hashes] != [$df_hashes]" >&2; exit 1; }
[ "$up_url" = "$df_url" ] || { echo "check-model-pins: URL do modelo mudou no upstream: $up_url != $df_url" >&2; exit 1; }
[ "$up_names" = "model.safetensors tokenizer.json config.json " ] || { echo "check-model-pins: arquivos do modelo mudaram: $up_names" >&2; exit 1; }
echo "check-model-pins: ok ($up_names)"
