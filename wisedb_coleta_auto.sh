#!/bin/bash
#===============================================================================
# wisedb_coleta_auto.sh - WiseDB | Coleta AUTOMATICA para Politica de Backup
# v3.3 - Wizard blindado (papel do host, multi-tenancy, coerencia de escopo)
#
# USO:
#   export WISEDB_BASE_URL="https://raw.githubusercontent.com/SUAORG/wisedb-kit/main"
#   bash <(curl -fsSL "$WISEDB_BASE_URL/wisedb_coleta_auto.sh")
#
#   Em host legado, a v3.3 tenta TLS normal nos modulos e faz fallback
#   automatico para -k somente quando o curl retornar erro 60. Para desabilitar:
#   export WISEDB_SSL_FALLBACK=0
#
# PRINCIPIO CRITICO DESTA VERSAO:
#   Nunca assumir que o servidor onde o script roda pertence ao cliente.
#   Um bastion/jump da WiseDB com N profiles OCI NAO e ambiente do cliente:
#   seus dados locais (cron, discos, bases) sao contexto de FERRAMENTA e sao
#   marcados como NAO APLICAVEIS A POLITICA. Somente a coleta remota da
#   tenancy escolhida entra como evidencia do cliente.
#
# RISCO: Zero no ambiente. Somente leitura.
#
# v3.3 (setembro/2026)
#   [CRITICO]   A pasta de trabalho passa a conter o nome do cliente e a hora.
#               Antes era wisedb_coleta_<host>_<data>: duas coletas no mesmo
#               bastion, no mesmo dia, para clientes diferentes reutilizavam a
#               mesma pasta e o pacote saia com a coleta OCI de dois clientes
#               juntos. O RESUMO de um cliente chegava a descrever o ambiente
#               do outro. Cada coleta agora tem pasta propria e um arquivo
#               .cliente para rastreabilidade.
#   [NOVO]      Elevacao opcional via sudo, com pergunta ao operador. Sem ela
#               /etc/crontab, /etc/cron.d e o dbcli ficam ilegiveis e o
#               agendador do backup fisico em DB System/ODA nunca e comprovado.
#   [NOVO]      Arquivo nivel_privilegio_coleta.txt declara se a coleta rodou
#               com sudo, para que a pendencia fique explicita no documento.
#   [NOVO]      Profundidade de varredura configuravel e com default maior
#               (WISEDB_LIST_DEPTH=4, WISEDB_DUMP_DEPTH=5), eliminando o falso
#               negativo "nenhum dump" em layouts com PDB em subpasta.
#   [NOVO]      Coleta OCI ampliada: IPs de instancia, volume groups, block
#               volumes, Recovery Service, backup config dos DB Systems,
#               replicacao de bucket e verificacao de copia cross-region.
#   [NOVO]      Downloads dos modulos usam uma funcao comum: primeiro tenta
#               validacao TLS normal e, se o curl retornar erro 60 (CA), faz
#               fallback automatico para -k. O fallback pode ser desligado com
#               WISEDB_SSL_FALLBACK=0. Toda ocorrencia vira alerta na coleta.
#   [NOVO]      Falha de modulo deixa a coleta explicitamente INCOMPLETA e o
#               pacote final fica marcado como pendente, nunca como coleta limpa.
#===============================================================================
set -uo pipefail

WISEDB_SSL_FALLBACK="${WISEDB_SSL_FALLBACK:-1}"
SSL_FALLBACK_USADO=0
COLETA_INCOMPLETA=0
declare -a MODULOS_FALHARAM=()

BASE_URL="${WISEDB_BASE_URL:-https://raw.githubusercontent.com/SUAORG/wisedb-kit/main}"
VERSAO="3.3"
HOSTN=$(hostname -s 2>/dev/null || hostname)
FQDN=$(hostname -f 2>/dev/null || echo "$HOSTN")
DATA=$(date +%Y%m%d)
HORA=$(date +%H%M)
ORIG_DIR="$(pwd)"
# WORK so e definido na FASE 3, quando o cliente e conhecido, para que o nome da
# pasta carregue o cliente e nao possa colidir com a coleta de outro cliente no
# mesmo host e no mesmo dia. Os modulos baixados vivem num temporario proprio.
WORK=""
TMP=$(mktemp -d "${TMPDIR:-/tmp}/wisedb_mod.XXXXXX") || { echo "Falha ao criar temporario"; exit 1; }
trap 'rm -rf "$TMP" 2>/dev/null' EXIT

#---------------------------- UI: cores e helpers -------------------------------
if [ -t 1 ] || [ -e /dev/tty ]; then
  LAR=$'\033[38;5;208m'; CINZA=$'\033[38;5;250m'; MAR=$'\033[38;5;39m'
  MARBG=$'\033[48;5;17m'; VERD=$'\033[38;5;40m'; VERM=$'\033[38;5;196m'
  AMAR=$'\033[38;5;220m'; NEG=$'\033[1m'; DIM=$'\033[2m'; R=$'\033[0m'
else
  LAR=""; CINZA=""; MAR=""; MARBG=""; VERD=""; VERM=""; AMAR=""; NEG=""; DIM=""; R=""
fi
if [ -e /dev/tty ] && { : >/dev/tty; } 2>/dev/null; then TTY=/dev/tty; INTER=1; else TTY=""; INTER=0; fi

ALERTAS=()
say(){ printf "%b\n" "$*"; }
titulo(){ say ""; say "${MARBG}${LAR}${NEG}  $*  ${R}"; }
info(){ say "  ${CINZA}$*${R}"; }
ok(){ say "  ${VERD}OK${R}  $*"; }
warn(){ say "  ${AMAR}!${R}   $*"; ALERTAS+=("$*"); }
erro(){ say "  ${VERM}X${R}   $*"; }

# Download dos modulos WiseDB. O fallback -k vale somente para BASE_URL;
# nao e aplicado ao metadata OCI ou a outras conexoes do ambiente.
wisedb_curl(){
  local url="$1"; shift
  local err rc
  err=$(mktemp "${TMPDIR:-/tmp}/wisedb_curl.XXXXXX") || err=""
  if [ -n "$err" ]; then
    curl -fsSL "$url" "$@" 2>"$err"; rc=$?
  else
    curl -fsSL "$url" "$@" 2>/dev/null; rc=$?
  fi

  if [ "$rc" -eq 0 ]; then
    [ -n "$err" ] && rm -f "$err" 2>/dev/null
    return 0
  fi

  # Erro 60 = certificado/CA nao confiavel no curl.
  if [ "$rc" -eq 60 ] && [ "$WISEDB_SSL_FALLBACK" = "1" ]; then
    SSL_FALLBACK_USADO=1
    warn "TLS/CA nao confiavel para $url; tentando novamente com -k (fallback SSL habilitado)"
    if curl -k -fsSL "$url" "$@"; then
      [ -n "$err" ] && rm -f "$err" 2>/dev/null
      return 0
    fi
  fi

  if [ -n "$err" ]; then
    cat "$err" >&2 2>/dev/null
    rm -f "$err" 2>/dev/null
  fi
  return "$rc"
}

wisedb_download(){
  local module="$1" dest="$2"
  wisedb_curl "$BASE_URL/$module" -o "$dest"
}

pergunta(){ # pergunta "label" var "default"
  local label="$1" var="$2" def="${3:-}" resp=""
  if [ "$INTER" = "1" ]; then
    printf "%b" "  ${LAR}?${R} ${NEG}$label${R}${def:+ ${DIM}[$def]${R}}: " > "$TTY"
    IFS= read -r resp < "$TTY"
  fi
  [ -z "$resp" ] && resp="$def"
  printf -v "$var" '%s' "$resp"
}

MENU_SEL=()
menu_sel(){ # menu_sel single|multi "titulo" item...
  local modo="$1" tit="$2"; shift 2
  local -a itens=("$@")
  local n=${#itens[@]} cur=0 i
  local -a marc; for ((i=0;i<n;i++)); do marc[i]=0; done
  MENU_SEL=()
  [ "$n" -eq 0 ] && return 0
  if [ "$INTER" = "0" ]; then [ "$modo" = "single" ] && MENU_SEL=(0); return 0; fi
  while :; do
    {
      printf "\n  ${NEG}%s${R}\n" "$tit"
      if [ "$modo" = "multi" ]; then
        printf "  ${DIM}setas ou j/k move | ESPACO marca | a=todos | n=nenhum | ENTER confirma${R}\n"
      else
        printf "  ${DIM}setas ou j/k move | numero seleciona direto | ENTER confirma${R}\n"
      fi
      for ((i=0;i<n;i++)); do
        local cursor="  " box=""
        [ "$i" -eq "$cur" ] && cursor="${LAR}>${R} "
        if [ "$modo" = "multi" ]; then
          [ "${marc[i]}" = "1" ] && box="${VERD}[x]${R} " || box="${CINZA}[ ]${R} "
        else
          [ "$i" -eq "$cur" ] && box="${LAR}(o)${R} " || box="${CINZA}( )${R} "
        fi
        printf "  %b%b%b\n" "$cursor" "$box" "${itens[i]}"
      done
    } > "$TTY"
    local k rest
    IFS= read -rsn1 k < "$TTY"
    case "$k" in
      $'\033') IFS= read -rsn2 -t 0.1 rest < "$TTY" || rest=""
               case "$rest" in "[A") [ "$cur" -gt 0 ] && cur=$((cur-1));; "[B") [ "$cur" -lt $((n-1)) ] && cur=$((cur+1));; esac;;
      k|K) [ "$cur" -gt 0 ] && cur=$((cur-1));;
      j|J) [ "$cur" -lt $((n-1)) ] && cur=$((cur+1));;
      " ") [ "$modo" = "multi" ] && marc[cur]=$((1-marc[cur]));;
      a|A) [ "$modo" = "multi" ] && for ((i=0;i<n;i++)); do marc[i]=1; done;;
      n|N) [ "$modo" = "multi" ] && for ((i=0;i<n;i++)); do marc[i]=0; done;;
      ""|$'\n')
        if [ "$modo" = "single" ]; then MENU_SEL=("$cur"); return 0
        else for ((i=0;i<n;i++)); do [ "${marc[i]}" = "1" ] && MENU_SEL+=("$i"); done; return 0; fi;;
      [0-9]) local idx=$((k-1))
             if [ "$idx" -ge 0 ] && [ "$idx" -lt "$n" ]; then
               if [ "$modo" = "single" ]; then MENU_SEL=("$idx"); return 0
               else marc[idx]=$((1-marc[idx])); fi
             fi;;
    esac
    printf "\033[%dA\033[J" $((n+3)) > "$TTY"
  done
}

say ""
say "${MARBG}${LAR}${NEG}  WiseDB - Coleta Automatica de Backup  v$VERSAO  ${R}"
info "Host: $FQDN | Usuario: $(whoami) | $(date '+%d/%m/%Y %H:%M %Z')"
wisedb_curl "$BASE_URL/01_coleta_linux_geral.sh" -o /dev/null || \
  warn "Nao foi possivel baixar modulos de $BASE_URL (verifique WISEDB_BASE_URL, HTTPS e/ou WISEDB_SSL_FALLBACK)"

#===============================================================================
# FASE 1 - DESCOBERTA PROFUNDA (lista TUDO, nao escolhe nada)
#===============================================================================
titulo "FASE 1 - DESCOBERTA DO AMBIENTE"
tem(){ command -v "$1" >/dev/null 2>&1; }

VM_TENANCY=""; VM_COMPART=""; VM_NOME_OCI=""; VM_REGIAO=""; NA_OCI=0; MD_CONFIAVEL=1
if curl -fsSL -m 3 -H "Authorization: Bearer Oracle" \
     http://169.254.169.254/opc/v2/instance/ -o "$TMP/_md.json" 2>/dev/null; then
  NA_OCI=1
  VM_TENANCY=$(grep -o '"tenantId"[^,]*' "$TMP/_md.json" | cut -d'"' -f4)
  VM_COMPART=$(grep -o '"compartmentId"[^,]*' "$TMP/_md.json" | cut -d'"' -f4)
  VM_NOME_OCI=$(grep -o '"displayName"[^,]*' "$TMP/_md.json" | cut -d'"' -f4)
  VM_REGIAO=$(grep -o '"canonicalRegionName"[^,]*' "$TMP/_md.json" | cut -d'"' -f4)
  ok "Esta maquina E uma instancia OCI: ${NEG}${VM_NOME_OCI:-?}${R} (regiao ${VM_REGIAO:-?})"
  info "Tenancy reportada pelo metadata: ${VM_TENANCY:-nao exposta}"
  case "$VM_NOME_OCI" in ocid1.dbsystem*|ocid1.autonomous*|ocid1.vmcluster*|ocid1.cloudvmcluster*)
    MD_CONFIAVEL=0
    warn "Servico gerenciado da OCI (DB System/Exa/ADB): o metadata devolve a tenancy do service enclave da Oracle, NAO a do cliente. Comparacao de tenancy sera apenas informativa."
    ;;
  esac
else
  info "Metadata OCI nao respondeu: on-premises, outra cloud ou metadata bloqueado"
fi

declare -a ORA_SIDS=()
if [ -r /etc/oratab ]; then
  while IFS=: read -r sid home rest; do
    case "$sid" in ''|'#'*|'+ASM'*|'-MGMTDB'|agent*) continue;; esac
    ORA_SIDS+=("$sid|${home:-home?}")
  done < /etc/oratab
fi
while read -r p; do
  [ -z "$p" ] && continue
  if [ ${#ORA_SIDS[@]} -eq 0 ] || ! printf '%s\n' "${ORA_SIDS[@]}" | grep -q "^$p|"; then
    ORA_SIDS+=("$p|(processo ativo, ausente no oratab)")
  fi
done < <(ps -eo args 2>/dev/null | grep -o 'ora_pmon_[A-Za-z0-9_]*' | sed 's/ora_pmon_//' | sort -u)
ORA_GERENCIADO=0
if tem dbcli || tem dbaascli; then
  ORA_GERENCIADO=1
  MD_CONFIAVEL=0
fi
if [ ${#ORA_SIDS[@]} -gt 0 ]; then
  ok "Oracle: ${#ORA_SIDS[@]} instancia(s)"
  for s in "${ORA_SIDS[@]}"; do info "  - ${s%%|*}  ${DIM}(${s##*|})${R}"; done
  [ "$ORA_GERENCIADO" = "1" ] && warn "dbcli/dbaascli presente: backup pode ser GERENCIADO pela OCI (DB System), nao por cron"
  tem crsctl && warn "Clusterware/RAC detectado: o backup pode executar em OUTRO no do cluster"
fi

SQL_ON=0; declare -a SQL_PORTAS=()
if pgrep -x sqlservr >/dev/null 2>&1 || systemctl is-active mssql-server >/dev/null 2>&1; then
  SQL_ON=1
  mapfile -t SQL_PORTAS < <(ss -lntp 2>/dev/null | grep -i sqlservr | awk '{print $4}' | sort -u)
  ok "SQL Server ativo${SQL_PORTAS:+ (${SQL_PORTAS[*]})}"
fi
MY_ON=0; PG_ON=0
if pgrep -x mysqld >/dev/null 2>&1 || pgrep -x mariadbd >/dev/null 2>&1; then
  MY_ON=1; ok "MySQL/MariaDB ativo:"
  ps -eo user,pid,args 2>/dev/null | grep -E '^\S+ +[0-9]+ +\S*(mysqld|mariadbd)' | grep -v grep | head -3 | while read -r l; do info "  $l"; done
  warn "Confirme se este MySQL/MariaDB pertence ao cliente ou e apoio de ferramenta (ex.: Zabbix). Rotina de dump/binlog nao e coletada automaticamente."
fi
if pgrep -f 'postgres.*checkpointer' >/dev/null 2>&1; then
  PG_ON=1; ok "PostgreSQL ativo:"
  ps -eo user,pid,args 2>/dev/null | grep -E 'postgres' | grep -v grep | head -3 | while read -r l; do info "  $l"; done
  warn "Confirme se este PostgreSQL pertence ao cliente ou e apoio de ferramenta. Rotina de pg_dump/WAL nao e coletada automaticamente."
fi

for c in docker podman; do
  if tem $c; then
    CD=$($c ps --format '{{.Names}} {{.Image}}' 2>/dev/null | grep -Ei 'oracle|mysql|maria|postgres|mssql|mongo' | head -5)
    [ -n "$CD" ] && { warn "Containers com banco ($c): a coleta NAO entra no container, verificar a parte"; info "$CD"; }
  fi
done

HYP_ON=0; VEEAM_ON=0
{ tem pvesh || tem proxmox-backup-manager || { tem virsh && ! tem pvesh; }; } && { HYP_ON=1; ok "Hypervisor Linux detectado"; }
tem veeamconfig && { VEEAM_ON=1; ok "Veeam Agent for Linux presente"; }

declare -a OCI_PROF=() OCI_TEN=() OCI_REG=()
OCICFG="${OCI_CLI_CONFIG_FILE:-$HOME/.oci/config}"
if tem oci && [ -r "$OCICFG" ]; then
  cur=""
  while IFS= read -r ln; do
    ln="${ln%%#*}"; ln="$(echo "$ln" | tr -d '[:space:]')"
    case "$ln" in
      "["*"]") cur="${ln#[}"; cur="${cur%]}"; OCI_PROF+=("$cur"); OCI_TEN+=(""); OCI_REG+=("");;
      tenancy=*) [ -n "$cur" ] && OCI_TEN[$((${#OCI_PROF[@]}-1))]="${ln#tenancy=}";;
      region=*)  [ -n "$cur" ] && OCI_REG[$((${#OCI_PROF[@]}-1))]="${ln#region=}";;
    esac
  done < "$OCICFG"
  ok "OCI CLI: ${#OCI_PROF[@]} profile(s) em $OCICFG"
  for i in "${!OCI_PROF[@]}"; do info "  - ${OCI_PROF[i]}  ${DIM}${OCI_REG[i]:-regiao?} | tenancy ...${OCI_TEN[i]: -12}${R}"; done
fi
MULTI_TENANT=0; [ ${#OCI_PROF[@]} -gt 1 ] && MULTI_TENANT=1

declare -a CRON_HITS=()
cq(){ crontab -l ${2:+-u "$2"} 2>/dev/null | grep -Eic 'backup|rman|expdp|dump|vzdump|rsync|oci os' || true; }
q=$(cq); [ "${q:-0}" -gt 0 ] && CRON_HITS+=("$(whoami): $q linha(s)")
for u in oracle root mssql postgres mysql backup relatorio; do
  [ "$u" = "$(whoami)" ] && continue
  q=$(crontab -l -u "$u" 2>/dev/null | grep -Eic 'backup|rman|expdp|dump|vzdump|rsync|oci os' || true)
  [ "${q:-0}" -gt 0 ] && CRON_HITS+=("$u: $q linha(s)")
done
q=$( { cat /etc/crontab 2>/dev/null; grep -rh '' /etc/cron.d/ 2>/dev/null; } | grep -Eic 'backup|rman|expdp|dump' || true)
[ "${q:-0}" -gt 0 ] && CRON_HITS+=("sistema: $q linha(s)")
if [ ${#CRON_HITS[@]} -gt 0 ]; then
  ok "Indicios de backup no cron:"; for c in "${CRON_HITS[@]}"; do info "  - $c"; done
else
  warn "Nenhum indicio de backup no cron acessivel por este usuario (pode exigir root ou outro owner)"
fi

{
  { crontab -l 2>/dev/null; cat /etc/crontab 2>/dev/null; grep -rh '' /etc/cron.d/ 2>/dev/null; } |
    grep -Eo '/[A-Za-z0-9._/-]{4,}' | grep -Ei 'backup|bkp|dump|export' | xargs -r -n1 dirname 2>/dev/null
  mount | awk '{print $3}' | grep -Ei 'backup|bkp|stage|^/u0'
  ls -d /u0*/ /backup* /bkp* /stage* /var/backup* 2>/dev/null
} 2>/dev/null | sed 's:/*$::' | sort -u | while read -r d; do [ -d "$d" ] && echo "$d"; done > "$TMP/_dirs"
mapfile -t DIR_CAND < "$TMP/_dirs"
if [ ${#DIR_CAND[@]} -gt 0 ]; then
  ok "Diretorios candidatos a repositorio: ${#DIR_CAND[@]}"
  for d in "${DIR_CAND[@]}"; do info "  - $d ${DIM}$(df -h "$d" 2>/dev/null | awk 'NR==2{print "("$2" total, "$5" usado)"}')${R}"; done
fi

SCORE_FERR=0; declare -a SINAIS=()
[ "$MULTI_TENANT" = "1" ] && { SCORE_FERR=$((SCORE_FERR+3)); SINAIS+=("${#OCI_PROF[@]} profiles OCI de tenancies distintas no mesmo host"); }
case "$HOSTN" in *bastion*|*jump*|*wise*|*monitor*|*zabbix*|*relatorio*|*mgmt*|*deploy*)
  SCORE_FERR=$((SCORE_FERR+2)); SINAIS+=("hostname sugere infraestrutura de gestao: $HOSTN");; esac
if [ ${#OCI_PROF[@]} -gt 0 ] && [ ${#ORA_SIDS[@]} -eq 0 ] && [ "$SQL_ON" = "0" ]; then
  SCORE_FERR=$((SCORE_FERR+1)); SINAIS+=("tem OCI CLI mas nenhum SGBD de producao local")
fi

#===============================================================================
# FASE 2 - PAPEL DO HOST (blindagem principal)
#===============================================================================
titulo "FASE 2 - PAPEL DESTE SERVIDOR"
if [ ${#SINAIS[@]} -gt 0 ]; then
  say "  ${AMAR}${NEG}ATENCAO${R} sinais de que este host pode ser FERRAMENTA da WiseDB:"
  for s in "${SINAIS[@]}"; do info "  - $s"; done
fi
info "A resposta abaixo decide o que entra na politica do cliente."
menu_sel single "Qual o papel deste servidor?" \
 "${NEG}HOST DO CLIENTE${R} - servidor do cliente. Dados locais entram na politica." \
 "${NEG}ESTACAO DE COLETA / BASTION WiseDB${R} - multi-cliente. Dados locais NAO entram; so a cloud do cliente." \
 "${NEG}HOST MISTO${R} - do cliente, mas com credenciais de terceiros. Coleta local + tenancy validada."
PAPEL_IDX=${MENU_SEL[0]:-0}
[ "$INTER" = "0" ] && [ "$SCORE_FERR" -ge 3 ] && PAPEL_IDX=1
case "$PAPEL_IDX" in
  0) PAPEL="HOST_DO_CLIENTE"; COLETA_LOCAL=1;;
  1) PAPEL="ESTACAO_COLETA_WISEDB"; COLETA_LOCAL=0;;
  *) PAPEL="HOST_MISTO"; COLETA_LOCAL=1;;
esac
ok "Papel: ${NEG}$PAPEL${R}"
[ "$COLETA_LOCAL" = "0" ] && warn "Coleta LOCAL desabilitada: cron, discos e bases deste host nao serao tratados como do cliente"
[ "$PAPEL" = "HOST_DO_CLIENTE" ] && [ "$MULTI_TENANT" = "1" ] && \
  warn "Host declarado do cliente, porem ha ${#OCI_PROF[@]} tenancies configuradas aqui. Revise o config OCI."

#===============================================================================
# FASE 3 - CLIENTE
#===============================================================================
titulo "FASE 3 - IDENTIFICACAO DO CLIENTE"
pergunta "Nome do cliente (como aparece nos documentos)" CLIENTE ""
while [ -z "$CLIENTE" ] || echo "$CLIENTE" | grep -qiE '^(teste|test|xxx|abc|a|123)$'; do
  [ "$INTER" = "0" ] && { CLIENTE="NAO_INFORMADO"; break; }
  warn "Nome invalido ou de teste. Ele vai para a politica e para o nome do pacote."
  pergunta "Nome do cliente" CLIENTE ""
done
CLI_NORM=$(echo "$CLIENTE" | tr '[:upper:]' '[:lower:]' | tr -cd '[:alnum:]')
CLI_SLUG=$(echo "$CLI_NORM" | cut -c1-6)
# Match bidirecional: cobre "DBS Partner" x profile "DBS" e "Interne..." x "INTERNE"
casa_cliente(){ # casa_cliente "texto"
  local t; t=$(echo "$1" | tr '[:upper:]' '[:lower:]' | tr -cd '[:alnum:]')
  [ -z "$t" ] && return 1
  [ ${#t} -lt 3 ] && return 1
  case "$t" in *"$CLI_SLUG"*) return 0;; esac
  case "$CLI_NORM" in *"$t"*) return 0;; esac
  return 1
}
COERENTE=0
for t in "$HOSTN" "$FQDN" "$VM_NOME_OCI"; do
  casa_cliente "$t" && { COERENTE=1; ok "Nome do cliente compativel com '$t'"; break; }
done
if [ "$COERENTE" = "0" ] && [ ${#OCI_PROF[@]} -gt 0 ]; then
  for p in "${OCI_PROF[@]}"; do
    casa_cliente "$p" && { COERENTE=1; ok "Nome do cliente compativel com o profile '$p'"; break; }
  done
fi
if [ "$COERENTE" = "0" ]; then
  # A tenancy do metadata local conferindo com a do profile escolhido e prova
  # mais forte do que semelhanca de nome. Sem esta ressalva o wizard emitia
  # "cliente nao aparece no hostname" em hosts legitimos, e o alerta falso
  # chegava a virar pendencia no documento do cliente.
  if [ -n "${VM_TENANCY:-}" ] && [ -n "${OCI_SEL_TEN:-}" ] && [ "$VM_TENANCY" = "$OCI_SEL_TEN" ]; then
    ok "Nome do cliente nao casa com hostname nem profile, porem a tenancy do host confere com a do profile: escopo coerente"
  else
    warn "'$CLIENTE' nao aparece no hostname nem nos profiles: confirme que nao houve troca de cliente"
  fi
fi
pergunta "RPO acordado (ENTER se nao definido)" RPO "A combinar com o cliente"
pergunta "RTO acordado (ENTER se nao definido)" RTO "A combinar com o cliente"

#-------------------------------------------------------------------------------
# Pasta de trabalho definitiva: cliente + host + data + hora.
#
# O nome antigo, wisedb_coleta_<host>_<data>, nao continha o cliente. Duas
# coletas no mesmo host e no mesmo dia para clientes diferentes, cenario normal
# num bastion com varios profiles, reutilizavam a MESMA pasta. O resultado era
# um pacote com coleta_oci_<CLIENTE_A> e coleta_oci_<CLIENTE_B> juntos, e um
# RESUMO de um cliente descrevendo o ambiente do outro. Dado de cliente
# vazando para o documento de outro cliente e o pior defeito possivel aqui.
#-------------------------------------------------------------------------------
WORK="$ORIG_DIR/wisedb_coleta_${CLIENTE// /_}_${HOSTN}_${DATA}_${HORA}"
if [ -d "$WORK" ]; then
  warn "Pasta $WORK ja existe; usando sufixo para nao misturar coletas"
  WORK="${WORK}_$$"
fi
mkdir -p "$WORK"
CLI_TAG="$WORK/.cliente"
printf '%s\n' "$CLIENTE" > "$CLI_TAG"

# Guarda adicional: se por qualquer motivo a pasta receber evidencia de outro
# cliente, abortamos a consolidacao em vez de gerar um pacote misturado.
CONTAMINADO=0
for d in "$ORIG_DIR"/wisedb_coleta_*/; do
  [ -d "$d" ] || continue
  [ "$(readlink -f "$d")" = "$(readlink -f "$WORK")" ] && continue
  if [ -f "$d/.cliente" ] && [ "$(cat "$d/.cliente" 2>/dev/null)" != "$CLIENTE" ]; then
    info "Coleta anterior de outro cliente encontrada em $(basename "$d"), sera ignorada"
  fi
done
ok "Pasta de trabalho desta coleta: $(basename "$WORK")"

#-------------------------------------------------------------------------------
# Elevacao opcional. Sem sudo, /etc/crontab e /etc/cron.d ficam ilegiveis para
# oracle e o dbcli nao roda: o agendador do backup fisico do DB System nunca e
# comprovado e a politica registra o agendador como INFERIDO.
#-------------------------------------------------------------------------------
WISEDB_SUDO=0
if command -v sudo >/dev/null 2>&1; then
  if sudo -n true 2>/dev/null; then
    WISEDB_SUDO=1
    ok "sudo sem senha disponivel: cron de sistema e dbcli serao coletados"
  else
    pergunta "Usar sudo para ler cron de sistema e dbcli? Pode pedir senha (S/n)" USESUDO "S"
    if [ "${USESUDO^^}" != "N" ]; then
      if sudo -v 2>/dev/null && sudo -n true 2>/dev/null; then
        WISEDB_SUDO=1; ok "sudo validado"
      else
        warn "sudo indisponivel: cron de sistema e dbcli nao serao coletados; agendador do backup fisico ficara como pendencia"
      fi
    else
      warn "Coleta sem sudo por escolha do operador: cron de sistema e dbcli ficarao como pendencia"
    fi
  fi
else
  warn "sudo nao instalado: cron de sistema e dbcli nao serao coletados"
fi
export WISEDB_SUDO
export WISEDB_LIST_DEPTH="${WISEDB_LIST_DEPTH:-4}"
export WISEDB_DUMP_DEPTH="${WISEDB_DUMP_DEPTH:-5}"

#===============================================================================
# FASE 4 - ESCOPO
#===============================================================================
titulo "FASE 4 - ESCOPO DA COLETA"
declare -a ORA_SEL=() DIR_SEL=()
if [ "$COLETA_LOCAL" = "1" ] && [ ${#ORA_SIDS[@]} -gt 0 ]; then
  disp=(); for s in "${ORA_SIDS[@]}"; do disp+=("${NEG}${s%%|*}${R}  ${DIM}${s##*|}${R}"); done
  menu_sel multi "Instancias Oracle a INCLUIR (ESPACO marca, 'a' = todas)" "${disp[@]}"
  if [ ${#MENU_SEL[@]} -eq 0 ]; then
    warn "Nenhuma marcada: todas serao coletadas"
    for s in "${ORA_SIDS[@]}"; do ORA_SEL+=("${s%%|*}"); done
  else
    for i in "${MENU_SEL[@]}"; do ORA_SEL+=("${ORA_SIDS[i]%%|*}"); done
  fi
  ok "Oracle no escopo: ${ORA_SEL[*]}"
fi
if [ "$COLETA_LOCAL" = "1" ] && [ ${#DIR_CAND[@]} -gt 0 ]; then
  menu_sel multi "Diretorios de backup a inventariar ('a' = todos)" "${DIR_CAND[@]}"
  if [ ${#MENU_SEL[@]} -eq 0 ]; then DIR_SEL=("${DIR_CAND[@]}")
  else for i in "${MENU_SEL[@]}"; do DIR_SEL+=("${DIR_CAND[i]}"); done; fi
fi

OCI_SEL_PROF=""; OCI_SEL_TEN=""; OCI_SEL_REG=""
if [ ${#OCI_PROF[@]} -gt 0 ]; then
  disp=()
  for i in "${!OCI_PROF[@]}"; do
    mark=""
    casa_cliente "${OCI_PROF[i]}" && mark="  ${VERD}<= parece ser deste cliente${R}"
    [ -n "$VM_TENANCY" ] && [ "${OCI_TEN[i]}" = "$VM_TENANCY" ] && mark="$mark  ${MAR}<= mesma tenancy desta VM${R}"
    disp+=("${NEG}${OCI_PROF[i]}${R}  ${DIM}${OCI_REG[i]:-regiao?} | ...${OCI_TEN[i]: -12}${R}$mark")
  done
  disp+=("${VERM}NAO coletar OCI nesta execucao${R}")
  menu_sel single "Profile OCI do cliente '$CLIENTE' (ha ${#OCI_PROF[@]} tenancies neste host)" "${disp[@]}"
  sel=${MENU_SEL[0]:-999}
  if [ "$sel" -lt ${#OCI_PROF[@]} ]; then
    OCI_SEL_PROF="${OCI_PROF[sel]}"; OCI_SEL_TEN="${OCI_TEN[sel]}"; OCI_SEL_REG="${OCI_REG[sel]}"
    ok "Profile: ${NEG}$OCI_SEL_PROF${R} | regiao ${OCI_SEL_REG:-padrao}"
    if [ -n "$VM_TENANCY" ] && [ -n "$OCI_SEL_TEN" ] && [ "$VM_TENANCY" != "$OCI_SEL_TEN" ] && [ "$PAPEL" = "HOST_DO_CLIENTE" ]; then
      if [ "$MD_CONFIAVEL" = "0" ]; then
        info "Tenancy do metadata (...${VM_TENANCY: -12}) difere da do profile (...${OCI_SEL_TEN: -12}), esperado em servico gerenciado: nao e divergencia."
      else
        warn "DIVERGENCIA: esta VM esta na tenancy ...${VM_TENANCY: -12} e o profile aponta para ...${OCI_SEL_TEN: -12}"
        pergunta "Confirma que o profile e do cliente '$CLIENTE'? (s/N)" CONF "N"
        [ "${CONF^^}" != "S" ] && { OCI_SEL_PROF=""; OCI_SEL_TEN=""; OCI_SEL_REG=""; warn "Coleta OCI cancelada por divergencia de tenancy"; }
      fi
    fi
    if [ -n "$OCI_SEL_PROF" ] && ! casa_cliente "$OCI_SEL_PROF"; then
      if [ ${#OCI_PROF[@]} -eq 1 ] && [ "$PAPEL" != "ESTACAO_COLETA_WISEDB" ]; then
        info "Profile unico '$OCI_SEL_PROF' neste host: nome generico e esperado, seguindo sem bloqueio."
      else
        warn "O profile '$OCI_SEL_PROF' nao lembra o nome '$CLIENTE' e ha ${#OCI_PROF[@]} profiles neste host"
        pergunta "Prosseguir com este profile? (s/N)" CONF2 "N"
        [ "${CONF2^^}" != "S" ] && { OCI_SEL_PROF=""; OCI_SEL_TEN=""; OCI_SEL_REG=""; warn "Coleta OCI cancelada pelo operador"; }
      fi
    fi
    if [ -n "$OCI_SEL_PROF" ]; then
      if oci --profile "$OCI_SEL_PROF" os ns get >/dev/null 2>&1 || oci --profile "$OCI_SEL_PROF" iam region list >/dev/null 2>&1; then
        ok "Autenticacao do profile validada"
      else
        warn "Profile '$OCI_SEL_PROF' nao autenticou (chave/permissao): a coleta OCI pode vir vazia"
      fi
    fi
  else
    info "Coleta OCI nao sera executada"
  fi
elif [ "$NA_OCI" = "1" ]; then
  warn "Maquina na OCI sem OCI CLI local: rode a coleta OCI no bastion com o profile do cliente"
fi

SQL_USER=""
[ "$COLETA_LOCAL" = "1" ] && [ "$SQL_ON" = "1" ] && \
  pergunta "Usuario de LEITURA do SQL Server (senha pedida na hora, nao e salva)" SQL_USER ""

declare -a EXCL=()
if [ "$INTER" = "1" ]; then
  while :; do
    pergunta "Ambiente/base FORA do escopo da politica (nome, ENTER p/ seguir)" IT ""
    [ -z "$IT" ] && break
    pergunta "  Justificativa para '$IT'" JU "Nao informado"
    EXCL+=("$IT|$JU")
  done
fi

#===============================================================================
# FASE 5 - CONFIRMACAO
#===============================================================================
titulo "FASE 5 - CONFIRMACAO DO PLANO"
say "  Cliente ...........: ${NEG}$CLIENTE${R}"
say "  Papel do host .....: ${NEG}$PAPEL${R}"
say "  Coleta local ......: $([ "$COLETA_LOCAL" = "1" ] && echo "${VERD}SIM${R}" || echo "${VERM}NAO (host de ferramenta)${R}")"
[ ${#ORA_SEL[@]} -gt 0 ] && say "  Oracle ............: ${ORA_SEL[*]}"
[ -n "$SQL_USER" ] && say "  SQL Server ........: usuario $SQL_USER"
[ ${#DIR_SEL[@]} -gt 0 ] && say "  Diretorios ........: ${DIR_SEL[*]}"
say "  OCI ...............: ${OCI_SEL_PROF:-nao sera coletado}${OCI_SEL_PROF:+ (tenancy ...${OCI_SEL_TEN: -12})}"
say "  Fora do escopo ....: ${#EXCL[@]} item(ns)"
say "  RPO / RTO .........: $RPO / $RTO"
if [ ${#ALERTAS[@]} -gt 0 ]; then
  say "  ${AMAR}Alertas: ${#ALERTAS[@]}${R}"; for a in "${ALERTAS[@]}"; do info "  ! $a"; done
fi
pergunta "Executar a coleta com este plano? (S/n)" GO "S"
[ "${GO^^}" = "N" ] && { erro "Coleta cancelada."; exit 0; }

#===============================================================================
# FASE 6 - COLETA
#===============================================================================
titulo "FASE 6 - COLETA (somente leitura)"
dl(){ local m="$1"; local dest="${TMP_DIGEST:-$TMP}"
  [ "$m" = "wisedb_digest.py" ] || dest="$TMP"
  mkdir -p "$dest"
  if   [ -f "$ORIG_DIR/kit_coleta_backup/$m" ]; then cp "$ORIG_DIR/kit_coleta_backup/$m" "$dest/$m"
  elif [ -f "$ORIG_DIR/$m" ]; then cp "$ORIG_DIR/$m" "$dest/$m"
  else wisedb_download "$m" "$dest/$m" || { erro "Falha ao baixar $m"; MODULOS_FALHARAM+=("$m"); COLETA_INCOMPLETA=1; return 1; }
       [ -s "$dest/$m" ] || { erro "$m veio vazio"; return 1; }
  fi
  chmod +x "$dest/$m"; }

cd "$WORK"
if [ "$COLETA_LOCAL" = "1" ]; then
  if dl 01_coleta_linux_geral.sh; then
    if bash "$TMP/01_coleta_linux_geral.sh" ${DIR_SEL[@]+"${DIR_SEL[@]}"}; then ok "Inventario local coletado"; else erro "Modulo 01 falhou durante a coleta"; MODULOS_FALHARAM+=("01_coleta_linux_geral.sh(execucao)"); COLETA_INCOMPLETA=1; fi
  fi
  if [ ${#ORA_SEL[@]} -gt 0 ]; then
    if dl 02_coleta_oracle.sh; then
      if bash "$TMP/02_coleta_oracle.sh" "${ORA_SEL[@]}"; then ok "Oracle coletado"; else erro "Modulo 02 falhou durante a coleta"; MODULOS_FALHARAM+=("02_coleta_oracle.sh(execucao)"); COLETA_INCOMPLETA=1; fi
    fi
  fi
  if [ -n "$SQL_USER" ]; then
    if dl 03_coleta_sqlserver_linux.sh; then
      if bash "$TMP/03_coleta_sqlserver_linux.sh" "localhost,1433" "$SQL_USER"; then ok "SQL Server coletado"; else erro "Modulo SQL Server falhou durante a coleta"; MODULOS_FALHARAM+=("03_coleta_sqlserver_linux.sh(execucao)"); COLETA_INCOMPLETA=1; fi
    fi
  fi
  if [ "$HYP_ON" = "1" ]; then
    if dl 07_coleta_hypervisor_linux.sh; then
      if bash "$TMP/07_coleta_hypervisor_linux.sh"; then ok "Hypervisor coletado"; else erro "Modulo Hypervisor falhou durante a coleta"; MODULOS_FALHARAM+=("07_coleta_hypervisor_linux.sh(execucao)"); COLETA_INCOMPLETA=1; fi
    fi
  fi
  [ "$VEEAM_ON" = "1" ] && { echo "## Veeam Agent Linux"; veeamconfig job list 2>&1; veeamconfig session list 2>&1 | tail -30; } > veeam_agent_linux.txt
else
  { echo "## CONTEXTO DA ESTACAO DE COLETA - NAO APLICAVEL A POLITICA DO CLIENTE"
    echo "## Host: $FQDN | Papel: $PAPEL | Coletado em $(date '+%d/%m/%Y %H:%M')"
    echo "## Este host e ferramenta da WiseDB. Cron, discos e bases locais NAO pertencem ao cliente."
    echo; echo "Profiles OCI presentes (apenas nomes, para rastreabilidade):"
    printf '  - %s\n' ${OCI_PROF[@]+"${OCI_PROF[@]}"}
  } > contexto_estacao_NAO_DO_CLIENTE.txt
  ok "Coleta local suprimida; contexto da estacao registrado em arquivo separado"
fi
if [ -n "$OCI_SEL_PROF" ]; then
  info "Coleta OCI iniciada. Agora inclui IPs das instancias, volume groups, block volumes,"
  info "Recovery Service, backup config dos DB Systems, replicacao de bucket e verificacao"
  info "cross-region. Em tenancies grandes pode levar varios minutos; aguarde sem interromper."
  dl 05_coleta_oci.sh && bash "$TMP/05_coleta_oci.sh" --profile "$OCI_SEL_PROF" \
     ${OCI_SEL_REG:+--region "$OCI_SEL_REG"} --tenancy "$OCI_SEL_TEN" \
     --obj-limit "${WISEDB_OBJ_LIMIT:-50}" && ok "OCI coletado (tenancy do cliente)"
fi
# Registro explicito do nivel de privilegio da coleta. Entra no resultado_final e
# permite a quem le a politica saber se o cron de sistema foi de fato auditado.
{ echo "## NIVEL DE PRIVILEGIO DESTA COLETA"
  echo "## Usuario ....: $(whoami)"
  echo "## sudo usado .: $([ "$WISEDB_SUDO" = "1" ] && echo 'SIM' || echo 'NAO')"
  if [ "$WISEDB_SUDO" != "1" ]; then
    echo "## [PENDENCIA] Sem sudo: /etc/crontab, /etc/cron.d e dbcli nao foram lidos."
    echo "## [PENDENCIA] Pode existir job de backup sob root fora desta coleta, e o"
    echo "## [PENDENCIA] agendador do backup fisico em DB System/ODA fica como INFERIDO."
  fi
  echo "## Profundidade: listagem=$WISEDB_LIST_DEPTH niveis, dumps=$WISEDB_DUMP_DEPTH niveis"
  echo "## Fallback SSL usado: $([ "$SSL_FALLBACK_USADO" = "1" ] && echo SIM || echo NAO)"
  echo "## Coleta incompleta: $([ "$COLETA_INCOMPLETA" = "1" ] && echo SIM || echo NAO)"
  if [ ${#MODULOS_FALHARAM[@]} -gt 0 ]; then echo "## Modulos com falha: ${MODULOS_FALHARAM[*]}"; fi
} > "$WORK/nivel_privilegio_coleta.txt"
cd "$ORIG_DIR"
export WISEDB_SSL_FALLBACK_USED="$SSL_FALLBACK_USADO"
export WISEDB_COLETA_INCOMPLETA="$COLETA_INCOMPLETA"

#===============================================================================
# FASE 7 - SANITIZACAO, CONSOLIDACAO, SAIDA
#===============================================================================
titulo "FASE 7 - SANITIZACAO E CONSOLIDACAO"
find "$WORK" -type f \( -name "*.txt" -o -name "*.log" -o -name "*.json" \) -print0 |
while IFS= read -r -d '' f; do
  sed -i -E \
    -e 's/((password|passwd|pwd|secret|token|apikey|api_key|client_secret)[[:space:]]*[=:][[:space:]]*)[^[:space:]",]+/\1***REMOVIDO***/Ig' \
    -e 's/(identified[[:space:]]+by[[:space:]]+)[^[:space:];]+/\1***REMOVIDO***/Ig' \
    -e 's#(//[^/:@[:space:]]+:)[^@[:space:]]+(@)#\1***REMOVIDO***\2#g' \
    -e 's#([A-Za-z0-9_.$]+)/[^[:space:]/@"'"'"']{3,}@#\1/***REMOVIDO***@#g' "$f"
done
TMP_DIGEST="$WORK/.digest"; mkdir -p "$TMP_DIGEST"
[ -f "$TMP/wisedb_digest.py" ] && cp "$TMP/wisedb_digest.py" "$TMP_DIGEST/" 2>/dev/null
rm -rf "$TMP"

FINAL="$WORK/resultado_final.txt"
{
  echo "================================================================"
  echo " WISEDB - COLETA AUTOMATICA v$VERSAO"
  echo " Cliente ............: $CLIENTE"
  echo " Versao do script ...: $VERSAO"
  echo " Host da coleta .....: $FQDN (papel: $PAPEL)"
  echo " Coleta local .......: $([ "$COLETA_LOCAL" = "1" ] && echo "SIM - evidencia do cliente" || echo "NAO - host de ferramenta WiseDB")"
  echo " Instancia OCI local : ${VM_NOME_OCI:-n/a} | tenancy ${VM_TENANCY:-n/a}"
  echo " Profile OCI usado ..: ${OCI_SEL_PROF:-nenhum} | tenancy ${OCI_SEL_TEN:-n/a} | regiao ${OCI_SEL_REG:-n/a}"
  echo " Oracle no escopo ...: ${ORA_SEL[*]:-nenhum}"
  echo " Data da coleta .....: $(date '+%d/%m/%Y %H:%M %Z')"
  echo " RPO informado ......: $RPO"
  echo " RTO informado ......: $RTO"
  echo " Fora do escopo .....:"
  if [ ${#EXCL[@]} -eq 0 ]; then echo "   (nenhum)"; else
    for e in "${EXCL[@]}"; do echo "   - ${e%%|*} | Justificativa: ${e##*|}"; done; fi
  echo " Alertas do wizard ..:"
  if [ ${#ALERTAS[@]} -eq 0 ]; then echo "   (nenhum)"; else
    for a in "${ALERTAS[@]}"; do echo "   ! $a"; done; fi
  echo "================================================================"
  echo
  echo "NOTA PARA A IA: tratar como evidencia do cliente apenas o conteudo coletado"
  echo "com papel HOST_DO_CLIENTE ou HOST_MISTO, mais a coleta OCI do profile acima."
  echo "Arquivos com 'NAO_DO_CLIENTE' no nome sao contexto de ferramenta da WiseDB e"
  echo "nao devem alimentar a politica do cliente."
  find "$WORK" -type f -name "*.txt" ! -name "resultado_final.txt" | sort | while read -r f; do
    echo; echo "########## ARQUIVO: ${f#$WORK/} ##########"; cat "$f"
  done
} > "$FINAL"

python3 - "$WORK" "$CLIENTE" "$PAPEL" "$COLETA_LOCAL" "$OCI_SEL_PROF" "$OCI_SEL_TEN" "$VM_TENANCY" "$RPO" "$RTO" "$MD_CONFIAVEL" <<'PYEOF' 2>/dev/null || warn "python3 ausente: resultado.json nao gerado (o .txt esta completo)"
import json, os, sys, datetime
w, cli, papel, local, prof, ten, vmten, rpo, rto, mdok = sys.argv[1:11]
pend = []
if rpo.startswith("A combinar"): pend.append("RPO nao definido formalmente")
if rto.startswith("A combinar"): pend.append("RTO nao definido formalmente")
if local == "0": pend.append("Host de ferramenta: ambiente local do cliente deve ser coletado no servidor do cliente")
if not prof: pend.append("Coleta OCI nao executada nesta rodada")
if vmten and ten and vmten != ten and mdok == "1": pend.append("Tenancy da VM difere da do profile: escopo validado manualmente")
if os.environ.get("WISEDB_SSL_FALLBACK_USED") == "1": pend.append("TLS do GitHub exigiu fallback -k; recomenda-se corrigir a cadeia de CA do sistema")
if os.environ.get("WISEDB_COLETA_INCOMPLETA") == "1": pend.append("Coleta incompleta: um ou mais modulos/evidencias falharam")
doc = {
 "schema": "wisedb.coleta.backup/v2",
 "cliente": cli,
 "coleta": {"host": os.uname().nodename, "papel_host": papel,
            "coleta_local_habilitada": local == "1",
            "data": datetime.datetime.now().isoformat(timespec="minutes"),
            "script_versao": "3.3"},
 "oci": {"profile_usado": prof or None, "tenancy_profile": ten or None,
         "tenancy_reportada_pelo_metadata": vmten or None,
         "metadata_confiavel": mdok == "1",
         "tenancy_conferida": bool(prof and ten and (mdok == "0" or not vmten or vmten == ten))},
 "escopo": {"rpo_informado": rpo, "rto_informado": rto},
 "evidencias": sorted(os.path.relpath(os.path.join(r,f), w)
     for r,_,fs in os.walk(w) for f in fs if f.endswith((".txt",".log",".json")) and f != "resultado.json"),
 "pendencias": pend,
}
open(os.path.join(w,"resultado.json"),"w",encoding="utf-8").write(json.dumps(doc, ensure_ascii=False, indent=2))
print("resultado.json gerado")
PYEOF

# ---- RESUMO COMPACTO (o que voce cola na IA) -------------------------------
RESUMO="$WORK/RESUMO_${CLIENTE// /_}_${HOSTN}.txt"
if dl wisedb_digest.py 2>/dev/null; then
  python3 "$TMP_DIGEST/wisedb_digest.py" "$WORK" "$CLIENTE" "$PAPEL" "$RESUMO" \
    || warn "Digest nao gerado; use o resultado_final.txt"
  # o digest v2.1 resolve sozinho a subpasta coleta_<host>_<data>; se ainda assim
  # o resumo sair sem secao de evidencia, avisa em vez de entregar resumo vazio
  if [ -s "$RESUMO" ] && ! grep -qE '^== (SERVIDOR|ORACLE|SQL SERVER|OCI)' "$RESUMO"; then
    warn "RESUMO sem secoes de evidencia. Verifique $WORK e use o resultado_final.txt"
  fi
fi

titulo "RESUMO FINAL"
say "  Cliente ...........: ${NEG}$CLIENTE${R}"
say "  Papel do host .....: $PAPEL"
say "  Arquivos coletados : $(find "$WORK" -name '*.txt' | wc -l)"
say "  Alertas ...........: ${#ALERTAS[@]}"
info "Segredos remanescentes:"
grep -rniE 'password|passwd|secret|token' "$WORK" 2>/dev/null | grep -v 'REMOVIDO' | head -5 || info "  nenhum"
pergunta "Gerar pacote final? (S/n)" OKF "S"
if [ "${OKF^^}" != "N" ]; then
  PAC="$ORIG_DIR/wisedb_coleta_${CLIENTE// /_}_${HOSTN}_${DATA}.tar.gz"
  tar -czf "$PAC" -C "$ORIG_DIR" "$(basename "$WORK")"
  say ""
  if [ "$COLETA_INCOMPLETA" = "1" ]; then
    say "  ${AMAR}${NEG}PACOTE GERADO COM PENDENCIAS${R}"
  else
    say "  ${VERD}${NEG}PRONTO${R}"
  fi
  say "  Pacote completo ..: $PAC"
  if [ "$SSL_FALLBACK_USADO" = "1" ]; then
    say "  ${AMAR}Aviso SSL .........: o GitHub exigiu fallback -k; corrija a CA do SO quando possivel${R}"
  fi
  if [ ${#MODULOS_FALHARAM[@]} -gt 0 ]; then
    say "  ${AMAR}Modulos com falha : ${MODULOS_FALHARAM[*]}${R}"
  fi
  if [ -s "$RESUMO" ]; then
    say "  ${LAR}${NEG}COLE ISTO NA IA${R}: $RESUMO  ${DIM}($(wc -l < "$RESUMO") linhas)${R}"
    say "  Ver com ..........: ${DIM}cat \"$RESUMO\"${R}"
    say "  Bruto completo ...: $FINAL ${DIM}(so se a IA pedir detalhe)${R}"
  else
    say "  Para a IA ........: $FINAL"
  fi
else
  info "Pacote nao gerado. Arquivos em $WORK"
fi