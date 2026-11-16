#!/bin/sh
# Bootstrap de https://memory.ufba.app/install.sh  (curl -fsSL https://memory.ufba.app/install.sh | sh)
#
# Este arquivo so faz tres coisas: baixa o instalador VERSIONADO e IMUTAVEL do release do GitHub (ufba-app/memory),
# confere o SHA-256 embutido aqui e o executa. Os marcadores @@...@@ abaixo sao trocados pelo CI (tools/build-release.mjs)
# a cada release; no git eles ficam como placeholder e o bootstrap RECUSA rodar assim.
# Para nao rodar nada as cegas: baixe o instalador do release, leia, confira o hash e rode (veja o README).
# Argumentos: curl -fsSL https://memory.ufba.app/install.sh | sh -s -- --yes --root ~/dev/ufba
# Tudo fica dentro de ufba_bootstrap, chamada na ultima linha: um download truncado nao executa nada.

ufba_bootstrap() {
    version='@@INSTALLER_VERSION@@'
    sha256='@@INSTALLER_SHA256@@'
    base='https://github.com/ufba-app/memory/releases/download'
    proto='=https'
    if [ "${UFBA_INSTALLER_TEST:-}" = 1 ] && [ -n "${UFBA_RELEASE_BASE:-}" ]; then base=${UFBA_RELEASE_BASE%/}; proto='=https,http'; fi
    case "$version$sha256" in *@@*) echo 'ufba: este bootstrap e um modelo (placeholder) e nao pode ser executado; use o de https://memory.ufba.app/install.sh' >&2; return 1 ;; esac
    case "$sha256" in *[!0-9a-f]*) echo 'ufba: hash embutido invalido' >&2; return 1 ;; esac
    [ "${#sha256}" -eq 64 ] || { echo 'ufba: hash embutido invalido' >&2; return 1; }
    command -v curl >/dev/null 2>&1 || { echo 'ufba: preciso do curl' >&2; return 1; }
    tmp=$(mktemp -d "${TMPDIR:-/tmp}/ufba-memory.XXXXXX") || return 1
    trap 'rm -rf "$tmp"' EXIT INT TERM
    curl -fsSL --proto "$proto" --tlsv1.2 -o "$tmp/ufba-memory.sh" "$base/installer-v$version/ufba-memory.sh" || { echo 'ufba: nao consegui baixar o instalador' >&2; return 1; }
    if command -v sha256sum >/dev/null 2>&1; then got=$(sha256sum "$tmp/ufba-memory.sh" | cut -d ' ' -f 1)
    elif command -v shasum >/dev/null 2>&1; then got=$(shasum -a 256 "$tmp/ufba-memory.sh" | cut -d ' ' -f 1)
    else echo 'ufba: preciso de sha256sum ou shasum' >&2; return 1; fi
    if [ "$got" != "$sha256" ]; then echo "ufba: o hash do instalador NAO confere (esperado $sha256, veio $got). Nada foi executado." >&2; return 1; fi
    sh "$tmp/ufba-memory.sh" "$@"
}

ufba_bootstrap "$@"
