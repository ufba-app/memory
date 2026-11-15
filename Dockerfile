# syntax=docker/dockerfile:1.7
#
# Camada da ufba.app sobre a imagem oficial do ai-memory (compilada pelo workflow `image` na tag do arquivo VERSION):
# embarca o modelo do embedder local (all-MiniLM-L6-v2) DENTRO da imagem, para que o servidor nao baixe nada da
# internet ao subir (o desenho promete "sem chamada externa").
#
# Por que fora de /data: o ai-memory procura o modelo em <data_dir>/models/all-MiniLM-L6-v2/ (caminho fixo no codigo,
# sem variavel de ambiente: crates/ai-memory-cli/src/config.rs, `models_dir: self.data_dir.join("models")`), e o volume
# do Railway sombreia /data. Entao o modelo mora em /opt/ai-memory/models e o entrypoint (docker/entrypoint.sh) cria,
# no volume, so os links simbolicos para ele. O ai-memory continua conferindo o sha256 dos 3 arquivos ao carregar.
#
# BASE_IMAGE vem do workflow: ghcr.io/ufba-app/ai-memory:<versao>-base (o ai-memory oficial, sem alteracoes).
# Os sha256 abaixo sao os de MODEL_FILES em crates/ai-memory-llm/src/local.rs da tag do VERSION;
# docker/check-model-pins.sh confere isso no CI e falha se o upstream mudar o modelo.

ARG BASE_IMAGE

FROM debian:bookworm-slim@sha256:734a72b3d6142a71993b4bc580ca01d8ca687f77a2c422d96a961d3376b179bc AS model
RUN apt-get update \
 && apt-get install -y --no-install-recommends ca-certificates curl \
 && rm -rf /var/lib/apt/lists/*
ARG MODEL_BASE_URL=https://huggingface.co/sentence-transformers/all-MiniLM-L6-v2/resolve/main
ARG SHA256_MODEL_SAFETENSORS=53aa51172d142c89d9012cce15ae4d6cc0ca6895895114379cacb4fab128d9db
ARG SHA256_TOKENIZER_JSON=be50c3628f2bf5bb5e3a7f17b1f74611b2561a3a27eeab05e5aa30f411572037
ARG SHA256_CONFIG_JSON=953f9c0d463486b10a6871cc2fd59f223b2c70184f49815e7efbcab5d8908b41
WORKDIR /models/all-MiniLM-L6-v2
RUN set -eu; \
    for spec in "model.safetensors:${SHA256_MODEL_SAFETENSORS}" "tokenizer.json:${SHA256_TOKENIZER_JSON}" "config.json:${SHA256_CONFIG_JSON}"; do \
      f="${spec%%:*}"; h="${spec##*:}"; \
      curl -fsSL --retry 3 --proto '=https' --tlsv1.2 -o "$f" "${MODEL_BASE_URL}/$f"; \
      echo "$h  $f" | sha256sum -c -; \
    done

FROM ${BASE_IMAGE}
USER root
COPY --from=model /models /opt/ai-memory/models
COPY --chmod=0755 docker/entrypoint.sh /usr/local/bin/ufba-entrypoint
ENV UFBA_MODELS_DIR=/opt/ai-memory/models
USER ai-memory
# O ENTRYPOINT novo zera o CMD herdado: repetimos o do ai-memory oficial (docker/Dockerfile da tag).
ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/ufba-entrypoint"]
CMD ["serve", "--transport", "http", "--bind", "0.0.0.0:49374", "--enable-web"]
