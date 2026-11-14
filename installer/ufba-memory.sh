#!/bin/sh
# Instalador da memoria compartilhada do ufba.app (Linux e macOS; POSIX sh, sem dependencias alem de curl ou wget,
# tar, e sha256sum/shasum/openssl). Sem root, sem sudo.
#
# Normalmente voce o recebe pelo bootstrap (curl -fsSL https://ufba.app/install.sh | sh), que confere o SHA-256 antes
# de executar. Para rodar na mao: baixe, leia, confira o hash publicado no release e rode `sh ufba-memory.sh`.
#
#   ufba-memory.sh [install|uninstall] [--dry-run] [--yes] [--root <pasta>]... [--computer-name <nome>]
#
#   --dry-run   mostra o plano e nao escreve nada.
#   --yes       aceita todos os agentes encontrados e nao pergunta nada (em modo perfil exige --root).
#   --root      pasta onde ficam os repositorios da ufba.app (so no modo perfil; pode repetir).
#   uninstall   remove so o que este instalador instalou.
#
# O modo (fresh ou profile) NAO se escolhe: e detectado. A chave do computador nunca vai em argumento, variavel de
# ambiente persistente, log, arquivo de estado ou saida: entra por stdin ou no ambiente so do processo filho.
#
# Variaveis de TESTE (so valem com UFBA_INSTALLER_TEST=1; sem ela sao ignoradas com aviso): UFBA_API_URL,
# UFBA_MEMORY_URL, UFBA_POLL_SCALE_MS, UFBA_INSTALLER_TEST_OS, UFBA_INSTALLER_TEST_ARCH. UFBA_NO_BROWSER=1 nao abre o
# navegador.
#
# Tudo roda dentro de main(), chamada na ultima linha: um download truncado nao executa nada.

main() {
    IV='1.0.0'
    PINNED_API='https://api.ufba.app'
    PINNED_MEMORY='https://memory.ufba.app'
    umask 077

    # ---------- util ----------
    say() { printf '%s\n' "$*"; }
    warn() { printf 'Aviso: %s\n' "$*"; }
    die() { printf 'ufba-memory: erro: %s\n' "$*" >&2; exit 1; }
    stop_planned() { printf '\n%s\n\nNada foi alterado nesta maquina.\n' "$*"; exit 3; }
    json_str() { printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g'; }
    have() { command -v "$1" >/dev/null 2>&1; }

    # ---------- argumentos ----------
    CMD=install; DRY=0; YES=0; ROOTS=''; CNAME=''
    while [ $# -gt 0 ]; do
        case "$1" in
            install) CMD=install ;;
            uninstall) CMD=uninstall ;;
            --dry-run|-n) DRY=1 ;;
            --yes|-y) YES=1 ;;
            --root) [ $# -ge 2 ] || die '--root precisa de uma pasta'; ROOTS="$ROOTS
$2"; shift ;;
            --root=*) ROOTS="$ROOTS
${1#--root=}" ;;
            --computer-name) [ $# -ge 2 ] || die '--computer-name precisa de um nome'; CNAME="$2"; shift ;;
            -h|--help) sed -n '2,19p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
            --mode|--mode=*) die 'nao existe --mode: o modo (fresh/profile) e detectado.' ;;
            *) die "argumento desconhecido: $1 (use --help)" ;;
        esac
        shift
    done

    # ---------- URLs: fixas em producao; overrides so em teste ----------
    TEST=0; [ "${UFBA_INSTALLER_TEST:-}" = 1 ] && TEST=1
    API=$PINNED_API; MEM=$PINNED_MEMORY
    for _n in UFBA_API_URL UFBA_MEMORY_URL; do
        eval "_v=\${$_n:-}"
        [ -n "$_v" ] || continue
        if [ $TEST -ne 1 ]; then warn "$_n ignorada (so vale com UFBA_INSTALLER_TEST=1); usando as URLs oficiais."; continue; fi
        case "$_v" in https://*|http://127.0.0.1:*|http://127.0.0.1/*) ;; *) die "$_n precisa ser https:// (ou http://127.0.0.1 em teste).";; esac
        if [ "$_n" = UFBA_API_URL ]; then API=${_v%/}; else MEM=${_v%/}; fi
    done
    MCP_URL="$API/mcp"
    SCALE_MS=1000
    [ $TEST -eq 1 ] && [ -n "${UFBA_POLL_SCALE_MS:-}" ] && SCALE_MS=$UFBA_POLL_SCALE_MS
    wait_s() {
        if [ "$SCALE_MS" = 1000 ]; then sleep "$1"; else sleep "$(awk "BEGIN{printf \"%.3f\", $1*$SCALE_MS/1000}")"; fi
    }
    allowed_url() {
        case "$1" in https://*) return 0 ;; http://127.0.0.1*) [ $TEST -eq 1 ] && return 0 ;; esac
        return 1
    }

    # ---------- pastas e plataforma ----------
    HOME_DIR=${HOME:-}
    [ -n "$HOME_DIR" ] || die 'HOME nao esta definido.'
    UNAME_S=$(uname -s); UNAME_M=$(uname -m)
    if [ $TEST -eq 1 ]; then UNAME_S=${UFBA_INSTALLER_TEST_OS:-$UNAME_S}; UNAME_M=${UFBA_INSTALLER_TEST_ARCH:-$UNAME_M}; fi
    case "$UNAME_S" in
        Linux|linux) OS_NAME=linux; DATA_DIR="${XDG_DATA_HOME:-$HOME_DIR/.local/share}/ai-memory" ;;
        Darwin) OS_NAME=macos; DATA_DIR="$HOME_DIR/Library/Application Support/ai-memory" ;;
        *) stop_planned "Sistema nao suportado por este instalador: $UNAME_S (use o instalador PowerShell no Windows)." ;;
    esac
    case "$UNAME_M" in
        x86_64|amd64) ARCH_KEY=x64 ;;
        arm64|aarch64) ARCH_KEY=arm64 ;;
        *) stop_planned "Arquitetura sem build do ai-memory: $UNAME_M." ;;
    esac
    PLAT_KEY="$OS_NAME-$ARCH_KEY"
    LIB_DIR="$HOME_DIR/.local/lib/ai-memory"
    BIN_LINK="$HOME_DIR/.local/bin/ai-memory"
    STATE_DIR="$HOME_DIR/.ufba"
    STATE_FILE="$STATE_DIR/computer.json"

    # ---------- rede ----------
    have curl || have wget || die 'preciso de curl (ou wget) para falar com a ufba.app.'
    have curl || die 'preciso do curl para os pedidos a API (o wget so serve para baixar arquivos).'
    PROTO='=https'; [ $TEST -eq 1 ] && PROTO='=https,http'
    # http METHOD URL BEARER CONTENT_TYPE [dados...]  ->  HTTP_STATUS, HTTP_BODY. O Bearer vai por `-K -` (stdin),
    # nunca na linha de comando.
    http() {
        _m=$1; _u=$2; _b=$3; _ct=$4; shift 4
        allowed_url "$_u" || die "URL recusada (so https): $_u"
        _out=''; _rc=0
        if [ -n "$_b" ]; then
            _out=$(printf 'header = "Authorization: Bearer %s"\n' "$_b" | curl -sS --max-time 30 --proto "$PROTO" --tlsv1.2 -K - -X "$_m" ${_ct:+-H "Content-Type: $_ct"} -w '\n%{http_code}' "$@" "$_u" 2>/dev/null) || _rc=$?
        else
            _out=$(curl -sS --max-time 30 --proto "$PROTO" --tlsv1.2 -X "$_m" ${_ct:+-H "Content-Type: $_ct"} -w '\n%{http_code}' "$@" "$_u" 2>/dev/null) || _rc=$?
        fi
        HTTP_STATUS=$(printf '%s\n' "$_out" | tail -n 1)
        case "$HTTP_STATUS" in ''|*[!0-9]*) HTTP_STATUS=0 ;; esac
        [ "$_rc" -ne 0 ] && HTTP_STATUS=0
        HTTP_BODY=$(printf '%s\n' "$_out" | sed '$d')
        [ "$HTTP_STATUS" = 000 ] && HTTP_STATUS=0
        HTTP_STATUS=$((HTTP_STATUS + 0))
        return 0
    }
    # Achata JSON em "caminho<TAB>valor" (objetos e arrays; sem dependencias).
    json_flat() {
        tr -d '\r\n' | awk '
        { s=$0; n=length(s); i=1; depth=0; cur=""
          while (i<=n) {
            c=substr(s,i,1)
            if (c==" " || c=="\t") { i++; continue }
            if (c=="{" || c=="[") {
                vp = (depth>0 && typ[depth]=="a") ? pre[depth] "." idx[depth] : cur
                depth++; typ[depth]=(c=="{")?"o":"a"; pre[depth]=vp; idx[depth]=0; cur=""; i++; continue }
            if (c=="}" || c=="]") { depth--; i++; continue }
            if (c==",") { if (typ[depth]=="a") idx[depth]++; i++; continue }
            if (c==":") { i++; continue }
            if (c=="\"") {
                j=i+1; str=""
                while (j<=n) { d=substr(s,j,1)
                    if (d=="\\") { str=str substr(s,j+1,1); j+=2; continue }
                    if (d=="\"") break
                    str=str d; j++ }
                i=j+1
                k=i; while (substr(s,k,1)==" ") k++
                if (typ[depth]=="o" && substr(s,k,1)==":") { cur=(pre[depth]=="")?str:pre[depth] "." str; continue }
                vp=(typ[depth]=="a")?pre[depth] "." idx[depth]:cur
                print vp "\t" str; continue }
            j=i; while (j<=n && substr(s,j,1)!="," && substr(s,j,1)!="}" && substr(s,j,1)!="]") j++
            tok=substr(s,i,j-i); gsub(/ /,"",tok); if (tok=="null") tok=""
            vp=(typ[depth]=="a")?pre[depth] "." idx[depth]:cur
            print vp "\t" tok; i=j }
        }'
    }
    # jget "<json>" caminho
    jget() { printf '%s' "$1" | json_flat | awk -F '\t' -v p="$2" '$1==p { print $2; exit }'; }
    api_msg() {
        _m=$(jget "$HTTP_BODY" message); [ -n "$_m" ] || _m=$(jget "$HTTP_BODY" error_description); [ -n "$_m" ] || _m=$(jget "$HTTP_BODY" error)
        if [ -z "$_m" ]; then if [ "$HTTP_STATUS" -eq 0 ]; then _m='sem resposta do servidor (verifique a conexao)'; else _m="resposta HTTP $HTTP_STATUS"; fi; fi
        printf '%s' "$_m"
    }
    sha256_file() {
        if have sha256sum; then sha256sum "$1" | awk '{print tolower($1)}'
        elif have shasum; then shasum -a 256 "$1" | awk '{print tolower($1)}'
        elif have openssl; then openssl dgst -sha256 "$1" | awk '{print tolower($NF)}'
        else die 'preciso de sha256sum, shasum ou openssl.'; fi
    }
    fetch_file() {  # url destino
        allowed_url "$1" || die "URL recusada (so https): $1"
        if have curl; then curl -fsSL --max-time 300 --proto "$PROTO" --tlsv1.2 -o "$2" "$1" || return 1
        else wget -q -O "$2" "$1" || return 1; fi
    }
    vlt() { awk -v a="$1" -v b="$2" 'BEGIN{ na=split(a,x,"."); nb=split(b,y,"."); for(i=1;i<=3;i++){ if((x[i]+0)<(y[i]+0)){print 1; exit} if((x[i]+0)>(y[i]+0)){print 0; exit} } print 0 }'; }

    # ---------- perguntas (leem do terminal: no `curl | sh` o stdin e o script) ----------
    ask() {  # prompt -> ANSWER
        if ( : </dev/tty ) 2>/dev/null; then printf '%s ' "$1" >/dev/tty; read -r ANSWER </dev/tty || ANSWER=''
        else die 'preciso de uma resposta, mas nao ha terminal interativo. Rode de novo com --yes (e --root, no modo perfil).'; fi
    }
    confirm_item() {
        [ $YES -eq 1 ] && return 0
        ask "$1 [S/n]"
        case "$ANSWER" in ''|s|S|sim|Sim|y|Y|yes) return 0 ;; *) return 1 ;; esac
    }

    # ---------- agentes ----------
    has_hooks() {
        [ -f "$1/settings.json" ] && grep -q 'ai-memory' "$1/settings.json" && grep -q -e '--event' "$1/settings.json"
    }
    collect_targets() {  # saida: linhas "label|dir|envdir"
        _def=${CLAUDE_CONFIG_DIR:-}; _defenv=$_def
        [ -n "$_def" ] || _def="$HOME_DIR/.claude"
        if [ -d "$_def" ] || have claude; then printf 'Claude Code|%s|%s\n' "$_def" "$_defenv"; fi
        if [ -d "$HOME_DIR/.maestri-local/accounts" ]; then
            for _d in "$HOME_DIR/.maestri-local/accounts"/*/; do
                [ -d "$_d" ] || continue
                _d=${_d%/}
                printf 'Maestri: %s|%s|%s\n' "${_d##*/}" "$_d" "$_d"
            done
        fi
    }
    # run_aim EXEC_ENVDIR TOKEN_ENV args... : roda o ai-memory com CLAUDE_CONFIG_DIR e, se TOKEN_ENV, a chave so no
    # ambiente do filho; a saida e redigida.
    run_aim() {
        _ed=$1; _tk=$2; shift 2
        (
            [ -n "$_ed" ] && export CLAUDE_CONFIG_DIR="$_ed"
            if [ -n "$_tk" ]; then AI_MEMORY_AUTH_TOKEN="$_tk" "$@" 2>&1 </dev/null; else "$@" 2>&1 </dev/null; fi
        )
    }
    redact() { if [ -n "$1" ]; then sed "s|$1|***|g"; else cat; fi; }

    # ---------- estado ----------
    read_state() { [ -f "$STATE_FILE" ] && STATE_JSON=$(cat "$STATE_FILE") || STATE_JSON=''; }
    sget() { jget "$STATE_JSON" "$1"; }

    # =====================================================================
    # DESINSTALAR
    # =====================================================================
    if [ "$CMD" = uninstall ]; then
        read_state
        if [ -z "$STATE_JSON" ]; then say 'Nada para desinstalar: nao ha ~/.ufba/computer.json (este computador nao foi conectado por este instalador).'; exit 0; fi
        MODE=$(sget install_mode)
        AIM=$(sget ai_memory_exe); { [ -n "$AIM" ] && [ -x "$AIM" ]; } || AIM=$(command -v ai-memory 2>/dev/null || true)
        DD=$(sget data_dir); [ -n "$DD" ] || DD=$DATA_DIR
        say "Desinstalar (modo de instalacao: $MODE)"
        say '  - registro do MCP "ufba" em cada conta conectada'
        if [ "$MODE" = fresh ]; then say '  - hooks do ai-memory nessas contas, a chave gravada, o programa ai-memory (foram instalados por nos)'
        else say '  - perfil "ufba" do ai-memory (os hooks e o servidor padrao da pessoa NAO sao tocados)'; fi
        say '  - ~/.ufba/computer.json'
        if [ $DRY -eq 1 ]; then say ''; say 'Simulacao (--dry-run): nada foi alterado.'; exit 0; fi
        N=0
        while :; do
            L=$(sget "targets.$N.label"); [ -n "$L" ] || break
            ENVD=$(sget "targets.$N.env_dir")
            if have claude; then
                if ( [ -n "$ENVD" ] && export CLAUDE_CONFIG_DIR="$ENVD"; claude mcp remove --scope user ufba >/dev/null 2>&1 </dev/null ); then say "MCP removido: $L"; else warn "nao consegui remover o MCP em $L (talvez ja nao exista)."; fi
            else warn "comando claude nao encontrado: remova o MCP ufba de $L na mao (claude mcp remove --scope user ufba)."; fi
            if [ "$MODE" = fresh ] && [ -n "$AIM" ]; then
                if _o=$(run_aim "$ENVD" '' "$AIM" --data-dir "$DD" uninstall --only hooks --apply --yes); then say "Hooks removidos: $L"; else warn "nao consegui remover os hooks em $L: $_o"; fi
            fi
            N=$((N + 1))
        done
        if [ "$MODE" = profile ]; then
            if [ -n "$AIM" ]; then if "$AIM" --data-dir "$DD" server remove ufba >/dev/null 2>&1; then say 'Perfil "ufba" removido do ai-memory.'; else warn 'nao consegui remover o perfil "ufba".'; fi
            else warn 'ai-memory nao encontrado: remova o perfil na mao (ai-memory server remove ufba).'; fi
        else
            rm -f "$DD/auth-token" "$DD/auth-header"
            LD=$(sget ai_memory_dir)
            if [ "$(sget ai_memory_installed_by_ufba)" = true ] && [ -n "$LD" ] && [ -d "$LD" ]; then
                rm -rf "$LD"
                [ -L "$BIN_LINK" ] || [ -f "$BIN_LINK" ] && rm -f "$BIN_LINK"
                say 'Programa ai-memory removido.'
            fi
        fi
        rm -f "$STATE_FILE"; rmdir "$STATE_DIR" 2>/dev/null || true
        say ''
        say 'Pronto. A chave deste computador continua valida no servidor ate voce revoga-la:'
        say 'abra a ufba.app, va em "Computadores conectados" e remova este computador.'
        say "Os dados que ja estao no servidor nao sao apagados. A pasta de dados local ($DD) foi mantida."
        exit 0
    fi

    # =====================================================================
    # INSTALAR
    # =====================================================================
    say "ufba.app: instalador da memoria compartilhada ($IV)"
    [ $DRY -eq 1 ] && say '*** SIMULACAO (--dry-run): nada sera escrito nesta maquina. ***'

    # ---- 1. pre-checagem e manifesto ----
    http GET "$API/memory/install-manifest" '' ''
    [ "$HTTP_STATUS" -eq 200 ] || die "nao consegui obter o manifesto de instalacao em $API ($(api_msg))."
    MANIFEST_FLAT=$(printf '%s' "$HTTP_BODY" | json_flat)
    mget() { printf '%s\n' "$MANIFEST_FLAT" | awk -F '\t' -v p="$1" '$1==p { print $2; exit }'; }
    [ "$(mget schema)" = 1 ] && [ -n "$(mget aiMemory.version)" ] && [ -n "$(mget installer.minVersion)" ] || die 'manifesto de instalacao invalido (schema diferente de 1).'
    http GET "$MEM/identity" '' ''
    [ "$HTTP_STATUS" -ne 0 ] || die "nao consegui falar com o servidor de memoria ($MEM)."

    MIN=$(mget installer.minVersion)
    [ "$(vlt "$IV" "$MIN")" = 1 ] && die "este instalador ($IV) e antigo demais (minimo $MIN). Baixe o atual em https://ufba.app/instalar."
    [ -f "$0" ] || die 'nao consegui ler este proprio arquivo para conferir o hash; baixe o instalador e rode como arquivo (sh ufba-memory.sh).'
    EXPECT_SELF=$(mget installer.files.install.sh)
    [ "$(sha256_file "$0")" = "$(printf '%s' "$EXPECT_SELF" | tr 'A-F' 'a-f')" ] || die 'o hash deste instalador nao confere com o manifesto da ufba.app. Nada foi instalado. Baixe de novo o instalador oficial.'
    AIM_VERSION=$(mget aiMemory.version)
    ART_URL=$(mget "aiMemory.artifacts.$PLAT_KEY.url"); ART_SHA=$(mget "aiMemory.artifacts.$PLAT_KEY.sha256")
    { [ -n "$ART_URL" ] && [ -n "$ART_SHA" ]; } || die "o manifesto nao traz o ai-memory para $PLAT_KEY."
    allowed_url "$ART_URL" || die 'URL do ai-memory no manifesto nao e https.'

    # ---- deteccao do modo ----
    read_state
    TARGETS=$(collect_targets)
    AIM=''
    if have ai-memory; then AIM=$(command -v ai-memory)
    elif [ -x "$LIB_DIR/ai-memory" ]; then AIM="$LIB_DIR/ai-memory"
    elif [ -x "$BIN_LINK" ]; then AIM="$BIN_LINK"; fi
    SIGNALS=''
    addsig() { SIGNALS="${SIGNALS:+$SIGNALS; }$1"; }
    have ai-memory && addsig 'ai-memory no PATH'
    { [ -e "$BIN_LINK" ] || [ -L "$BIN_LINK" ]; } && addsig "programa em $BIN_LINK"
    [ -d "$LIB_DIR" ] && addsig "programa em $LIB_DIR"
    [ -d "$DATA_DIR" ] && addsig "pasta de dados $DATA_DIR"
    [ -f "$DATA_DIR/servers.toml" ] && addsig 'servers.toml'
    if [ -n "$TARGETS" ]; then
        while IFS='|' read -r _l _d _e; do has_hooks "$_d" && addsig "hooks do ai-memory em $_l"; done <<EOF
$TARGETS
EOF
    fi
    PREV_MODE=$(sget install_mode)
    if [ "$PREV_MODE" = fresh ] || [ "$PREV_MODE" = profile ]; then MODE=$PREV_MODE
    elif [ -n "$SIGNALS" ]; then MODE=profile; else MODE=fresh; fi
    say ''
    if [ "$MODE" = fresh ]; then say "Modo: fresh (nao ha ai-memory nesta maquina: vou instalar a versao $AIM_VERSION e a ufba.app sera o servidor padrao)."
    else say 'Modo: profile (ja existe ai-memory aqui: o servidor padrao, a chave e o modo de captura dele NAO serao tocados; so registro o perfil "ufba").'; fi
    [ -n "$SIGNALS" ] && say "  sinais: $SIGNALS"

    EXISTING_PROFILES=''
    if [ "$MODE" = profile ]; then
        [ -n "$AIM" ] || stop_planned "Encontrei sinais de um ai-memory existente ($SIGNALS), mas nao achei o programa no PATH nem em $LIB_DIR.
Nao vou instalar outro por cima. Coloque o ai-memory $AIM_VERSION no PATH (ou reinstale o seu) e rode de novo."
        _v=$("$AIM" --version 2>/dev/null) || _v=''
        HAVE=$(printf '%s' "$_v" | sed -n 's/.*\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\).*/\1/p' | head -n 1)
        [ -n "$HAVE" ] || stop_planned "Nao consegui ler a versao do ai-memory em $AIM."
        if [ "$(vlt "$HAVE" "$AIM_VERSION")" = 1 ]; then
            stop_planned "O seu ai-memory e a versao $HAVE, mais antiga que a $AIM_VERSION que a ufba.app exige para o modo perfil.
Uma versao antiga ignora o perfil e mandaria a captura para o seu servidor padrao.
Este instalador nunca atualiza o ai-memory de ninguem: atualize o seu por conta propria (ai-memory upgrade, ou baixe a $AIM_VERSION em github.com/akitaonrails/ai-memory) e rode de novo.
Programa encontrado: $AIM"
        fi
        _sl=$("$AIM" --data-dir "$DATA_DIR" server list --json 2>/dev/null) && EXISTING_PROFILES=$(printf '%s' "$_sl" | json_flat | awk -F '\t' '$1 ~ /\.name$/ { print $2 }')
    fi

    # ---- 4. agentes ----
    say ''
    [ -n "$TARGETS" ] || stop_planned 'Nao encontrei nenhum agente compativel (Claude Code ou contas do Maestri). Instale o Claude Code e rode de novo.'
    say 'Agentes encontrados:'
    CHOSEN=''
    while IFS='|' read -r _l _d _e; do
        if [ "$MODE" = profile ] && ! has_hooks "$_d"; then
            say "  - $_l: SEM hooks do ai-memory; vou pular (instale os seus hooks com 'ai-memory install-hooks --apply' nessa conta e rode de novo)."
            continue
        fi
        if confirm_item "  Conectar $_l ($_d)?"; then CHOSEN="${CHOSEN:+$CHOSEN
}$_l|$_d|$_e"; else say "  (pulado: $_l)"; fi
    done <<EOF
$TARGETS
EOF
    for _o in .codex .gemini .cursor; do
        [ -d "$HOME_DIR/$_o" ] && say "  - $_o encontrado, mas nao conectado: esse agente usa scripts que nao roteiam perfil de servidor."
    done
    if [ -z "$CHOSEN" ]; then
        [ "$MODE" = profile ] && stop_planned 'Nenhum agente com hooks do ai-memory foi selecionado. O modo perfil so conecta agentes que ja tem os hooks do ai-memory.'
        stop_planned 'Nenhum agente selecionado.'
    fi
    LABELS=$(printf '%s\n' "$CHOSEN" | awk -F '|' '{ printf "%s%s", (NR>1?", ":""), $1 }')

    # ---- roots (profile) ----
    ROOT_LIST=''
    if [ "$MODE" = profile ]; then
        _roots_in=$ROOTS
        ROOTS=''
        while IFS= read -r _r; do
            [ -n "$_r" ] || continue
            [ -d "$_r" ] || die "a pasta de --root nao existe: $_r"
            _full=$(cd "$_r" && pwd) || die "nao consegui entrar em $_r"
            ROOT_LIST="${ROOT_LIST:+$ROOT_LIST
}$_full"
        done <<EOF
$_roots_in
EOF
        ALREADY=0; printf '%s\n' "$EXISTING_PROFILES" | grep -qx 'ufba' && ALREADY=1
        if [ -z "$ROOT_LIST" ] && [ $ALREADY -eq 0 ]; then
            [ $YES -eq 1 ] && die 'em --yes o modo perfil exige --root <pasta onde ficam os repositorios da ufba.app>.'
            say ''
            say 'Um repositorio so pode escolher o perfil "ufba" se estiver dentro de uma pasta que voce autorizar.'
            ask 'Pasta onde ficam (ou ficarao) os repositorios da ufba.app:'
            [ -n "$ANSWER" ] || die 'preciso de uma pasta para o perfil.'
            [ -d "$ANSWER" ] || die "a pasta nao existe: $ANSWER"
            ROOT_LIST=$(cd "$ANSWER" && pwd)
        fi
        [ -z "$ROOT_LIST" ] && [ $ALREADY -eq 1 ] && say 'Perfil "ufba" ja existe: mantenho as pastas (roots) que ele ja tem.'
    elif [ -n "$ROOTS" ]; then warn '--root so vale no modo perfil; ignorado.'; fi

    NAME=$CNAME; [ -n "$NAME" ] || NAME=$(hostname 2>/dev/null || true); [ -n "$NAME" ] || NAME=computador

    # ---- plano ----
    say ''
    say 'Plano (o que vai mudar nesta maquina):'
    if [ "$MODE" = fresh ]; then
        say "  - instalar o ai-memory $AIM_VERSION em $LIB_DIR (link em $BIN_LINK; sha256 conferido contra o manifesto)"
        say "  - pasta de dados do ai-memory: $DATA_DIR"
        say "  - gravar os hooks do ai-memory (servidor padrao = ufba.app, captura so em repositorios com marcador) em: $LABELS"
    else
        say "  - registrar o perfil de servidor 'ufba' no ai-memory existente (dados em $DATA_DIR)${ROOT_LIST:+, roots: $(printf '%s' "$ROOT_LIST" | tr '\n' ' ')}"
        say '  - NAO mexer nos hooks, no servidor padrao nem no modo de captura'
    fi
    say "  - registrar o MCP \"ufba\" ($MCP_URL) em: $LABELS"
    say "  - guardar o id deste computador em $STATE_FILE (sem segredo)"
    say '  - login de dispositivo: voce aprova na ufba.app; a chave deste computador fica so no ai-memory'
    if [ $DRY -eq 1 ]; then say ''; say 'Simulacao (--dry-run) concluida: nada foi alterado.'; exit 0; fi

    # ---- 2. binario (fresh) ----
    INSTALLED_BIN=false
    if [ "$MODE" = fresh ]; then
        NEED=1
        if [ -x "$LIB_DIR/ai-memory" ]; then
            _v=$("$LIB_DIR/ai-memory" --version 2>/dev/null) || _v=''
            case "$_v" in *"$AIM_VERSION"*) NEED=0; say "ai-memory $AIM_VERSION ja instalado."; [ "$(sget ai_memory_installed_by_ufba)" = true ] && INSTALLED_BIN=true ;; esac
        fi
        if [ $NEED -eq 1 ]; then
            say "Baixando o ai-memory $AIM_VERSION ..."
            WORK=$(mktemp -d "${TMPDIR:-/tmp}/ufba-memory.XXXXXX") || die 'nao consegui criar uma pasta temporaria.'
            trap 'rm -rf "$WORK"' EXIT INT TERM
            fetch_file "$ART_URL" "$WORK/ai-memory.tar.gz" || die 'nao consegui baixar o ai-memory.'
            _got=$(sha256_file "$WORK/ai-memory.tar.gz")
            [ "$_got" = "$(printf '%s' "$ART_SHA" | tr 'A-F' 'a-f')" ] || die "o SHA-256 do ai-memory baixado ($_got) nao confere com o manifesto. Nada foi instalado."
            (cd "$WORK" && tar -tzf ai-memory.tar.gz) | awk '$0 ~ /^\// || $0 ~ /(^|\/)\.\.(\/|$)/ { bad=1 } END { exit bad }' || die 'o arquivo do ai-memory tem um caminho suspeito. Nada foi instalado.'
            mkdir -p "$WORK/release"
            (cd "$WORK" && { tar --no-same-owner -xzf ai-memory.tar.gz -C release 2>/dev/null || tar -xzf ai-memory.tar.gz -C release; }) || die 'nao consegui extrair o ai-memory.'
            [ -f "$WORK/release/ai-memory" ] || die 'o arquivo do ai-memory nao tem o binario ai-memory.'
            chmod 0755 "$WORK/release/ai-memory"
            mkdir -p "$(dirname "$LIB_DIR")" "$(dirname "$BIN_LINK")"
            OLD=''
            if [ -e "$LIB_DIR" ]; then OLD="$LIB_DIR.old.$$"; mv "$LIB_DIR" "$OLD"; fi
            if ! mv "$WORK/release" "$LIB_DIR"; then [ -n "$OLD" ] && mv "$OLD" "$LIB_DIR"; die 'nao consegui instalar o ai-memory.'; fi
            [ -n "$OLD" ] && rm -rf "$OLD"
            rm -f "$BIN_LINK"; ln -s "$LIB_DIR/ai-memory" "$BIN_LINK" 2>/dev/null || cp "$LIB_DIR/ai-memory" "$BIN_LINK"
            INSTALLED_BIN=true
            say "ai-memory instalado em $LIB_DIR."
            case ":$PATH:" in *":$(dirname "$BIN_LINK"):"*) ;; *) say "$(dirname "$BIN_LINK") nao esta no PATH; adicione, por exemplo: export PATH=\"$(dirname "$BIN_LINK"):\$PATH\"" ;; esac
        fi
        AIM="$LIB_DIR/ai-memory"
        "$AIM" --version >/dev/null 2>&1 || die 'o ai-memory instalado nao executa nesta maquina.'
    fi

    # ---- 3. login de dispositivo ----
    say ''
    http POST "$API/oauth/device_authorization" '' 'application/x-www-form-urlencoded' --data-urlencode 'client_id=ufba-installer' --data-urlencode 'scope=memory:connect' --data-urlencode "computer_name=$NAME" --data-urlencode "os=$OS_NAME"
    [ "$HTTP_STATUS" -eq 200 ] || die "nao consegui iniciar o login de dispositivo: $(api_msg)"
    DEV_FLAT=$(printf '%s' "$HTTP_BODY" | json_flat)
    dget() { printf '%s\n' "$DEV_FLAT" | awk -F '\t' -v p="$1" '$1==p { print $2; exit }'; }
    DEVICE_CODE=$(dget device_code); USER_CODE=$(dget user_code)
    { [ -n "$DEVICE_CODE" ] && [ -n "$USER_CODE" ]; } || die 'resposta inesperada no login de dispositivo.'
    say 'Para autorizar este computador:'
    say "  1. abra  $(dget verification_uri)"
    say "  2. confira que o codigo na tela e  $USER_CODE  (so aprove se ele apareceu AQUI agora)"
    _complete=$(dget verification_uri_complete)
    if [ "${UFBA_NO_BROWSER:-}" != 1 ] && [ $TEST -ne 1 ]; then
        case "$_complete" in https://ufba.app/*|https://*.ufba.app/*)
            if have xdg-open; then xdg-open "$_complete" >/dev/null 2>&1 || true; elif have open; then open "$_complete" >/dev/null 2>&1 || true; fi ;; esac
    fi
    INTERVAL=$(dget interval); case "$INTERVAL" in ''|*[!0-9]*|0) INTERVAL=5 ;; esac
    DEADLINE=$(( $(date +%s) + $(dget expires_in | awk '{print int($1)}') ))
    SHORT=''
    say 'Aguardando a sua aprovacao ...'
    while [ "$(date +%s)" -lt "$DEADLINE" ]; do
        wait_s "$INTERVAL"
        http POST "$API/token" '' 'application/x-www-form-urlencoded' --data-urlencode 'grant_type=urn:ietf:params:oauth:grant-type:device_code' --data-urlencode "device_code=$DEVICE_CODE" --data-urlencode 'client_id=ufba-installer'
        if [ "$HTTP_STATUS" -eq 200 ]; then SHORT=$(jget "$HTTP_BODY" access_token); [ -n "$SHORT" ] || die 'resposta inesperada do token.'; break; fi
        [ "$HTTP_STATUS" -eq 0 ] && continue
        case "$(jget "$HTTP_BODY" error)" in
            authorization_pending) ;;
            slow_down) INTERVAL=$((INTERVAL + 5)) ;;
            access_denied) printf '\nA autorizacao foi negada na ufba.app. Nada foi instalado alem do programa (se era o modo fresh).\n'; exit 4 ;;
            expired_token) printf '\nO codigo expirou. Rode o instalador de novo para ver um novo.\n'; exit 4 ;;
            *) die "login de dispositivo falhou: $(api_msg)" ;;
        esac
    done
    [ -n "$SHORT" ] || { printf '\nO tempo para aprovar acabou. Rode o instalador de novo.\n'; exit 4; }
    say 'Autorizado.'

    # ---- POST /memory/computers (idempotente por computer_id) ----
    COMPUTER_ID=$(sget computer_id)
    PAYLOAD="{\"name\":\"$(json_str "$NAME")\",\"os\":\"$OS_NAME\",\"agents\":[\"claude-code\"],\"client_version\":\"ai-memory $AIM_VERSION\",\"install_mode\":\"$MODE\"${COMPUTER_ID:+,\"computer_id\":\"$(json_str "$COMPUTER_ID")\"}}"
    KEY=''; ATTEMPT=1; CREATED=''
    while [ $ATTEMPT -le 3 ]; do
        http POST "$API/memory/computers" "$SHORT" 'application/json' --data-binary "$PAYLOAD"
        if [ "$HTTP_STATUS" -eq 200 ]; then
            CREATED=$(printf '%s' "$HTTP_BODY" | json_flat)
            KEY=$(printf '%s\n' "$CREATED" | awk -F '\t' '$1=="key" { print $2; exit }')
            NEW_ID=$(printf '%s\n' "$CREATED" | awk -F '\t' '$1=="computer_id" { print $2; exit }')
            [ -n "$KEY" ] && [ -n "$NEW_ID" ] && break
            KEY=''
        elif [ "$HTTP_STATUS" -ne 0 ] && [ "$HTTP_STATUS" -lt 500 ]; then die "a ufba.app recusou o pedido: $(api_msg)"; fi
        HTTP_BODY=''
        [ $ATTEMPT -lt 3 ] && { warn 'a resposta se perdeu ou o servidor falhou; tentando de novo (com o mesmo id do computador, a chave e trocada com seguranca).'; wait_s $((2 * ATTEMPT)); }
        ATTEMPT=$((ATTEMPT + 1))
    done
    [ -n "$KEY" ] || die 'nao consegui registrar o computador. Rode o instalador de novo em alguns minutos.'
    COMPUTER_ID=$NEW_ID
    USERNAME=$(printf '%s\n' "$CREATED" | awk -F '\t' '$1=="username" { print $2; exit }')
    _murl=$(printf '%s\n' "$CREATED" | awk -F '\t' '$1=="memory_url" { print $2; exit }')
    CREATED=''; HTTP_BODY=''
    [ "${_murl%/}" = "$MEM" ] || die 'o endereco do servidor de memoria devolvido pela API nao e o esperado. Nada foi gravado.'

    write_state() {  # $1 = JSON de targets
        mkdir -p "$STATE_DIR"
        _rl=$(printf '%s\n' "$ROOT_LIST" | awk 'NF { printf "%s\"%s\"", (c++?",":""), $0 }' | sed 's/\\/\\\\/g')
        _exe=$(json_str "$AIM")
        {
            printf '{\n  "schema": 1,\n  "computer_id": "%s",\n  "name": "%s",\n  "os": "%s",\n  "install_mode": "%s",\n' "$COMPUTER_ID" "$(json_str "$NAME")" "$OS_NAME" "$MODE"
            printf '  "installer_version": "%s",\n  "ai_memory_version": "%s",\n  "ai_memory_exe": "%s",\n' "$IV" "$AIM_VERSION" "$_exe"
            if [ "$MODE" = fresh ]; then printf '  "ai_memory_dir": "%s",\n' "$(json_str "$LIB_DIR")"; else printf '  "ai_memory_dir": null,\n'; fi
            printf '  "ai_memory_installed_by_ufba": %s,\n  "data_dir": "%s",\n  "roots": [%s],\n' "$INSTALLED_BIN" "$(json_str "$DATA_DIR")" "$_rl"
            printf '  "targets": [%s],\n  "mcp_url": "%s",\n  "updated_at": "%s"\n}\n' "$1" "$(json_str "$MCP_URL")" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        } > "$STATE_FILE.tmp" && mv "$STATE_FILE.tmp" "$STATE_FILE"
    }
    write_state ''

    # ---- 5. gravar a chave ----
    WRITE_FAIL=''
    if [ "$MODE" = fresh ]; then
        while IFS='|' read -r _l _d _e; do
            if ! _o=$(run_aim "$_e" "$KEY" "$AIM" --data-dir "$DATA_DIR" install-hooks --agent claude-code --server-url "$MEM" --capture-mode allowlist --as-user "$USERNAME" --apply); then
                WRITE_FAIL="install-hooks falhou em $_l: $(printf '%s' "$_o" | redact "$KEY")"; break
            fi
        done <<EOF
$CHOSEN
EOF
    else
        set -- --data-dir "$DATA_DIR" server add ufba --url "$MEM"
        while IFS= read -r _r; do [ -n "$_r" ] && set -- "$@" --root "$_r"; done <<EOF
$ROOT_LIST
EOF
        set -- "$@" --auth-token-stdin
        if ! _o=$(printf '%s\n' "$KEY" | "$AIM" "$@" 2>&1); then WRITE_FAIL="server add falhou: $(printf '%s' "$_o" | redact "$KEY")"; fi
    fi
    if [ -n "$WRITE_FAIL" ]; then
        KEY=''
        printf '\nNao consegui gravar a chave; por seguranca NAO confirmei o computador. Em ate 10 minutos a ufba.app revoga a chave sozinha.\n'
        printf 'Corrija o problema e rode o instalador de novo (ele reaproveita o id deste computador).\n'
        die "$WRITE_FAIL"
    fi
    KEY=''
    say 'Chave gravada no ai-memory (nao aparece em nenhum log).'

    # ---- confirmar (consome o token curto) ----
    CONFIRMED=0; _i=1
    while [ $_i -le 3 ] && [ $CONFIRMED -eq 0 ]; do
        http POST "$API/memory/computers/$COMPUTER_ID/confirm" "$SHORT" ''
        if [ "$HTTP_STATUS" -eq 204 ] || [ "$HTTP_STATUS" -eq 200 ]; then CONFIRMED=1
        elif [ "$HTTP_STATUS" -ne 0 ] && [ "$HTTP_STATUS" -lt 500 ]; then die "a ufba.app nao confirmou o computador: $(api_msg)"
        else wait_s $((2 * _i)); fi
        _i=$((_i + 1))
    done
    [ $CONFIRMED -eq 1 ] || die 'a chave foi gravada, mas nao consegui confirmar com a ufba.app. Rode o instalador de novo (em ate 10 minutos a chave nao confirmada e revogada).'
    SHORT=''

    # ---- 7. MCP ----
    MCP_OK=''; TARGETS_JSON=''
    while IFS='|' read -r _l _d _e; do
        TARGETS_JSON="${TARGETS_JSON:+$TARGETS_JSON,}{\"label\":\"$(json_str "$_l")\",\"kind\":\"claude-code\",\"config_dir\":\"$(json_str "$_d")\",\"env_dir\":$([ -n "$_e" ] && printf '"%s"' "$(json_str "$_e")" || printf null)}"
        if ! have claude; then warn "comando claude nao encontrado; em $_l rode: claude mcp add --transport http --scope user ufba $MCP_URL"; continue; fi
        if ( [ -n "$_e" ] && export CLAUDE_CONFIG_DIR="$_e"; claude mcp get ufba >/dev/null 2>&1 </dev/null ); then say "MCP ufba ja registrado: $_l"; MCP_OK="${MCP_OK:+$MCP_OK, }$_l"; continue; fi
        if _o=$( ( [ -n "$_e" ] && export CLAUDE_CONFIG_DIR="$_e"; claude mcp add --transport http --scope user ufba "$MCP_URL" </dev/null ) 2>&1 ); then say "MCP ufba registrado: $_l"; MCP_OK="${MCP_OK:+$MCP_OK, }$_l"
        else warn "nao consegui registrar o MCP em $_l: $_o"; fi
    done <<EOF
$CHOSEN
EOF
    write_state "$TARGETS_JSON"

    # ---- 9. auto-teste (so leitura) ----
    say ''
    say 'Verificando:'
    if [ "$MODE" = profile ]; then
        if "$AIM" --data-dir "$DATA_DIR" server list --json 2>/dev/null | grep -q '"name"[[:space:]]*:[[:space:]]*"ufba"'; then say '  ok: o perfil "ufba" esta registrado.'; else warn 'o perfil "ufba" nao apareceu em "ai-memory server list".'; fi
        _root1=$(printf '%s\n' "$ROOT_LIST" | head -n 1)
        if [ -n "$_root1" ]; then
            _probe="$_root1/.ufba-selftest-$$"
            if mkdir "$_probe" 2>/dev/null; then
                printf 'workspace = "ufba-app"\nproject = "selftest"\nserver = "ufba"\n' > "$_probe/.ai-memory.toml"
                _cc=$(cd "$_probe" && printf '{}' | "$AIM" --data-dir "$DATA_DIR" hook --event user-prompt-submit --agent claude-code --check-capture 2>&1) || true
                rm -rf "$_probe"
                case "$_cc" in *'"server_resolution":"marker"'*|*'"server_resolution": "marker"'*) say '  ok: um repositorio com marcador server = "ufba" dentro da pasta autorizada captura para a ufba.app.' ;;
                    *) warn 'o teste de captura nao devolveu server_resolution = marker (confira a pasta autorizada e rode: ai-memory hook --check-capture).' ;; esac
            fi
        fi
        KEYFILE="$DATA_DIR/auth-tokens/ufba"
    else
        say '  ok: hooks gravados (servidor padrao = ufba.app, captura so em repositorios com marcador).'
        KEYFILE="$DATA_DIR/auth-token"
    fi
    IDOK=0
    if [ -f "$KEYFILE" ]; then
        _k2=$(head -n 1 "$KEYFILE" | tr -d '\r\n')
        if [ -n "$_k2" ]; then http GET "$MEM/identity" "$_k2" ''; _k2=''; case "$HTTP_BODY" in *"$USERNAME"*) [ "$HTTP_STATUS" -eq 200 ] && IDOK=1 ;; esac; fi
    fi
    if [ $IDOK -eq 1 ]; then say "  ok: o servidor de memoria reconhece este computador como a sua conta (user:$USERNAME)."; else warn 'nao consegui confirmar a identidade no servidor de memoria (/identity). Se algo falhar depois, rode o instalador de novo.'; fi

    # ---- 10. resumo ----
    say ''
    say '================ Resumo ================'
    say "Modo: $MODE    Computador: $NAME    Id: $COMPUTER_ID"
    if [ "$MODE" = fresh ]; then say "- ai-memory $AIM_VERSION em $LIB_DIR; hooks gravados em: $LABELS"
    else say "- perfil \"ufba\" registrado${ROOT_LIST:+ (roots: $(printf '%s' "$ROOT_LIST" | tr '\n' ' '))}; seus hooks e servidor padrao ficaram como estavam"; fi
    say "- MCP \"ufba\" registrado em: ${MCP_OK:-(nenhuma conta)}"
    say "- id do computador (sem segredo): $STATE_FILE"
    if [ "$MODE" = profile ]; then
        say ''
        say 'Para um repositorio capturar para a ufba.app, ponha na raiz dele (dentro da pasta autorizada) um .ai-memory.toml com:'
        say '  workspace = "ufba-app"'
        say '  project   = "<projeto>"'
        say '  server    = "ufba"'
    fi
    say ''
    say 'Para desfazer: rode este instalador com o comando uninstall, e remova este computador em "Computadores conectados" na ufba.app (isso revoga a chave).'
    say 'No Claude Code, rode /mcp e autentique o servidor "ufba" (login com Google @ufba.br).'
    exit 0
}

main "$@"
