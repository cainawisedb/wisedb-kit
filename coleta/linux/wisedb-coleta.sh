#!/bin/bash
#==============================================================================
# wisedb-coleta.sh  (WiseDB, wizard de coleta para Linux)
#
# Descobre os bancos do servidor (Oracle, SQL Server, MySQL/MariaDB, PostgreSQL,
# MongoDB) e o ambiente de nuvem, coleta SOMENTE metadados com SQL de leitura,
# monta 1 JSON (contrato wisedb.coleta/1) e envia por HTTPS PUT para um link PAR
# da OCI. Nada e instalado: so /etc/wisedb/coleta.conf (600) e, se pedido, 1 linha
# no crontab do root. Detalhes: LEIAME.md e contrato/CONTRATO_v1.md.
#
# Uso:
#   wisedb-coleta.sh --descobrir
#   wisedb-coleta.sh --coletar --cliente ID --saida ARQ.json.gz
#   wisedb-coleta.sh --cliente ID --link URL_PAR             (coleta e envia)
#   wisedb-coleta.sh --agendar diario|semanal --cliente ID --link URL_PAR \
#                    --url-wizard URL --sha256 HASH
#   wisedb-coleta.sh --remover-agendamento [--apagar-conf]
#
# Codigos de saida:
#   0 ok | 1 uso/parametros | 2 ja em execucao | 3 pre-requisito ausente
#   4 havia instancias e nenhuma foi coletada | 5 falha ao montar o JSON/gzip
#   6 falha no envio | 7 falha no agendamento/configuracao
#==============================================================================
WIZ_VERSAO="1.0.1"
SCHEMA_ID="wisedb.coleta/1"

if [ "${BASH_VERSINFO[0]:-0}" -lt 4 ] || { [ "${BASH_VERSINFO[0]}" -eq 4 ] && [ "${BASH_VERSINFO[1]}" -lt 2 ]; }; then
    echo "wisedb-coleta: requer bash 4.2 ou superior" >&2; exit 3
fi

umask 077
ORIG_LC_ALL=${LC_ALL-}; ORIG_LANG=${LANG-}
export LC_ALL=C
export PATH="$PATH:/usr/local/sbin:/usr/local/bin:/usr/sbin:/sbin:/usr/bin:/bin"

TAB=$'\t'
ME=$(id -un 2>/dev/null)
[ -n "$ME" ] || ME="?"
CONF_PADRAO="/etc/wisedb/coleta.conf"
CONF="${WISEDB_CONF:-$CONF_PADRAO}"
LOGFILE_CRON="/var/log/wisedb-coleta.log"
TAG_CRON="# wisedb-coleta"
JANELA_DIAS=35
INATIVO_MIN=180
TMO="${WISEDB_TIMEOUT:-120}"
W=""

#------------------------------------------------------------------ utilitarios
log() { printf '%s [%s] %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$1" "$2" >&2; }

usage() {
    cat <<EOF
wisedb-coleta.sh v$WIZ_VERSAO (WiseDB)
Uso:
  --descobrir                     mostra o inventario (bancos e nuvem); nao coleta nem envia
  --coletar --saida ARQ.json.gz   coleta e grava o arquivo; NAO envia
  (padrao)                        coleta e envia ao link PAR
  --agendar diario|semanal        grava $CONF_PADRAO (600) e 1 linha no crontab do root
  --remover-agendamento           remove a linha do crontab (--apagar-conf apaga tambem o conf)
  --gravar-credenciais            grava WISEDB_MSSQL_*/WISEDB_MONGO_URI do ambiente em <dir do conf>/credenciais (600); o cron le este arquivo
  --enviar-arquivo ARQ.json.gz    reenvia um arquivo gerado antes por --coletar (nao coleta)
Parametros:
  --cliente ID        identificador do cliente (A-Z a-z 0-9 . _ -)
  --link URL          link PAR da OCI (termina em /o/); ou WISEDB_LINK, ou o conf
  --saida ARQ         grava uma copia local do .json.gz
  --url-wizard URL    (--agendar) URL publicada deste script
  --sha256 HASH       (--agendar) SHA-256 do script publicado
  --timeout SEG       limite por consulta (padrao $TMO)
  --versao | --ajuda
Variaveis opcionais (lidas so na execucao, nunca gravadas):
  WISEDB_MSSQL_USER / WISEDB_MSSQL_PASS   SQL Server com autenticacao
  WISEDB_MONGO_URI                         MongoDB com autenticacao
Rode como root para o wizard alternar para o usuario dono de cada banco.
EOF
}

# emit ARQ campo...  (grava 1 linha TSV em $W/ARQ)
emit() { local f=$1; shift; local IFS=$TAB; printf '%s\n' "$*" >> "$W/$f"; }

aviso() { emit avisos.tsv "$1"; log AVISO "$1"; }

# limpa texto livre: 1 linha, sem controle, no maximo $2 caracteres
clean() { printf '%s' "$1" | tr '\r\n\t' '   ' | tr -d '\000-\037\177' | cut -c1-"${2:-160}"; }

jstr() { local s=$1; s=${s//\\/\\\\}; s=${s//\"/\\\"}; printf '"%s"' "$s"; }
jnull() { if [ -n "$1" ]; then jstr "$1"; else printf 'null'; fi; }

tmo() { if command -v timeout >/dev/null 2>&1; then timeout "$TMO" "$@"; else "$@"; fi; }

# as_user USUARIO cmd...  (stdin repassado; rc 126 se nao der para alternar)
as_user() {
    local u=$1; shift
    if [ -z "$u" ] || [ "$u" = "$ME" ]; then
        tmo "$@"
    elif [ "$EUID" -eq 0 ]; then
        local cmd
        cmd="exec $(printf '%q ' "$@")"
        if command -v runuser >/dev/null 2>&1; then tmo runuser -s /bin/bash "$u" -c "$cmd"
        elif command -v su >/dev/null 2>&1; then tmo su -s /bin/bash "$u" -c "$cmd"
        else echo "sem runuser/su para alternar para $u"; return 126; fi
    else
        echo "requer root para alternar para o usuario $u"; return 126
    fi
}

#------------------------------------------------------------------ argumentos
MODO="padrao"; ARQ_ENVIO=""; CLIENTE=""; LINK=""; SAIDA=""; AGENDA=""; URL_WIZARD=""; SHA_WIZARD=""; APAGAR_CONF=0
parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --descobrir) MODO="descobrir"; shift ;;
            --coletar) MODO="coletar"; shift ;;
            --agendar) [ $# -ge 2 ] || { echo "falta o valor de --agendar (diario|semanal)" >&2; exit 1; }
                       MODO="agendar"; AGENDA="$2"; shift 2 ;;
            --remover-agendamento) MODO="remover"; shift ;;
            --enviar-arquivo) [ $# -ge 2 ] || { echo "falta o valor de --enviar-arquivo" >&2; exit 1; }
                              MODO="enviar"; ARQ_ENVIO="$2"; shift 2 ;;
            --apagar-conf) APAGAR_CONF=1; shift ;;
            --gravar-credenciais) MODO="gravarcred"; shift ;;
            --cliente) [ $# -ge 2 ] || { echo "falta o valor de --cliente" >&2; exit 1; }; CLIENTE="$2"; shift 2 ;;
            --link) [ $# -ge 2 ] || { echo "falta o valor de --link" >&2; exit 1; }; LINK="$2"; shift 2 ;;
            --saida) [ $# -ge 2 ] || { echo "falta o valor de --saida" >&2; exit 1; }; SAIDA="$2"; shift 2 ;;
            --url-wizard) [ $# -ge 2 ] || { echo "falta o valor de --url-wizard" >&2; exit 1; }; URL_WIZARD="$2"; shift 2 ;;
            --sha256) [ $# -ge 2 ] || { echo "falta o valor de --sha256" >&2; exit 1; }; SHA_WIZARD="$2"; shift 2 ;;
            --timeout) [ $# -ge 2 ] || { echo "falta o valor de --timeout" >&2; exit 1; }; TMO="$2"; shift 2 ;;
            --versao) echo "wisedb-coleta.sh $WIZ_VERSAO"; exit 0 ;;
            -h|--ajuda) usage; exit 0 ;;
            *) echo "opcao invalida: $1" >&2; usage >&2; exit 1 ;;
        esac
    done
    case "$TMO" in ""|*[!0-9]*) echo "--timeout deve ser inteiro" >&2; exit 1 ;; esac
    case "$AGENDA" in ""|diario|semanal) ;; *) echo "--agendar aceita diario ou semanal" >&2; exit 1 ;; esac
    if [ "$MODO" = "coletar" ] && [ -z "$SAIDA" ]; then echo "--coletar exige --saida ARQ.json.gz" >&2; exit 1; fi
}

#------------------------------------------------------------------ configuracao
C_CLIENTE=""; C_LINK=""; C_URL=""; C_SHA=""
ler_conf() {
    [ -f "$CONF" ] || return 0
    local mode owner l k v
    mode=$(stat -c %a "$CONF" 2>/dev/null || echo 777)
    owner=$(stat -c %u "$CONF" 2>/dev/null || echo 9999)
    case "$mode" in
        *[2367]?|*?[1-7]) log ERRO "$CONF com permissao insuficiente ($mode); use chmod 600"; exit 7 ;;
    esac
    if [ "$owner" != "0" ] && [ "$owner" != "$EUID" ]; then log ERRO "$CONF pertence a outro usuario; ignorado"; exit 7; fi
    while IFS= read -r l || [ -n "$l" ]; do
        l=${l%$'\r'}
        case "$l" in ""|"#"*) continue ;; esac
        k=${l%%=*}; v=${l#*=}
        v=${v#\"}; v=${v%\"}; v=${v#\'}; v=${v%\'}
        case "$k" in
            CLIENTE_ID) C_CLIENTE=$v ;;
            LINK_PAR) C_LINK=$v ;;
            URL_WIZARD) C_URL=$v ;;
            SHA256_WIZARD) C_SHA=$v ;;
        esac
    done < "$CONF"
}


# Credenciais opcionais para execucao SEM ambiente (cron): <dir do conf>/credenciais (600, dono root).
# Linhas CHAVE=VALOR, so WISEDB_MSSQL_USER, WISEDB_MSSQL_PASS e WISEDB_MONGO_URI. Variavel ja
# definida no ambiente tem prioridade. Lido em tempo de execucao; nunca vai para JSON, log ou conf.
CRED_ARQ=""
ler_credenciais() {
    CRED_ARQ="$(dirname "$CONF")/credenciais"
    [ -f "$CRED_ARQ" ] || return 0
    local mode owner l k v
    mode=$(stat -c %a "$CRED_ARQ" 2>/dev/null || echo 777)
    owner=$(stat -c %u "$CRED_ARQ" 2>/dev/null || echo 9999)
    case "$mode" in
        600|400) ;;
        *) log ERRO "$CRED_ARQ com permissao insuficiente ($mode); use chmod 600; credenciais ignoradas"; return 0 ;;
    esac
    if [ "$owner" != "0" ] && [ "$owner" != "$EUID" ]; then log ERRO "$CRED_ARQ pertence a outro usuario; ignorado"; return 0; fi
    while IFS= read -r l || [ -n "$l" ]; do
        l=${l%$'\r'}
        case "$l" in ""|"#"*) continue ;; esac
        k=${l%%=*}; v=${l#*=}
        case "$k" in
            WISEDB_MSSQL_USER) [ -n "${WISEDB_MSSQL_USER:-}" ] || export WISEDB_MSSQL_USER=$v ;;
            WISEDB_MSSQL_PASS) [ -n "${WISEDB_MSSQL_PASS:-}" ] || export WISEDB_MSSQL_PASS=$v ;;
            WISEDB_MONGO_URI) [ -n "${WISEDB_MONGO_URI:-}" ] || export WISEDB_MONGO_URI=$v ;;
        esac
    done < "$CRED_ARQ"
}

# --gravar-credenciais: grava as variaveis WISEDB_MSSQL_USER/PASS e WISEDB_MONGO_URI do ambiente atual
do_gravar_cred() {
    if [ "$EUID" -ne 0 ]; then echo "--gravar-credenciais exige root" >&2; exit 7; fi
    local dir arq k v n=0 tmpc
    dir=$(dirname "$CONF"); arq="$dir/credenciais"
    mkdir -p "$dir" && chmod 700 "$dir" || { echo "nao consegui criar $dir" >&2; exit 7; }
    tmpc="$arq.tmp.$$"
    : > "$tmpc" && chmod 600 "$tmpc" || { echo "nao consegui gravar $arq" >&2; exit 7; }
    for k in WISEDB_MSSQL_USER WISEDB_MSSQL_PASS WISEDB_MONGO_URI; do
        v=${!k:-}
        [ -n "$v" ] || continue
        case "$v" in *$'\n'*|*$'\r'*) rm -f "$tmpc"; echo "$k contem quebra de linha; nao gravado" >&2; exit 7 ;; esac
        printf '%s=%s\n' "$k" "$v" >> "$tmpc"; n=$((n + 1))
    done
    if [ "$n" -eq 0 ]; then rm -f "$tmpc"; echo "defina WISEDB_MSSQL_USER/PASS e/ou WISEDB_MONGO_URI no ambiente (sudo -E)" >&2; exit 1; fi
    mv -f "$tmpc" "$arq" || { rm -f "$tmpc"; echo "nao consegui gravar $arq" >&2; exit 7; }
    echo "Credenciais gravadas em $arq (600, root): $n variavel(is). Lidas so na execucao; nunca vao para JSON ou log."
    exit 0
}
valida_cliente() { case "$1" in ""|*[!A-Za-z0-9._-]*) return 1 ;; esac; return 0; }
valida_link() { case "$1" in https://*/o/) ;; *) return 1 ;; esac; case "$1" in *[!A-Za-z0-9._~:/%@+=-]*) return 1 ;; esac; return 0; }
link_curto() { printf '%s...' "${LINK:0:30}"; }
oculta_link() { # remove o link (e a URL de envio) de um texto
    local t=$1
    [ -z "$LINK" ] || t=${t//"$LINK"/<link>}
    [ -z "${URL_ENVIO:-}" ] || t=${t//"$URL_ENVIO"/<url>}
    printf '%s' "$t"
}

#------------------------------------------------------------------ ambiente
HOST_NOME=""; HOST_SO=""; NUVEM=""; NUVEM_ID=""; CLI_OK=""
init_ambiente() {
    W=$(mktemp -d "${TMPDIR:-/tmp}/wisedb-coleta.XXXXXX") || { echo "mktemp falhou" >&2; exit 3; }
    chmod 711 "$W"
    trap 'rm -rf "$W"' EXIT
    trap 'exit 130' INT TERM
    : > "$W/inv.tsv"; : > "$W/cresc.tsv"; : > "$W/bk.tsv"; : > "$W/avisos.tsv"; : > "$W/found.dat"
    HOST_NOME=$(hostname -s 2>/dev/null || hostname 2>/dev/null || uname -n 2>/dev/null)
    HOST_NOME=$(printf '%s' "$HOST_NOME" | tr -cd 'A-Za-z0-9_.-')
    [ -n "$HOST_NOME" ] || HOST_NOME="host"
    HOST_SO=$( . /etc/os-release 2>/dev/null && printf '%s' "${PRETTY_NAME:-$NAME}" )
    [ -n "$HOST_SO" ] || HOST_SO=$(uname -sr 2>/dev/null)
    HOST_SO=$(clean "$HOST_SO" 80)
    gravar_awk_expdp
}

#------------------------------------------------------------------ nuvem
detect_cloud() {
    NUVEM=""; NUVEM_ID=""
    if ! command -v curl >/dev/null 2>&1; then aviso "curl ausente: deteccao de nuvem ignorada"; return; fi
    local c="curl -s -f --connect-timeout 2 --max-time 2" out rc tok base="http://169.254.169.254"
    out=$($c -H 'Authorization: Bearer Oracle' "$base/opc/v2/instance/" 2>/dev/null); rc=$?
    if [ $rc -eq 0 ] && [ -n "$out" ]; then
        NUVEM_ID=$(printf '%s' "$out" | tr -d '\n' | sed -n 's/.*"id" *: *"\(ocid1\.instance[^"]*\)".*/\1/p')
        case "$NUVEM_ID" in ocid1.instance.*) NUVEM="oci"; return ;; esac
        NUVEM_ID=""
    fi
    case $rc in 6|7|28) return ;; esac
    out=$($c -H 'Metadata: true' "$base/metadata/instance/compute/vmId?api-version=2021-02-01&format=text" 2>/dev/null)
    case "$out" in [0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]-*) NUVEM="azure"; NUVEM_ID=$(clean "$out" 64); return ;; esac
    out=$($c -H 'Metadata-Flavor: Google' "$base/computeMetadata/v1/instance/id" 2>/dev/null)
    case "$out" in ""|*[!0-9]*) ;; *) NUVEM="gcp"; NUVEM_ID="$out"; return ;; esac
    tok=$($c -X PUT -H 'X-aws-ec2-metadata-token-ttl-seconds: 60' "$base/latest/api/token" 2>/dev/null)
    if [ -n "$tok" ]; then
        out=$($c -H "X-aws-ec2-metadata-token: $tok" "$base/latest/meta-data/instance-id" 2>/dev/null)
        case "$out" in i-[0-9a-f]*) NUVEM="aws"; NUVEM_ID=$(clean "$out" 64); return ;; esac
    fi
}

# CLIs em Python (oci, az...) falham com LC_ALL=C: roda com locale UTF-8, 15 s no maximo, sem stdin
cli_run() {
    (
        l=${ORIG_LC_ALL:-$ORIG_LANG}
        case "$l" in *[Uu][Tt][Ff]*8*) ;; *) l=en_US.UTF-8 ;; esac
        export LANG=$l LC_ALL=$l
        timeout 15 "$@"
    ) 2>/dev/null </dev/null
}

detect_cli() {
    CLI_OK=""
    local cli ok
    for cli in oci aws az gcloud; do
        command -v "$cli" >/dev/null 2>&1 || continue
        ok=1
        case "$cli" in
            oci) cli_run oci os ns get >/dev/null || cli_run oci os ns get --auth instance_principal >/dev/null || ok=0 ;;
            aws) cli_run aws sts get-caller-identity >/dev/null || ok=0 ;;
            az) cli_run az account show >/dev/null || ok=0 ;;
            gcloud) [ -n "$(cli_run gcloud auth list --filter=status:ACTIVE --format='value(account)')" ] || ok=0 ;;
        esac
        if [ "$ok" = 1 ]; then CLI_OK="$CLI_OK $cli"; else aviso "cli $cli encontrada, sem autenticacao"; fi
    done
}

#------------------------------------------------------------------ helpers de /proc
pid_inodes() { ls -l "/proc/$1/fd" 2>/dev/null | sed -n 's/.*socket:\[\([0-9][0-9]*\)\].*/\1/p'; }
# sem CAP_SYS_PTRACE (ex.: container) o fd de outro usuario lista, mas o readlink falha
pid_le_fd() { local f; for f in /proc/$1/fd/*; do [ -L "$f" ] || continue; readlink "$f" >/dev/null 2>&1; return $?; done; return 1; }

pid_tcp_ports() { # portas TCP em LISTEN do pid (decimal, uma por linha)
    local ino uid=""
    if pid_le_fd "$1"; then ino=$(pid_inodes "$1" | tr '\n' ' '); [ -n "$ino" ] || return 0
    else uid=$(stat -c %u "/proc/$1" 2>/dev/null); [ -n "$uid" ] || return 0; fi   # alternativa: sockets do mesmo uid
    awk -v inos="$ino" -v uid="$uid" '
        function h2d(h,   i, n, c) { n = 0; h = toupper(h); for (i = 1; i <= length(h); i++) { c = index("0123456789ABCDEF", substr(h, i, 1)) - 1; n = n * 16 + c } return n }
        BEGIN { n = split(inos, a, " "); for (i = 1; i <= n; i++) S[a[i]] = 1 }
        FNR > 1 && $4 == "0A" && ((uid == "" && ($10 in S)) || (uid != "" && $8 == uid)) { split($2, p, ":"); print h2d(p[2]) }' /proc/net/tcp /proc/net/tcp6 2>/dev/null | sort -un
}

pid_unix_socks() { # sockets unix em LISTEN do pid ; $2 = regex do nome (usada so se o fd nao puder ser lido)
    local ino=""
    if pid_le_fd "$1"; then ino=$(pid_inodes "$1" | tr '\n' ' '); [ -n "$ino" ] || return 0; fi
    awk -v inos="$ino" -v rx="${2:-}" '
        BEGIN { n = split(inos, a, " "); for (i = 1; i <= n; i++) S[a[i]] = 1 }
        FNR > 1 && $6 == "01" && substr($8, 1, 1) == "/" && ((inos != "" && ($7 in S)) || (inos == "" && rx != "" && $8 ~ rx)) { print $8 }' /proc/net/unix 2>/dev/null
}

#------------------------------------------------------------------ descoberta
found() { local f="$W/found.dat" IFS='|'; printf '%s\n' "$*" >> "$f"; }   # motor|instancia|dono|a|b|c

oratab_home() {
    local f
    for f in /etc/oratab /var/opt/oracle/oratab; do
        [ -r "$f" ] && awk -F: -v s="$1" '$1 == s && $1 !~ /^#/ { print $2; exit }' "$f"
    done | head -n 1
}

found_oracle() {
    local pid=$1 sid=$2 owner oh exe
    case "$sid" in ""|*[!A-Za-z0-9_#$-]*) return ;; esac
    owner=$(stat -c %U "/proc/$pid" 2>/dev/null)
    oh=$({ tr '\0' '\n' < "/proc/$pid/environ"; } 2>/dev/null | sed -n 's/^ORACLE_HOME=//p' | head -n 1)
    if [ -z "$oh" ] || [ ! -d "$oh" ]; then
        exe=$(readlink "/proc/$pid/exe" 2>/dev/null); exe=${exe% (deleted)}
        case "$exe" in */bin/oracle*) oh=${exe%/bin/oracle*} ;; *) oh="" ;; esac
    fi
    [ -n "$oh" ] || oh=$(oratab_home "$sid")
    found oracle "$sid" "$owner" "$oh" "$pid" ""
}

found_mssql() {
    local pid=$1 owner ports port cli p
    ports=$(pid_tcp_ports "$pid")
    MSSQL_VISTO=1
    [ -n "$ports" ] || return 0
    port=$(printf '%s\n' "$ports" | head -n 1)
    printf '%s\n' "$ports" | grep -qx 1433 && port=1433
    owner=$(stat -c %U "/proc/$pid" 2>/dev/null)
    cli=""
    for p in /opt/mssql-tools18/bin/sqlcmd /opt/mssql-tools/bin/sqlcmd "$(command -v sqlcmd 2>/dev/null)"; do
        [ -n "$p" ] && [ -x "$p" ] && { cli=$p; break; }
    done
    grep -q "^sqlserver|$port|" "$W/found.dat" 2>/dev/null || found sqlserver "$port" "$owner" "$port" "$cli" "$pid"
    MSSQL_EMITIDO=1
}

found_mysql() {
    local pid=$1 owner sock port cli
    owner=$(stat -c %U "/proc/$pid" 2>/dev/null)
    sock=$(pid_unix_socks "$pid" 'mysql|maria' | head -n 1)
    port=$(pid_tcp_ports "$pid" | head -n 1)
    cli=$(command -v mariadb 2>/dev/null || command -v mysql 2>/dev/null)
    local inst=${port:-${sock##*/}}
    found mysql "${inst:-mysql}" "$owner" "$sock" "$port" "$cli"
}

found_pg() {
    local pid=$1 owner dd pf port sock bindir psql ports
    owner=$(stat -c %U "/proc/$pid" 2>/dev/null)
    dd=$(readlink "/proc/$pid/cwd" 2>/dev/null)
    pf="$dd/postmaster.pid"
    port=""; sock=""
    if [ -r "$pf" ]; then
        [ "$(sed -n 1p "$pf")" = "$pid" ] || return 0
        port=$(sed -n 4p "$pf"); sock=$(sed -n 5p "$pf")
        case "$sock" in /*) ;; *) sock="" ;; esac
    fi
    if [ -z "$port" ]; then port=$(pid_tcp_ports "$pid" | head -n 1); fi
    if [ -z "$sock" ]; then sock=$(pid_unix_socks "$pid" | head -n 1); sock=${sock%/*}; fi
    case "$PG_PORTS_VISTAS" in *" $port "*) return 0 ;; esac
    PG_PORTS_VISTAS="$PG_PORTS_VISTAS $port "
    bindir=$(readlink "/proc/$pid/exe" 2>/dev/null); bindir=${bindir% (deleted)}; bindir=${bindir%/*}
    psql=""
    [ -x "$bindir/psql" ] && psql="$bindir/psql"
    [ -n "$psql" ] || psql=$(command -v psql 2>/dev/null)
    ports=${port:-5432}
    found postgresql "$ports" "$owner" "$sock" "$psql" "$bindir"
}

found_mongo() {
    local pid=$1 owner port cli
    owner=$(stat -c %U "/proc/$pid" 2>/dev/null)
    port=$(pid_tcp_ports "$pid" | head -n 1)
    cli=$(command -v mongosh 2>/dev/null || command -v mongo 2>/dev/null)
    found mongodb "${port:-27017}" "$owner" "${port:-27017}" "$cli" ""
}

# banco rodando em container (outro namespace de rede): o wizard nao alcanca o socket/porta de fora
found_container() { # nome-do-processo pid ns
    local b=$1 ns=$3 motor inst=""
    case "$b" in
        ora_pmon_*|xe_pmon_*) motor=oracle; inst="container-${b#*_pmon_}" ;;
        sqlservr) motor=sqlserver ;;
        mysqld|mariadbd) motor=mysql ;;
        mongod) motor=mongodb ;;
        *) motor=postgresql ;;
    esac
    [ -n "$inst" ] || inst="container-${ns//[!0-9]/}"
    case "$CONT_VISTOS" in *" $motor|$inst "*) return ;; esac
    CONT_VISTOS="$CONT_VISTOS $motor|$inst "
    found "$motor" "$inst" "@container" "" "" ""
}

scan_processos() {
    local d pid a0 b ns selfns
    MSSQL_VISTO=0; MSSQL_EMITIDO=0; PG_PORTS_VISTAS=" "; CONT_VISTOS=" "
    selfns=$(readlink /proc/self/ns/net 2>/dev/null)
    for d in /proc/[0-9]*; do
        pid=${d#/proc/}
        a0=""
        { IFS= read -r -d '' a0 < "$d/cmdline"; } 2>/dev/null
        [ -n "$a0" ] || continue
        b=${a0##*/}
        case "$b" in
            ora_pmon_*|xe_pmon_*|sqlservr|mysqld|mariadbd|mongod) ;;
            postgres|postmaster) case "$a0" in *": "*) continue ;; esac ;;
            *) continue ;;
        esac
        ns=$(readlink "$d/ns/net" 2>/dev/null)
        if [ -n "$selfns" ] && [ -n "$ns" ] && [ "$ns" != "$selfns" ]; then found_container "$b" "$pid" "$ns"; continue; fi
        case "$b" in
            ora_pmon_*|xe_pmon_*) found_oracle "$pid" "${b#*_pmon_}" ;;
            sqlservr) found_mssql "$pid" ;;
            mysqld|mariadbd) found_mysql "$pid" ;;
            postgres|postmaster) case "$a0" in *": "*) ;; *) found_pg "$pid" ;; esac ;;
            mongod) found_mongo "$pid" ;;
        esac
    done
    if [ "$MSSQL_VISTO" = 1 ] && [ "$MSSQL_EMITIDO" = 0 ]; then
        local cli="" p
        for p in /opt/mssql-tools18/bin/sqlcmd /opt/mssql-tools/bin/sqlcmd "$(command -v sqlcmd 2>/dev/null)"; do
            [ -n "$p" ] && [ -x "$p" ] && { cli=$p; break; }
        done
        found sqlserver 1433 mssql 1433 "$cli" ""
    fi
    # Oracle listado no oratab sem pmon (instancia parada)
    local f s
    for f in /etc/oratab /var/opt/oracle/oratab; do
        [ -r "$f" ] || continue
        for s in $(awk -F: '$1 !~ /^#/ && $1 != "" && $1 !~ /^\+/ && NF >= 2 { print $1 }' "$f"); do
            grep -q "^oracle|$s|" "$W/found.dat" 2>/dev/null || found oracle "$s" "-" "$(oratab_home "$s")" "" ""
        done
    done
}

#------------------------------------------------------------------ erros comuns
classifica_erro() { # $1 = saida do cliente -> ACESSO e DETALHE
    local t=$1 linha
    linha=$(printf '%s\n' "$t" | grep -E 'ORA-[0-9]+|SP2-[0-9]+' | head -n 1)
    [ -n "$linha" ] || linha=$(printf '%s\n' "$t" | grep -E 'FATAL|ERROR [0-9]|Error|error|denied|Unauthorized|authentication|Login failed|Cannot|cannot|could not|Can.t connect' | head -n 1)
    [ -n "$linha" ] || linha=$(printf '%s\n' "$t" | head -n 1)
    DETALHE=$(clean "$linha" 140)
    DETALHE=${DETALHE//username\/password/credencial}
    if printf '%s' "$t" | grep -Eiq 'ORA-01017|ORA-01031|ORA-12641|Access denied|Peer authentication failed|password authentication failed|no password supplied|password.*required|Login failed|Unauthorized|requires authentication|Authentication failed|not authorized|role .* does not exist|permission denied|pg_hba|requer root'; then
        ACESSO="sem_credencial"
    else
        ACESSO="erro"
    fi
}

#------------------------------------------------------------------ ORACLE
ORA_SID=""; ORA_OH=""; ORA_OWNER=""; ORA_DB=""; ORA_MODO=""

ora_sql() { # $1 = SQL ; saida e stderr no stdout ; rc do sqlplus
    printf '%s\n' \
        "SET ECHO OFF FEEDBACK OFF HEADING OFF PAGESIZE 0 LINESIZE 2000 TRIMSPOOL ON TAB OFF VERIFY OFF DEFINE OFF SERVEROUTPUT OFF" \
        "SET SQLBLANKLINES ON" \
        "WHENEVER SQLERROR EXIT FAILURE" \
        "WHENEVER OSERROR EXIT FAILURE" \
        "$1" "EXIT" |
    as_user "$ORA_OWNER" env "ORACLE_HOME=$ORA_OH" "ORACLE_SID=$ORA_SID" \
        "LD_LIBRARY_PATH=$ORA_OH/lib${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}" "PATH=$ORA_OH/bin:$PATH" \
        "NLS_LANG=AMERICAN_AMERICA.AL32UTF8" \
        "$ORA_OH/bin/sqlplus" -s -L "/ as sysdba" 2>&1
}

probe_oracle() {
    ORA_SID=$INST; ORA_OWNER=$OWNER; ORA_OH=$FA; ORA_DB=""; ORA_MODO=""
    if [ -z "$OWNER" ] || [ "$OWNER" = "-" ]; then ACESSO="erro"; DETALHE="instancia parada (listada no oratab, sem processo pmon)"; return; fi
    if [ -z "$ORA_OH" ] || [ ! -x "$ORA_OH/bin/sqlplus" ]; then
        ACESSO="sem_cliente"; DETALHE="sqlplus nao encontrado (ORACLE_HOME=${ORA_OH:-desconhecido})"; return
    fi
    local out rc sql
    sql="SELECT 'INFO;VERSAO;' || version FROM v\$instance;
SELECT 'INFO;DBNAME;' || name FROM v\$database;
SELECT 'INFO;MODO;' || CASE WHEN COUNT(*) > 0 THEN 'cdb' ELSE 'nocdb' END FROM v\$parameter WHERE name = 'enable_pluggable_database' AND UPPER(value) = 'TRUE';
SELECT 'INFO;ESTADO;' || status FROM v\$instance;"
    out=$(ora_sql "$sql"); rc=$?
    VERSAO=$(printf '%s\n' "$out" | sed -n 's/^INFO;VERSAO;//p' | head -n 1 | tr -cd 'A-Za-z0-9._-')
    if [ $rc -eq 0 ] && [ -n "$VERSAO" ]; then
        ACESSO="ok"; DETALHE=""
        ORA_DB=$(printf '%s\n' "$out" | sed -n 's/^INFO;DBNAME;//p' | head -n 1 | tr -cd 'A-Za-z0-9_.$#@-')
        ORA_MODO=$(printf '%s\n' "$out" | sed -n 's/^INFO;MODO;//p' | head -n 1 | tr -cd 'a-z')
        [ -n "$ORA_MODO" ] || ORA_MODO="nocdb"
        [ -n "$ORA_DB" ] || ORA_DB=$ORA_SID
        return
    fi
    VERSAO=""
    if [ $rc -eq 124 ]; then ACESSO="erro"; DETALHE="timeout (${TMO}s)"; return; fi
    classifica_erro "$out"
    if [ "$ACESSO" = "sem_credencial" ] && [ $rc -ne 126 ]; then DETALHE="usuario $OWNER sem acesso '/ as sysdba' (grupo dba?): $DETALHE"; DETALHE=$(clean "$DETALHE" 160); fi
}

cresc_oracle() {
    local out rc sql agora tag db pdb comp bytes npdb=0
    agora=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    if [ "$ORA_MODO" = "cdb" ]; then
        sql="SELECT 'AVISO;PDB_FECHADO;' || name || ';' || open_mode FROM v\$pdbs WHERE con_id > 2 AND open_mode NOT IN ('READ WRITE', 'READ ONLY');
SELECT 'TOT;' || d.name || ';' || c.name || ';;' || TO_CHAR(SUM(f.bytes), 'FM999999999999999999990') FROM cdb_data_files f JOIN v\$containers c ON c.con_id = f.con_id CROSS JOIN v\$database d WHERE c.con_id > 2 GROUP BY d.name, c.name ORDER BY c.name;
SELECT 'TBS;' || d.name || ';' || c.name || ';' || f.tablespace_name || ';' || TO_CHAR(SUM(f.bytes), 'FM999999999999999999990') FROM cdb_data_files f JOIN v\$containers c ON c.con_id = f.con_id CROSS JOIN v\$database d WHERE c.con_id > 2 GROUP BY d.name, c.name, f.tablespace_name ORDER BY c.name, f.tablespace_name;"
    else
        sql="SELECT 'TOT;' || d.name || ';;;' || TO_CHAR(SUM(f.bytes), 'FM999999999999999999990') FROM dba_data_files f CROSS JOIN v\$database d GROUP BY d.name;
SELECT 'TBS;' || d.name || ';;' || f.tablespace_name || ';' || TO_CHAR(SUM(f.bytes), 'FM999999999999999999990') FROM dba_data_files f CROSS JOIN v\$database d GROUP BY d.name, f.tablespace_name ORDER BY f.tablespace_name;"
    fi
    out=$(ora_sql "$sql"); rc=$?
    if [ $rc -ne 0 ]; then
        classifica_erro "$out"
        aviso "oracle $ORA_SID: crescimento nao coletado ($DETALHE)"; return 1
    fi
    while IFS=';' read -r tag db pdb comp bytes; do
        case "$tag" in
            TOT) emit cresc.tsv oracle "$ORA_SID" "$db" "$pdb" total "$db" "$bytes" "$agora"; npdb=$((npdb + 1)) ;;
            TBS) emit cresc.tsv oracle "$ORA_SID" "$db" "$pdb" tablespace "$comp" "$bytes" "$agora" ;;
            AVISO) aviso "oracle $ORA_SID: PDB $pdb em modo $comp (sem dados nesta coleta)" ;;
        esac
    done < <(printf '%s\n' "$out" | grep -E '^(TOT|TBS|AVISO);' | sed 's/[[:space:]]*$//')
    [ "$npdb" -gt 0 ] || aviso "oracle $ORA_SID: nenhum datafile encontrado (CDB sem PDBs de usuario abertos?)"
    return 0
}

bk_oracle_rman() {
    local sql out rc linha tag tipo ini fim bytes status dev n=0
    local nivel="LEFT JOIN (SELECT session_key, session_stamp, MIN(incremental_level) nivel_min FROM v\$backup_set_details GROUP BY session_key, session_stamp) d ON d.session_key = j.session_key AND d.session_stamp = j.session_stamp"
    local tipo_sql="CASE WHEN j.input_type LIKE '%FULL' THEN 'FULL' WHEN j.input_type LIKE '%INCR' AND d.nivel_min = 0 THEN 'FULL' ELSE 'INCREMENTAL' END"
    montar() { # $1 = trecho do nivel ; $2 = expressao do tipo
        printf '%s\n' "SELECT 'RMAN;' || $2
 || ';' || TO_CHAR(j.start_time, 'YYYY-MM-DD HH24:MI:SS')
 || ';' || CASE WHEN j.end_time IS NULL THEN '' ELSE TO_CHAR(j.end_time, 'YYYY-MM-DD HH24:MI:SS') END
 || ';' || TO_CHAR(NVL(j.output_bytes, 0), 'FM999999999999999999990')
 || ';' || CASE j.status WHEN 'COMPLETED' THEN 'SUCESSO' WHEN 'COMPLETED WITH WARNINGS' THEN 'WARNING' ELSE 'FALHA' END
 || ';' || x.dev
FROM v\$rman_backup_job_details j
 CROSS JOIN (SELECT 'DISK' dev FROM dual UNION ALL SELECT 'SBT_TAPE' FROM dual) x
 $1
WHERE j.start_time >= TRUNC(SYSDATE) - $JANELA_DIAS
AND j.input_type IN ('DB FULL', 'DB INCR', 'DATAFILE FULL', 'DATAFILE INCR')
AND j.status NOT LIKE 'RUNNING%'
AND INSTR(NVL(j.output_device_type, 'DISK'), x.dev) > 0
ORDER BY j.start_time, x.dev;"
    }
    sql=$(montar "$nivel" "$tipo_sql")
    out=$(ora_sql "$sql"); rc=$?
    if [ $rc -ne 0 ] && printf '%s' "$out" | grep -Eq 'ORA-00942|ORA-00904'; then
        aviso "oracle $ORA_SID: v\$backup_set_details indisponivel; Level 0 aparecera como INCREMENTAL"
        sql=$(montar "" "CASE WHEN j.input_type LIKE '%FULL' THEN 'FULL' ELSE 'INCREMENTAL' END")
        out=$(ora_sql "$sql"); rc=$?
    fi
    if [ $rc -ne 0 ]; then
        classifica_erro "$out"
        aviso "oracle $ORA_SID: RMAN nao coletado ($DETALHE)"; return 1
    fi
    while IFS=';' read -r tag tipo ini fim bytes status dev; do
        [ "$tag" = RMAN ] || continue
        emit bk.tsv oracle "$ORA_SID" "$ORA_DB" rman "$tipo" "$dev" "$ini" "$fim" "$status" "$bytes" ""
        n=$((n + 1))
    done < <(printf '%s\n' "$out" | grep '^RMAN;' | sed 's/[[:space:]]*$//')
    [ "$n" -gt 0 ] || aviso "oracle $ORA_SID: nenhum job RMAN de banco na janela de ${JANELA_DIAS} dias"
    return 0
}

gravar_awk_expdp() {
    cat > "$W/expdp_log.awk" <<'AWK_EXPDP'
# Le UM log do Data Pump (expdp) e imprime UMA linha TSV:
#   OK <S|W|F|I> <DATAINI dd-mm-aaaa> <HORAINI> <DATAFIM> <HORAFIM> <TIPO> <OBJETOS> <SOMA_BYTES> <N_ERROS> [arquivo_dmp ...]
#   IGNORAR <motivo>
function parse_data(txt,    n, a, mm, dd, yy, hh) {
    n = split(txt, a, " ")
    if (n < 5) return ""
    mm = (tolower(substr(a[2], 1, 3)) in MES) ? MES[tolower(substr(a[2], 1, 3))] : 0
    dd = a[3] + 0
    yy = a[5] + 0
    hh = a[4]
    if (mm == 0 || dd < 1 || dd > 31 || yy < 1990 || hh !~ /^[0-9][0-9]:[0-9][0-9]:[0-9][0-9]$/) return ""
    return sprintf("%02d-%02d-%04d %s", dd, mm, yy, hh)
}
BEGIN {
    split("jan:1 feb:2 fev:2 mar:3 apr:4 abr:4 may:5 mai:5 jun:6 jul:7 aug:8 ago:8 sep:9 set:9 oct:10 out:10 nov:11 dec:12 dez:12", par, " ")
    for (i in par) { split(par[i], kv, ":"); MES[kv[1]] = kv[2] + 0 }
    UN["bytes"] = 1; UN["KB"] = 1024; UN["MB"] = 1048576; UN["GB"] = 1073741824; UN["TB"] = 1099511627776
    cab = 0; starting = 0; modo = ""; job = ""; obj = 0; soma = 0; nf = 0; emset = 0
    fin = ""; nerr = 0; ini = ""; fim = ""; baddate = 0
}
{
    l = $0
    gsub(/\r/, "", l)
    sub(/^[0-9][0-9]-[A-Za-z][A-Za-z][A-Za-z]-[0-9][0-9]*[ ]+[0-9:.]+: /, "", l)
    if (emset) {
        if (l ~ /^[ \t]+[^ \t]/) {
            t = l; sub(/^[ \t]+/, "", t); sub(/[ \t]+$/, "", t)
            nf++; arq[nf] = t
            next
        }
        emset = 0
    }
    if (!cab && l ~ /^Export: Release [0-9.]+ - .* on /) {
        p = l; sub(/^.* on /, "", p)
        ini = parse_data(p)
        if (ini == "") baddate = 1
        cab = 1
        next
    }
    if (!starting && l ~ /^Starting "[^"]*"\."[^"]*":/) {
        starting = 1
        split(l, q, "\"")
        job = q[4]
        next
    }
    if (modo == "" && l ~ /^Processing object type [A-Z_]+_EXPORT\//) {
        t = l; sub(/^Processing object type /, "", t); sub(/_EXPORT\/.*/, "", t)
        modo = t
        next
    }
    if (l ~ /^\. \. exported "/) {
        obj++
        n = split(l, f, " ")
        if (n >= 4 && f[n] == "rows") {
            u = f[n - 2]; v = f[n - 3]; gsub(/,/, ".", v)
            if (v ~ /^[0-9]+(\.[0-9]+)?$/ && (u in UN)) soma += v * UN[u]
        }
        next
    }
    if (l ~ /^Dump file set for .* is:[ \t]*$/) { emset = 1; next }
    if (l ~ /^Job "[^"]*"\."[^"]*" /) {
        p = ""
        if (l ~ / successfully completed at /) {
            fin = "S"; nerr = 0
            p = l; sub(/^.* completed at /, "", p)
        } else if (l ~ / completed with [0-9]+ error\(s\) at /) {
            fin = "W"
            match(l, /completed with [0-9]+ error/)
            e = substr(l, RSTART, RLENGTH); gsub(/[^0-9]/, "", e); nerr = e + 0
            p = l; sub(/^.* error\(s\) at /, "", p)
        } else if (l ~ / stopped due to fatal error at /) {
            fin = "F"
            p = l; sub(/^.* fatal error at /, "", p)
        } else {
            next
        }
        fim = parse_data(p)
        next
    }
}
END {
    if (!cab || !starting) { print "IGNORAR\tnao_expdp"; exit }
    if (baddate) { print "IGNORAR\tdata_invalida"; exit }
    tipo = ""
    if (modo == "DATABASE") tipo = "FULL"
    else if (modo == "SCHEMA") tipo = "SCHEMA"
    else if (modo == "TABLE") tipo = "TABLE"
    else if (modo == "TABLESPACE") tipo = "TABLESPACE"
    else if (modo == "TRANSPORTABLE") tipo = "TRANSPORTABLE"
    else if (job ~ /^SYS_EXPORT_FULL_[0-9]+$/) tipo = "FULL"
    else if (job ~ /^SYS_EXPORT_SCHEMA_[0-9]+$/) tipo = "SCHEMA"
    else if (job ~ /^SYS_EXPORT_TABLE_[0-9]+$/) tipo = "TABLE"
    else if (job ~ /^SYS_EXPORT_TABLESPACE_[0-9]+$/) tipo = "TABLESPACE"
    else if (job ~ /^SYS_EXPORT_TRANSPORTABLE_[0-9]+$/) tipo = "TRANSPORTABLE"
    if (tipo == "") { print "IGNORAR\ttipo_indeterminado"; exit }
    if (fin == "" || fim == "") { st = (fin == "F") ? "F" : "I"; fim = "" } else st = fin
    if (fim == "") { dfim = "-"; hfim = "-" } else { split(fim, ff, " "); dfim = ff[1]; hfim = ff[2] }
    split(ini, ii, " ")
    printf "OK\t%s\t%s\t%s\t%s\t%s\t%s\t%d\t%.0f\t%d", st, ii[1], ii[2], dfim, hfim, tipo, obj, soma, nerr
    for (k = 1; k <= nf; k++) printf "\t%s", arq[k]
    printf "\n"
}
AWK_EXPDP
}

br_para_iso() { printf '%s-%s-%s %s' "${1:6:4}" "${1:3:2}" "${1:0:2}" "$2"; }

bk_oracle_expdp() {
    local sql out rc dirs d f d2 now linha tag st dini hini dfim hfim tipo obj soma nerr resto status
    local mt ini_e fim_e ini_iso fim_iso tam achou nfil a b sz arr
    local n_lidos=0 n_ok=0 n_ign=0 n_inc=0 n_andamento=0 n_aprox=0 n_ilegivel=0 lista_ign="" n_nomes=0
    if [ "$ORA_MODO" = "cdb" ]; then sql="SELECT 'DIR;' || directory_path FROM cdb_directories;"
    else sql="SELECT 'DIR;' || directory_path FROM dba_directories;"; fi
    out=$(ora_sql "$sql"); rc=$?
    if [ $rc -ne 0 ] && [ "$ORA_MODO" = "cdb" ]; then
        out=$(ora_sql "SELECT 'DIR;' || directory_path FROM dba_directories;"); rc=$?
    fi
    if [ $rc -ne 0 ]; then
        classifica_erro "$out"
        aviso "oracle $ORA_SID: diretorios do expdp nao consultados ($DETALHE)"; return 1
    fi
    dirs=$(printf '%s\n' "$out" | sed -n 's/^DIR;//p' | sed -e 's/[[:space:]]*$//' -e 's#/*$##' | sort -u)
    now=$(date +%s)
    while IFS= read -r d <&4; do
        [ -n "$d" ] || continue
        [ -d "$d" ] && [ -r "$d" ] || continue
        case "$d" in "$ORA_OH"|"$ORA_OH"/*) continue ;; esac
        while IFS= read -r -d '' f; do
            n_lidos=$((n_lidos + 1))
            if [ ! -r "$f" ]; then
                n_ilegivel=$((n_ilegivel + 1)); continue
            fi
            linha=$(awk -f "$W/expdp_log.awk" "$f")
            IFS="$TAB" read -r tag st dini hini dfim hfim tipo obj soma nerr resto <<<"$linha"
            if [ "$tag" != "OK" ]; then
                n_ign=$((n_ign + 1))
                [ "$n_nomes" -ge 5 ] || { lista_ign="$lista_ign ${f##*/}($st)"; n_nomes=$((n_nomes + 1)); }
                continue
            fi
            mt=$(stat -c %Y "$f")
            case "$st" in
                S) status="SUCESSO" ;;
                W) status="WARNING" ;;
                F) status="FALHA" ;;
                *) if [ $((now - mt)) -lt $((INATIVO_MIN * 60)) ]; then n_andamento=$((n_andamento + 1)); continue; fi
                   status="FALHA"; n_inc=$((n_inc + 1)) ;;
            esac
            ini_iso=$(br_para_iso "$dini" "$hini")
            ini_e=$(date -d "$ini_iso" +%s 2>/dev/null) || ini_e=0
            if [ "$dfim" = "-" ]; then
                [ "$mt" -ge "$ini_e" ] || mt=$ini_e
                fim_iso=$(date -d "@$mt" '+%Y-%m-%d %H:%M:%S')
            else
                fim_iso=$(br_para_iso "$dfim" "$hfim")
            fi
            fim_e=$(date -d "$fim_iso" +%s 2>/dev/null) || fim_e=0
            if [ "$fim_e" -lt "$ini_e" ]; then
                n_ign=$((n_ign + 1)); [ "$n_nomes" -ge 5 ] || { lista_ign="$lista_ign ${f##*/}(fim_antes_do_inicio)"; n_nomes=$((n_nomes + 1)); }
                continue
            fi
            tam=0; achou=1; nfil=0
            arr=()
            IFS="$TAB" read -r -a arr <<<"$resto"
            for a in "${arr[@]}"; do
                [ -n "$a" ] || continue
                nfil=$((nfil + 1)); b=""
                if [ -f "$a" ]; then b="$a"
                else
                    for d2 in "$d" $dirs; do [ -f "$d2/${a##*/}" ] && { b="$d2/${a##*/}"; break; }; done
                fi
                if [ -n "$b" ]; then sz=$(stat -c %s "$b"); tam=$((tam + sz)); else achou=0; fi
            done
            if [ "$nfil" -eq 0 ] || [ "$achou" -eq 0 ]; then
                [ "$status" = "FALHA" ] || n_aprox=$((n_aprox + 1))
                tam=$soma
            fi
            case "$tipo" in FULL) tipo="LOGICO_FULL" ;; *) tipo="LOGICO_SCHEMA" ;; esac
            emit bk.tsv oracle "$ORA_SID" "$ORA_DB" expdp "$tipo" DISK "$ini_iso" "$fim_iso" "$status" "$tam" "$obj"
            n_ok=$((n_ok + 1))
        done < <(find "$d" -maxdepth 1 -type f -name '*.log' -mtime -"$((JANELA_DIAS + 1))" -print0 2>/dev/null | sort -z)
    done 4<<<"$dirs"
    log INFO "oracle $ORA_SID expdp: $n_lidos log(s) lidos, $n_ok incluido(s) (incompletos parados: $n_inc; em andamento ignorados: $n_andamento)"
    [ "$n_ign" -eq 0 ] || aviso "oracle $ORA_SID: $n_ign log(s) .log fora do padrao expdp ignorados (ex.:$lista_ign)"
    [ "$n_ilegivel" -eq 0 ] || aviso "oracle $ORA_SID: $n_ilegivel log(s) ilegiveis"
    [ "$n_aprox" -eq 0 ] || aviso "oracle $ORA_SID: $n_aprox registro(s) expdp com tamanho aproximado (dumpfile nao encontrado)"
    return 0
}

#------------------------------------------------------------------ SQL SERVER
MS_PORT=""; MS_CLI=""; MS_SQLDBS=""

ms_sql() { # $1 = T-SQL (lote(s) com GO)
    local -a a=("$MS_CLI" -S "127.0.0.1,$MS_PORT" -C -l 15 -t 60 -W -h -1 -s '|')
    local envs=()
    if [ -n "${WISEDB_MSSQL_USER:-}" ]; then a+=(-U "$WISEDB_MSSQL_USER"); envs=("SQLCMDPASSWORD=${WISEDB_MSSQL_PASS:-}"); else a+=(-E); fi
    printf '%s\n' "SET NOCOUNT ON;" "$1" | tmo env ${envs[@]+"${envs[@]}"} "${a[@]}" 2>&1
}

probe_sqlserver() {
    MS_PORT=$FA; MS_CLI=$FB
    if [ -z "$MS_CLI" ]; then ACESSO="sem_cliente"; DETALHE="sqlcmd nao encontrado (/opt/mssql-tools*/bin)"; return; fi
    if [ -z "${WISEDB_MSSQL_USER:-}" ]; then
        ACESSO="sem_credencial"; DETALHE="defina WISEDB_MSSQL_USER e WISEDB_MSSQL_PASS (autenticacao do Windows nao existe no Linux)"; return
    fi
    local out rc
    out=$(ms_sql "SELECT 'VER|' + CAST(SERVERPROPERTY('ProductVersion') AS varchar(50));
SELECT 'DB|' + d.name COLLATE DATABASE_DEFAULT + '|' + d.state_desc COLLATE DATABASE_DEFAULT FROM sys.databases d WHERE d.database_id <> 2;
GO"); rc=$?
    VERSAO=$(printf '%s\n' "$out" | sed -n 's/^VER|//p' | head -n 1 | tr -cd 'A-Za-z0-9._-')
    if [ $rc -eq 0 ] && [ -n "$VERSAO" ]; then
        ACESSO="ok"; DETALHE=""; MS_SQLDBS=$(printf '%s\n' "$out" | sed -n 's/^DB|//p'); return
    fi
    VERSAO=""
    if [ $rc -eq 124 ]; then ACESSO="erro"; DETALHE="timeout (${TMO}s)"; return; fi
    classifica_erro "$out"
}

cresc_sqlserver() {
    local agora out rc lote="" nome estado tag db fg bytes
    agora=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    out=$(ms_sql "SELECT 'TOT|' + d.name + '|' + CAST(SUM(CAST(f.size AS bigint)) * 8192 AS varchar(30)) FROM sys.master_files f JOIN sys.databases d ON d.database_id = f.database_id WHERE f.type = 0 AND d.database_id <> 2 GROUP BY d.name;
GO"); rc=$?
    if [ $rc -ne 0 ]; then classifica_erro "$out"; aviso "sqlserver $MS_PORT: crescimento nao coletado ($DETALHE)"; return 1; fi
    while IFS='|' read -r tag db bytes; do
        [ "$tag" = TOT ] && emit cresc.tsv sqlserver "$MS_PORT" "$db" "" total "$db" "$bytes" "$agora"
    done < <(printf '%s\n' "$out" | grep '^TOT|')
    # filegroups: um lote USE por banco online
    while IFS='|' read -r nome estado; do
        [ -n "$nome" ] || continue
        if [ "$estado" != "ONLINE" ]; then aviso "sqlserver $MS_PORT: banco $nome em $estado (filegroups nao coletados)"; continue; fi
        nome=${nome//]/]]}
        lote="$lote
USE [$nome];
SELECT 'FG|' + DB_NAME() + '|' + ISNULL(ds.name, '') + '|' + CAST(SUM(CAST(df.size AS bigint)) * 8192 AS varchar(30)) FROM sys.database_files df LEFT JOIN sys.data_spaces ds ON ds.data_space_id = df.data_space_id WHERE df.type IN (0, 2) GROUP BY ds.name;
GO"
    done <<<"$MS_SQLDBS"
    if [ -n "$lote" ]; then
        out=$(ms_sql "$lote")
        while IFS='|' read -r tag db fg bytes; do
            [ "$tag" = FG ] && [ -n "$fg" ] && emit cresc.tsv sqlserver "$MS_PORT" "$db" "" filegroup "$fg" "$bytes" "$agora"
        done < <(printf '%s\n' "$out" | grep '^FG|')
    fi
    return 0
}

bk_sqlserver() {
    local out rc tag db tp ini fim bytes status dev tipo n=0
    out=$(ms_sql "SELECT 'BK|' + b.database_name + '|' + b.type + '|' + CONVERT(varchar(19), b.backup_start_date, 120) + '|' + ISNULL(CONVERT(varchar(19), b.backup_finish_date, 120), '') + '|' + CAST(CAST(ISNULL(b.compressed_backup_size, b.backup_size) AS bigint) AS varchar(30)) + '|' + CASE WHEN b.is_damaged = 1 THEN 'FALHA' WHEN b.has_incomplete_metadata = 1 THEN 'WARNING' ELSE 'SUCESSO' END + '|' + CASE WHEN m.device_type IN (2, 102) THEN 'DISK' WHEN m.device_type IN (5, 7) THEN 'SBT_TAPE' WHEN m.device_type = 9 AND m.physical_device_name LIKE '%objectstorage%' THEN 'OCI' WHEN m.device_type = 9 THEN 'URL' ELSE '' END
FROM msdb.dbo.backupset b OUTER APPLY (SELECT TOP 1 mf.device_type, mf.physical_device_name FROM msdb.dbo.backupmediafamily mf WHERE mf.media_set_id = b.media_set_id ORDER BY mf.family_sequence_number) m
WHERE b.type IN ('D', 'I', 'L') AND b.backup_start_date >= DATEADD(DAY, -$JANELA_DIAS, GETDATE()) ORDER BY b.backup_start_date;
GO"); rc=$?
    if [ $rc -ne 0 ]; then classifica_erro "$out"; aviso "sqlserver $MS_PORT: msdb nao coletado ($DETALHE)"; return 1; fi
    while IFS='|' read -r tag db tp ini fim bytes status dev; do
        case "$tp" in D) tipo=FULL ;; I) tipo=DIFERENCIAL ;; L) tipo=LOG ;; *) continue ;; esac
        emit bk.tsv sqlserver "$MS_PORT" "$db" msdb "$tipo" "$dev" "$ini" "$fim" "$status" "$bytes" ""
        n=$((n + 1))
    done < <(printf '%s\n' "$out" | grep '^BK|' | sed 's/[[:space:]]*$//')
    [ "$n" -gt 0 ] || aviso "sqlserver $MS_PORT: nenhum backup no msdb na janela de ${JANELA_DIAS} dias"
    return 0
}

#------------------------------------------------------------------ MYSQL / MARIADB
MY_SOCK=""; MY_PORT=""; MY_CLI=""; MY_EXTRA=""; MY_BASE="mysql"

my_sql() { # $1 = SQL ; saida TSV (-N -B)
    local -a a=("$MY_CLI")
    [ -z "$MY_EXTRA" ] || a+=("--defaults-extra-file=$MY_EXTRA")
    a+=(-N -B --connect-timeout=10 --default-character-set=utf8mb4)
    if [ -n "$MY_SOCK" ]; then a+=(-S "$MY_SOCK"); elif [ -n "$MY_PORT" ]; then a+=(-h 127.0.0.1 -P "$MY_PORT" --protocol=TCP); fi
    printf '%s\n' "$1" | tmo "${a[@]}" 2>&1
}

probe_mysql() {
    MY_SOCK=$FA; MY_PORT=$FB; MY_CLI=$FC; MY_EXTRA=""; MY_BASE="mysql"
    if [ -z "$MY_CLI" ]; then ACESSO="sem_cliente"; DETALHE="cliente mysql/mariadb nao encontrado"; return; fi
    local out rc ver
    out=$(my_sql "SELECT VERSION(), @@version_comment;"); rc=$?
    if [ $rc -ne 0 ] && [ -r /etc/mysql/debian.cnf ]; then
        MY_EXTRA=/etc/mysql/debian.cnf
        out=$(my_sql "SELECT VERSION(), @@version_comment;"); rc=$?
        [ $rc -eq 0 ] || MY_EXTRA=""
    fi
    if [ $rc -eq 0 ]; then
        ver=$(printf '%s\n' "$out" | head -n 1)
        VERSAO=$(printf '%s' "${ver%%$TAB*}" | tr -cd 'A-Za-z0-9._+-')
        if [ -n "$VERSAO" ]; then
            ACESSO="ok"; DETALHE=""
            case "$ver" in *[Mm]aria*) MY_BASE="mariadb" ;; esac
            return
        fi
    fi
    VERSAO=""
    if [ $rc -eq 124 ]; then ACESSO="erro"; DETALHE="timeout (${TMO}s)"; return; fi
    classifica_erro "$out"
    [ "$ACESSO" != "sem_credencial" ] || DETALHE="root via socket/.my.cnf recusado: $DETALHE"
    DETALHE=$(clean "$DETALHE" 160)
}

cresc_mysql() {
    local agora out rc sch bytes total=0 n=0
    agora=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    out=$(my_sql "SELECT s.schema_name, CAST(COALESCE(SUM(t.data_length + t.index_length), 0) AS UNSIGNED) FROM information_schema.schemata s LEFT JOIN information_schema.tables t ON t.table_schema = s.schema_name WHERE s.schema_name NOT IN ('information_schema', 'performance_schema', 'sys', 'mysql') GROUP BY s.schema_name ORDER BY s.schema_name;"); rc=$?
    if [ $rc -ne 0 ]; then classifica_erro "$out"; aviso "mysql $INST: crescimento nao coletado ($DETALHE)"; return 1; fi
    while IFS="$TAB" read -r sch bytes; do
        case "$bytes" in ""|*[!0-9]*) continue ;; esac
        emit cresc.tsv mysql "$INST" "$MY_BASE" "" schema "$sch" "$bytes" "$agora"
        total=$((total + bytes)); n=$((n + 1))
    done <<<"$out"
    emit cresc.tsv mysql "$INST" "$MY_BASE" "" total "$MY_BASE" "$total" "$agora"
    return 0
}

#------------------------------------------------------------------ POSTGRESQL
PG_PORT=""; PG_SOCK=""; PG_PSQL=""; PG_OWNER=""

pg_sql() { # $1 = banco ; $2 = SQL
    local -a a=("$PG_PSQL" -X -A -t -q -F "$TAB" -v ON_ERROR_STOP=1 -w -p "$PG_PORT" -d "$1" -f -)
    [ -z "$PG_SOCK" ] || a+=(-h "$PG_SOCK")
    printf '%s\n' "$2" | as_user "$PG_OWNER" env PGCONNECT_TIMEOUT=10 PGCLIENTENCODING=UTF8 \
        "PGOPTIONS=-c statement_timeout=60000 -c default_transaction_read_only=on" "${a[@]}" 2>&1
}

probe_postgresql() {
    PG_PORT=$INST; PG_SOCK=$FA; PG_PSQL=$FB; PG_OWNER=$OWNER
    if [ -z "$PG_PSQL" ]; then ACESSO="sem_cliente"; DETALHE="psql nao encontrado"; return; fi
    local out rc
    out=$(pg_sql postgres "SELECT current_setting('server_version');"); rc=$?
    if [ $rc -eq 0 ]; then
        VERSAO=$(printf '%s\n' "$out" | head -n 1 | tr -cd 'A-Za-z0-9._ ()-' | cut -c1-40)
        if [ -n "$VERSAO" ]; then ACESSO="ok"; DETALHE=""; return; fi
    fi
    VERSAO=""
    if [ $rc -eq 124 ]; then ACESSO="erro"; DETALHE="timeout (${TMO}s)"; return; fi
    classifica_erro "$out"
}

cresc_postgresql() {
    local agora out rc db bytes schs sch sb nbase=0
    agora=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    out=$(pg_sql postgres "SELECT datname, pg_database_size(datname) FROM pg_database WHERE NOT datistemplate AND datallowconn ORDER BY 1;"); rc=$?
    if [ $rc -ne 0 ]; then classifica_erro "$out"; aviso "postgresql $INST: crescimento nao coletado ($DETALHE)"; return 1; fi
    while IFS="$TAB" read -r db bytes; do
        case "$bytes" in ""|*[!0-9]*) continue ;; esac
        emit cresc.tsv postgresql "$INST" "$db" "" total "$db" "$bytes" "$agora"
        nbase=$((nbase + 1))
        schs=$(pg_sql "$db" "SELECT n.nspname, COALESCE(SUM(pg_total_relation_size(c.oid)), 0)::bigint FROM pg_namespace n LEFT JOIN pg_class c ON c.relnamespace = n.oid AND c.relkind IN ('r', 'm') WHERE n.nspname NOT LIKE 'pg\\_%' AND n.nspname <> 'information_schema' GROUP BY n.nspname ORDER BY n.nspname;"); rc=$?
        if [ $rc -ne 0 ]; then classifica_erro "$schs"; aviso "postgresql $INST: schemas de $db nao coletados ($DETALHE)"; continue; fi
        while IFS="$TAB" read -r sch sb; do
            case "$sb" in ""|*[!0-9]*) continue ;; esac
            emit cresc.tsv postgresql "$INST" "$db" "" schema "$sch" "$sb" "$agora"
        done <<<"$schs"
    done <<<"$out"
    return 0
}

PY_PGBACKREST='
import sys, json, time, datetime
dias = int(sys.argv[1])
try:
    dados = json.load(sys.stdin)
except Exception:
    sys.exit(2)
lim = time.time() - dias * 86400
tm = {"full": "FULL", "diff": "DIFERENCIAL", "incr": "INCREMENTAL"}
f = lambda e: datetime.datetime.utcfromtimestamp(e).strftime("%Y-%m-%dT%H:%M:%SZ")
for st in dados:
    for b in st.get("backup", []):
        ts = b.get("timestamp", {})
        ini = ts.get("start"); fim = ts.get("stop")
        if not ini or ini < lim:
            continue
        info = b.get("info", {})
        tam = info.get("repository", {}).get("size", info.get("size"))
        print("\t".join([st.get("name", ""), tm.get(b.get("type"), "FULL"), f(ini), f(fim) if fim else "", "" if tam is None else str(tam)]))
'

bk_pgbackrest() { # usa PG_OWNER/INST ; retorna 0 se a ferramenta existe
    local bin out rc stz tipo ini fim bytes n=0
    bin=$(command -v pgbackrest 2>/dev/null) || return 1
    if ! command -v python3 >/dev/null 2>&1; then
        aviso "postgresql $INST: pgbackrest detectado; python3 ausente para ler o JSON (backups nao coletados)"; return 0
    fi
    out=$(as_user "$PG_OWNER" "$bin" info --output=json 2>/dev/null </dev/null); rc=$?
    if [ $rc -ne 0 ] || [ -z "$out" ]; then aviso "postgresql $INST: pgbackrest info falhou (rc=$rc)"; return 0; fi
    out=$(printf '%s' "$out" | python3 -c "$PY_PGBACKREST" "$JANELA_DIAS"); rc=$?
    if [ $rc -ne 0 ]; then aviso "postgresql $INST: JSON do pgbackrest ilegivel"; return 0; fi
    while IFS="$TAB" read -r stz tipo ini fim bytes; do
        [ -n "$stz" ] || continue
        emit bk.tsv postgresql "$INST" "$stz" pgbackrest "$tipo" "" "$ini" "$fim" SUCESSO "$bytes" ""
        n=$((n + 1))
    done <<<"$out"
    [ "$n" -gt 0 ] || aviso "postgresql $INST: pgbackrest sem backups na janela de ${JANELA_DIAS} dias"
    return 0
}

ferramentas_backup() { # $1 = lista de binarios a procurar
    local t r=""
    for t in $1; do command -v "$t" >/dev/null 2>&1 && r="$r $t"; done
    printf '%s' "${r# }"
}

bk_postgresql() {
    bk_pgbackrest && return 0
    local t; t=$(ferramentas_backup "barman wal-g pg_probackup pg_basebackup")
    if [ -n "$t" ]; then aviso "postgresql $INST: ferramenta(s) de backup detectada(s): $t (sem coleta na v1)"
    else aviso "postgresql $INST: nenhuma ferramenta de backup conhecida detectada (backups nao coletados na v1)"; fi
}

bk_mysql() {
    local t; t=$(ferramentas_backup "mariabackup xtrabackup mysqlbackup mydumper mysqldump mariadb-dump")
    if [ -n "$t" ]; then aviso "mysql $INST: ferramenta(s) de backup detectada(s): $t (sem coleta na v1)"
    else aviso "mysql $INST: nenhuma ferramenta de backup conhecida detectada (backups nao coletados na v1)"; fi
}

#------------------------------------------------------------------ MONGODB
MG_PORT=""; MG_CLI=""

mongo_js() { # $1 = JS
    local -a a=("$MG_CLI" --quiet)
    case "$MG_CLI" in *mongosh*) a+=(--norc) ;; esac
    if [ -n "${WISEDB_MONGO_URI:-}" ]; then a+=("$WISEDB_MONGO_URI"); else a+=("mongodb://127.0.0.1:$MG_PORT/admin"); fi
    a+=(--eval "$1")
    tmo "${a[@]}" 2>&1 </dev/null
}

probe_mongodb() {
    MG_PORT=$FA; MG_CLI=$FB
    if [ -z "$MG_CLI" ]; then ACESSO="sem_cliente"; DETALHE="mongosh/mongo nao encontrado"; return; fi
    local out rc
    out=$(mongo_js "print('VER;' + db.version()); db.adminCommand({listDatabases: 1, nameOnly: true}).databases.length;"); rc=$?
    VERSAO=$(printf '%s\n' "$out" | sed -n 's/^VER;//p' | head -n 1 | tr -cd 'A-Za-z0-9._-')
    if [ $rc -eq 0 ] && [ -n "$VERSAO" ] && ! printf '%s' "$out" | grep -Eqi 'Unauthorized|requires authentication|not authorized|MongoServerError'; then
        ACESSO="ok"; DETALHE=""; return
    fi
    if [ $rc -eq 124 ]; then ACESSO="erro"; DETALHE="timeout (${TMO}s)"; return; fi
    classifica_erro "$out"
    [ "$ACESSO" != "sem_credencial" ] || DETALHE="exige autenticacao (defina WISEDB_MONGO_URI): $(clean "$DETALHE" 100)"
}

cresc_mongodb() {
    local agora out rc tag db col bytes
    agora=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    out=$(mongo_js "var T = String.fromCharCode(9);
db.adminCommand({listDatabases: 1, nameOnly: true}).databases.forEach(function (d) {
  var n = d.name;
  if (['admin', 'local', 'config'].indexOf(n) >= 0) return;
  var s = db.getSiblingDB(n);
  var st = s.runCommand({dbStats: 1});
  if (!st.ok) return;
  print('DB' + T + n + T + Math.round(st.storageSize + st.indexSize));
  s.getCollectionInfos({type: 'collection'}).forEach(function (c) {
    try {
      var cs = s.runCommand({collStats: c.name});
      if (cs.ok) print('COL' + T + n + T + c.name + T + Math.round(cs.storageSize + cs.totalIndexSize));
    } catch (e) {}
  });
});"); rc=$?
    if [ $rc -ne 0 ]; then classifica_erro "$out"; aviso "mongodb $INST: crescimento nao coletado ($DETALHE)"; return 1; fi
    while IFS="$TAB" read -r tag db col bytes; do
        case "$tag" in
            DB) emit cresc.tsv mongodb "$INST" "$db" "" total "$db" "$col" "$agora" ;;
            COL) emit cresc.tsv mongodb "$INST" "$db" "" collection "$col" "$bytes" "$agora" ;;
        esac
    done < <(printf '%s\n' "$out" | grep -E "^(DB|COL)$TAB")
    return 0
}

bk_mongodb() {
    local t; t=$(ferramentas_backup "mongodump mongorestore mongobackup")
    if [ -n "$t" ]; then aviso "mongodb $INST: ferramenta(s) de backup detectada(s): $t (sem coleta na v1)"
    else aviso "mongodb $INST: nenhuma ferramenta de backup conhecida detectada (backups nao coletados na v1)"; fi
}

#------------------------------------------------------------------ conversao de horario local -> UTC
# conv_utc ARQ coluna...  (valores 'AAAA-MM-DD HH:MM:SS' em hora local viram ISO UTC; os demais ficam)
conv_utc() {
    local f=$1; shift
    local cols="$*"
    [ -s "$f" ] || return 0
    awk -F'\t' -v cols="$cols" '
        BEGIN { n = split(cols, c, " ") }
        { for (i = 1; i <= n; i++) { v = $(c[i]); if (v ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]$/) print v } }' "$f" | sort -u > "$W/dts.in"
    [ -s "$W/dts.in" ] || return 0
    if date -f "$W/dts.in" +%s > "$W/dts.ep" 2>/dev/null && date -u -f <(sed 's/^/@/' "$W/dts.ep") '+%Y-%m-%dT%H:%M:%SZ' > "$W/dts.out" 2>/dev/null; then :
    else
        local l e
        : > "$W/dts.out"
        while IFS= read -r l; do
            e=$(date -d "$l" +%s 2>/dev/null) && date -u -d "@$e" '+%Y-%m-%dT%H:%M:%SZ' >> "$W/dts.out" || echo "?" >> "$W/dts.out"
        done < "$W/dts.in"
    fi
    paste -d '\t' "$W/dts.in" "$W/dts.out" > "$W/dts.map"
    [ -s "$W/dts.map" ] || return 0
    awk -F'\t' -v OFS='\t' -v cols="$cols" '
        BEGIN { n = split(cols, c, " ") }
        NR == FNR { m[$1] = $2; next }
        { for (i = 1; i <= n; i++) { k = c[i]; v = $k; if (v in m) $k = (m[v] == "?") ? "" : m[v] } print }' "$W/dts.map" "$f" > "$f.new" && mv "$f.new" "$f"
}

#------------------------------------------------------------------ JSON
sanear() { # stdin -> stdout: sem controle, UTF-8 valido
    tr -d '\r' | tr '\000-\010\013-\037\177' ' ' | { if command -v iconv >/dev/null 2>&1; then iconv -c -f UTF-8 -t UTF-8 2>/dev/null; else tr -cd '\11\12\40-\176'; fi; }
}

# tsv_json ARQ nomes kinds   (kinds: s texto, n texto/null, i inteiro/null, I inteiro obrigatorio)
tsv_json() {
    [ -s "$1" ] || return 0
    sanear < "$1" | awk -F'\t' -v nomes="$2" -v kinds="$3" '
        function esc(s,   o, i, n, c) {
            if (index(s, "\\") == 0 && index(s, "\"") == 0) return s
            o = ""; n = length(s)
            for (i = 1; i <= n; i++) { c = substr(s, i, 1); if (c == "\\") o = o "\\\\"; else if (c == "\"") o = o "\\\""; else o = o c }
            return o
        }
        BEGIN { nn = split(nomes, N, ","); first = 1 }
        {
            out = "    {"
            for (i = 1; i <= nn; i++) {
                v = $i; k = substr(kinds, i, 1)
                if (k == "s") val = "\"" esc(v) "\""
                else if (k == "n") val = (v == "") ? "null" : "\"" esc(v) "\""
                else if (k == "i") val = (v ~ /^[0-9]+$/) ? v : "null"
                else val = (v ~ /^[0-9]+$/) ? v : "0"
                out = out (i > 1 ? ", " : "") "\"" N[i] "\": " val
            }
            out = out "}"
            if (!first) printf ",\n"
            printf "%s", out; first = 0
        }
        END { if (!first) printf "\n" }'
}

avisos_json() {
    [ -s "$1" ] || return 0
    sanear < "$1" | awk '
        function esc(s,   o, i, n, c) {
            if (index(s, "\\") == 0 && index(s, "\"") == 0) return s
            o = ""; n = length(s)
            for (i = 1; i <= n; i++) { c = substr(s, i, 1); if (c == "\\") o = o "\\\\"; else if (c == "\"") o = o "\\\""; else o = o c }
            return o
        }
        BEGIN { first = 1 }
        $0 != "" { if (!first) printf ",\n"; printf "    \"%s\"", esc(substr($0, 1, 300)); first = 0 }
        END { if (!first) printf "\n" }'
}

montar_json() { # $1 = arquivo de saida (.json)
    local out=$1 agora cli c clis=""
    agora=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    for cli in $CLI_OK; do clis="${clis:+$clis, }$(jstr "$cli")"; done
    {
        printf '{\n'
        printf '  "schema": %s,\n' "$(jstr "$SCHEMA_ID")"
        printf '  "cliente_id": %s,\n' "$(jstr "$CLIENTE")"
        printf '  "coletado_em": %s,\n' "$(jstr "$agora")"
        printf '  "agente": {"nome": "wisedb-coleta", "versao": %s, "plataforma": "linux"},\n' "$(jstr "$WIZ_VERSAO")"
        printf '  "host": {"nome": %s, "so": %s, "nuvem": %s, "instancia_id": %s},\n' \
            "$(jstr "$HOST_NOME")" "$(jstr "$HOST_SO")" "$(jnull "$NUVEM")" "$(jnull "$NUVEM_ID")"
        printf '  "inventario": [\n'; tsv_json "$W/inv.tsv" "motor,instancia,versao,acesso,detalhe" "ssnsn"; printf '  ],\n'
        printf '  "crescimento": [\n'; tsv_json "$W/cresc.tsv" "motor,instancia,base,subbase,componente_tipo,componente,bytes,medido_em" "sssnssIs"; printf '  ],\n'
        printf '  "backups": [\n'; tsv_json "$W/bk.tsv" "motor,instancia,base,origem,tipo,dispositivo,inicio,fim,status,bytes,objetos" "sssssnsnsii"; printf '  ],\n'
        printf '  "nuvem": {"cli_detectadas": [%s], "itens": []},\n' "$clis"
        printf '  "avisos": [\n'; avisos_json "$W/avisos.tsv"; printf '  ]\n'
        printf '}\n'
    } > "$out"
}

#------------------------------------------------------------------ envio
URL_ENVIO=""
enviar() { # $1 = arquivo .json.gz ; $2 = timestamp
    local arq=$1 ts=$2 code rc resp
    URL_ENVIO="${LINK}${CLIENTE}/coleta/${HOST_NOME}/${ts}.json.gz"
    code=$(printf 'url = "%s"\n' "$URL_ENVIO" | curl -sS -K - --retry 3 --retry-delay 2 --connect-timeout 20 --max-time 120 \
        -X PUT --data-binary "@$arq" -H 'Content-Type: application/gzip' -o "$W/resp.txt" -w '%{http_code}' 2>"$W/curl_err.txt")
    rc=$?
    if [ "$code" = "200" ]; then
        log INFO "enviado: ${CLIENTE}/coleta/${HOST_NOME}/${ts}.json.gz (HTTP 200, $(wc -c < "$arq") bytes)"
        return 0
    fi
    resp=$(oculta_link "$(head -c 300 "$W/resp.txt" 2>/dev/null | tr '\r\n' '  ')")
    case "$code" in
        401|403) log ERRO "envio recusado (HTTP $code): link PAR invalido, expirado ou sem permissao para o prefixo ${CLIENTE}/coleta/" ;;
        404) log ERRO "envio recusado (HTTP 404): bucket/namespace do link nao encontrado" ;;
        000|"") log ERRO "falha de rede no envio (curl rc=$rc): $(oculta_link "$(tr '\r\n' '  ' < "$W/curl_err.txt" | cut -c1-200)")" ;;
        *) log ERRO "envio falhou: HTTP $code $resp" ;;
    esac
    return 1
}

reenviar_arquivo() { # --enviar-arquivo: reenvia um .json.gz gerado por --coletar
    local f=$ARQ_ENVIO host cli ts
    [ -f "$f" ] && [ -r "$f" ] || { log ERRO "arquivo nao encontrado: $f"; return 1; }
    gzip -t "$f" 2>/dev/null || { log ERRO "$f nao e um gzip valido"; return 1; }
    host=$(gzip -dc "$f" | sed -n 's/^  "host": {"nome": "\([A-Za-z0-9_.-]*\)".*/\1/p' | head -n 1)
    cli=$(gzip -dc "$f" | sed -n 's/^  "cliente_id": "\([^"]*\)".*/\1/p' | head -n 1)
    ts=$(gzip -dc "$f" | sed -n 's/^  "coletado_em": "\([^"]*\)".*/\1/p' | head -n 1 | tr -d ':-')
    [ -n "$host" ] && [ -n "$ts" ] || { log ERRO "$f nao parece um arquivo do wizard (host/coletado_em ausentes)"; return 1; }
    [ "$cli" = "$CLIENTE" ] || { log ERRO "cliente_id do arquivo ($cli) difere de --cliente ($CLIENTE)"; return 1; }
    HOST_NOME=$host
    enviar "$f" "$ts" || return 6
    return 0
}

#------------------------------------------------------------------ agendamento
sha_arquivo() { sha256sum "$1" 2>/dev/null | awk '{print $1}'; }

do_agendar() {
    if [ "$EUID" -ne 0 ]; then echo "--agendar exige root (conf em /etc/wisedb e crontab do root)" >&2; exit 7; fi
    command -v crontab >/dev/null 2>&1 || { echo "crontab nao encontrado" >&2; exit 7; }
    local cli=${CLIENTE:-$C_CLIENTE} lnk=${LINK:-${WISEDB_LINK:-$C_LINK}} url=${URL_WIZARD:-$C_URL} sha=${SHA_WIZARD:-$C_SHA}
    valida_cliente "$cli" || { echo "--cliente invalido ou ausente" >&2; exit 1; }
    LINK=$lnk
    valida_link "$lnk" || { echo "link PAR invalido: deve comecar com https:// e terminar em /o/" >&2; exit 1; }
    case "$url" in https://*) ;; *) echo "--url-wizard ausente ou nao https" >&2; exit 1 ;; esac
    case "$url" in *[!A-Za-z0-9._~:/?=\&@+-]*) echo "--url-wizard com caracteres nao permitidos" >&2; exit 1 ;; esac
    case "$sha" in [0-9a-f][0-9a-f]*) ;; *) echo "--sha256 ausente ou invalido" >&2; exit 1 ;; esac
    [ "${#sha}" -eq 64 ] && [ -z "${sha//[0-9a-f]/}" ] || { echo "--sha256 deve ter 64 caracteres hexadecimais minusculos" >&2; exit 1; }
    if [ -f "$0" ] && [ -r "$0" ]; then
        local meu; meu=$(sha_arquivo "$0")
        if [ -n "$meu" ] && [ "$meu" != "$sha" ]; then
            echo "o arquivo em execucao ($meu) nao confere com --sha256 informado" >&2; exit 7
        fi
    else
        log AVISO "nao foi possivel conferir o hash do script em execucao (nao e um arquivo)"
    fi
    local dir; dir=$(dirname "$CONF")
    mkdir -p "$dir" && chmod 700 "$dir" || { echo "nao consegui criar $dir" >&2; exit 7; }
    local tmpc="$CONF.tmp.$$"
    {
        printf '# WiseDB coleta (gerado por wisedb-coleta.sh %s em %s)\n' "$WIZ_VERSAO" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
        printf 'CLIENTE_ID=%s\nLINK_PAR=%s\nURL_WIZARD=%s\nSHA256_WIZARD=%s\n' "$cli" "$lnk" "$url" "$sha"
    } > "$tmpc" && chmod 600 "$tmpc" && mv -f "$tmpc" "$CONF" || { echo "nao consegui gravar $CONF" >&2; exit 7; }
    local h hn min hora dia expr
    hn=$(hostname -s 2>/dev/null || uname -n 2>/dev/null || echo host)
    h=$(printf '%s' "$hn$cli" | cksum | awk '{print $1}')
    min=$((h % 60)); hora=$(( (h / 60) % 4 + 1 )); dia=1
    if [ "$AGENDA" = "semanal" ]; then expr="$min $hora * * $dia"; else expr="$min $hora * * *"; fi
    local linha
    linha="$expr /bin/bash -c 'f=\$(mktemp /tmp/wisedb-coleta.XXXXXX) || exit 1; curl -fsSL --max-time 60 \"$url\" -o \"\$f\" && echo \"$sha  \$f\" | sha256sum -c --quiet - && bash \"\$f\"; r=\$?; rm -f \"\$f\"; exit \$r' >> $LOGFILE_CRON 2>&1 $TAG_CRON"
    local atual
    atual=$(crontab -l 2>/dev/null | grep -vF "$TAG_CRON")
    { [ -z "$atual" ] || printf '%s\n' "$atual"; printf '%s\n' "$linha"; } | crontab - || { echo "crontab falhou" >&2; exit 7; }
    ( umask 077; touch "$LOGFILE_CRON" 2>/dev/null; chmod 600 "$LOGFILE_CRON" 2>/dev/null )
    echo "Agendamento $AGENDA gravado: $expr (conf: $CONF, log: $LOGFILE_CRON)."
    echo "O cron baixa $url, confere o SHA-256 e so entao executa."
    exit 0
}

do_remover() {
    command -v crontab >/dev/null 2>&1 || { echo "crontab nao encontrado" >&2; exit 7; }
    local atual novo
    atual=$(crontab -l 2>/dev/null)
    novo=$(printf '%s\n' "$atual" | grep -vF "$TAG_CRON")
    if [ "$atual" = "$novo" ]; then echo "Nenhuma linha '$TAG_CRON' no crontab."
    else
        if [ -n "$novo" ]; then printf '%s\n' "$novo" | crontab - ; else crontab -r 2>/dev/null; fi
        echo "Linha de agendamento removida do crontab."
    fi
    if [ "$APAGAR_CONF" = 1 ]; then
        rm -f "$CONF" && echo "Removido: $CONF"; rmdir "$(dirname "$CONF")" 2>/dev/null
        rm -f "$LOGFILE_CRON" 2>/dev/null
    else
        echo "Mantido: $CONF (use --apagar-conf para remover tambem o conf e o log)."
    fi
    exit 0
}

#------------------------------------------------------------------ principal
LOCKF=""
trava() {
    local lf
    if [ "$EUID" -eq 0 ]; then lf=/var/lock/wisedb-coleta.lock; else lf="${TMPDIR:-/tmp}/wisedb-coleta-$EUID.lock"; fi
    [ -d "$(dirname "$lf")" ] || lf="${TMPDIR:-/tmp}/wisedb-coleta-$EUID.lock"
    if command -v flock >/dev/null 2>&1; then
        exec 9>"$lf" || return 0
        flock -n 9 || { log ERRO "outra execucao em andamento (lock $lf)"; exit 2; }
    else
        mkdir "$lf.d" 2>/dev/null || { log ERRO "outra execucao em andamento (lock $lf.d)"; exit 2; }
        LOCKF=$lf
        trap 'rmdir "$LOCKF.d" 2>/dev/null; rm -rf "$W"' EXIT
    fi
}

rotaciona_log_cron() {
    [ -f "$LOGFILE_CRON" ] && [ -w "$LOGFILE_CRON" ] || return 0
    if [ "$(stat -c %s "$LOGFILE_CRON" 2>/dev/null || echo 0)" -gt 1048576 ]; then
        tail -n 500 "$LOGFILE_CRON" > "$LOGFILE_CRON.tmp" 2>/dev/null && cat "$LOGFILE_CRON.tmp" > "$LOGFILE_CRON"; rm -f "$LOGFILE_CRON.tmp"
    fi
}

imprime_inventario() {
    printf 'WiseDB coleta v%s | host %s | %s\n' "$WIZ_VERSAO" "$HOST_NOME" "$HOST_SO"
    printf 'Nuvem: %s%s | CLIs autenticadas: %s\n' "${NUVEM:-nenhuma detectada}" "${NUVEM_ID:+ ($NUVEM_ID)}" "$(echo ${CLI_OK:-nenhuma})"
    printf 'Executando como: %s%s\n\n' "$ME" "$([ "$EUID" -eq 0 ] || echo ' (nao e root: so bancos do proprio usuario)')"
    if [ -s "$W/inv.tsv" ]; then
        awk -F'\t' 'BEGIN { printf "%-11s %-14s %-24s %-15s %s\n", "MOTOR", "INSTANCIA", "VERSAO", "ACESSO", "DETALHE" }
                    { printf "%-11s %-14s %-24s %-15s %s\n", $1, $2, ($3 == "" ? "-" : $3), $4, $5 }' "$W/inv.tsv"
    else
        echo "Nenhum banco de dados encontrado neste servidor."
    fi
    if [ -s "$W/avisos.tsv" ]; then printf '\nAvisos:\n'; sed 's/^/  - /' "$W/avisos.tsv"; fi
}

main() {
    parse_args "$@"
    [ "$MODO" != "remover" ] || do_remover
    init_ambiente
    ler_conf
    [ "$MODO" != "gravarcred" ] || do_gravar_cred
    ler_credenciais
    [ -n "$CLIENTE" ] || CLIENTE=$C_CLIENTE
    [ -n "$LINK" ] || LINK=${WISEDB_LINK:-$C_LINK}
    [ "$MODO" != "agendar" ] || do_agendar
    if [ "$MODO" != "descobrir" ]; then
        valida_cliente "$CLIENTE" || { echo "informe --cliente ID (A-Z a-z 0-9 . _ -) ou grave no conf" >&2; exit 1; }
    fi
    if [ "$MODO" = "padrao" ] || [ "$MODO" = "enviar" ]; then
        [ -n "$LINK" ] || { echo "informe --link URL_PAR (ou WISEDB_LINK, ou o conf)" >&2; exit 1; }
        valida_link "$LINK" || { echo "link PAR invalido: deve comecar com https:// e terminar em /o/ (inicio: $(link_curto))" >&2; exit 1; }
    fi
    trava
    rotaciona_log_cron
    local c
    for c in awk sed gzip date stat sort tr head cut mktemp find paste cat grep; do
        command -v "$c" >/dev/null 2>&1 || { log ERRO "comando ausente: $c"; exit 3; }
    done
    if { [ "$MODO" = "padrao" ] || [ "$MODO" = "enviar" ]; } && ! command -v curl >/dev/null 2>&1; then log ERRO "curl nao encontrado (necessario para o envio)"; exit 3; fi
    if [ "$MODO" = "enviar" ]; then reenviar_arquivo; exit $?; fi
    [ "$EUID" -eq 0 ] || log AVISO "executando como $ME (nao e root): so e possivel coletar bancos acessiveis a este usuario"

    log INFO "wisedb-coleta v$WIZ_VERSAO modo=$MODO host=$HOST_NOME${CLIENTE:+ cliente=$CLIENTE}${LINK:+ link=$(link_curto)}"
    detect_cloud
    detect_cli
    scan_processos

    local motor INST OWNER FA FB FC n_inst=0 n_ok=0
    while IFS='|' read -r motor INST OWNER FA FB FC <&3; do
        [ -n "$motor" ] || continue
        n_inst=$((n_inst + 1))
        ACESSO=""; DETALHE=""; VERSAO=""
        if [ "$OWNER" = "@container" ]; then
            ACESSO="erro"; DETALHE="processo em container (rede isolada); rode o wizard dentro do container"
        else
            case "$motor" in
                oracle) probe_oracle ;;
                sqlserver) probe_sqlserver ;;
                mysql) probe_mysql ;;
                postgresql) probe_postgresql ;;
                mongodb) probe_mongodb ;;
            esac
        fi
        emit inv.tsv "$motor" "$INST" "$VERSAO" "$ACESSO" "$DETALHE"
        if [ "$ACESSO" != "ok" ]; then
            aviso "$motor $INST: $ACESSO${DETALHE:+ ($DETALHE)}"
            continue
        fi
        n_ok=$((n_ok + 1))
        [ "$MODO" != "descobrir" ] || continue
        log INFO "coletando $motor $INST"
        case "$motor" in
            oracle) cresc_oracle; bk_oracle_rman; bk_oracle_expdp ;;
            sqlserver) cresc_sqlserver; bk_sqlserver ;;
            mysql) cresc_mysql; bk_mysql ;;
            postgresql) cresc_postgresql; bk_postgresql ;;
            mongodb) cresc_mongodb; bk_mongodb ;;
        esac
    done 3< "$W/found.dat"

    if [ "$MODO" = "descobrir" ]; then imprime_inventario; exit 0; fi

    conv_utc "$W/bk.tsv" 7 8
    local ts json gz
    ts=$(date -u +%Y%m%dT%H%M%SZ)
    json="$W/coleta.json"; gz="$W/coleta.json.gz"
    montar_json "$json" || { log ERRO "falha ao montar o JSON"; exit 5; }
    gzip -9 -n -c "$json" > "$gz" 2>/dev/null && gzip -t "$gz" 2>/dev/null || { log ERRO "falha ao gerar/validar o gzip"; exit 5; }
    log INFO "resumo: instancias=$n_inst acesso_ok=$n_ok crescimento=$(wc -l < "$W/cresc.tsv") backups=$(wc -l < "$W/bk.tsv") avisos=$(wc -l < "$W/avisos.tsv") bytes_gz=$(wc -c < "$gz")"

    if [ -n "$SAIDA" ]; then
        cp -f "$gz" "$SAIDA" 2>/dev/null && chmod 600 "$SAIDA" 2>/dev/null || { log ERRO "nao consegui gravar $SAIDA"; exit 5; }
        log INFO "arquivo gravado: $SAIDA"
    fi
    local rc=0
    if [ "$MODO" = "padrao" ]; then enviar "$gz" "$ts" || rc=6; fi
    if [ "$rc" -eq 0 ] && [ "$n_inst" -gt 0 ] && [ "$n_ok" -eq 0 ]; then
        log ERRO "havia $n_inst instancia(s) e nenhuma foi coletada (veja os avisos)"; rc=4
    fi
    exit "$rc"
}

if [ -z "${WISEDB_SOURCE_ONLY:-}" ]; then main "$@"; fi
