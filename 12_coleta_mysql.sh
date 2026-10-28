#!/bin/bash
#===============================================================================
# 12_coleta_mysql.sh - WiseDB | Kit de Coleta para Politica de Backup
# v1.0.1 (outubro/2026): em terminal web/PAM (senhasegura) o ENTER do usuario
#   chegava como CR+LF e o LF que sobrava respondia a senha em branco. Agora o
#   buffer do terminal e descartado entre as perguntas e o CR e removido.
# v1.0 (outubro/2026)
#
# OBJETIVO : Coletar, no MySQL/MariaDB local, o que a politica precisa:
#            versao, bancos e tamanho (e tabelas MyISAM, que nao tem backup
#            consistente com --single-transaction), log binario (PITR) e sua
#            janela, replicacao e atraso, Galera, criptografia, eventos, e
#            evidencia de backups (mysqldump/mariadb-dump/mydumper e
#            xtrabackup/mariabackup via xtrabackup_info) em disco.
# RISCO    : Zero. Somente SELECT/SHOW, find e stat. Nada e alterado.
# EXECUCAO : bash 12_coleta_mysql.sh
#            Autenticacao, nesta ordem:
#              1) WISEDB_MY_USER definido: senha pedida uma vez (ou MYSQL_PWD
#                 ja exportado) e mantida so na variavel do processo;
#              2) root com unix_socket / ~/.my.cnf (padrao MariaDB/Ubuntu);
#              3) sudo -n mysql (WISEDB_SUDO=1);
#              4) ~/.my.cnf do usuario atual; sem isso, pergunta usuario e senha.
#            Opcionais:
#              WISEDB_MY_SOCKET=/var/lib/mysql/mysql.sock  ou  WISEDB_MY_HOST/WISEDB_MY_PORT
#              WISEDB_DUMP_DIRS="/backup/mysql:/dump"     WISEDB_DUMP_DEPTH=5
# SAIDA    : ./coleta_<hostname>_<data>/12_mysql/
#              mysql_sql.txt            consultas da instancia
#              ferramentas_backup.txt   ferramentas e metadados de xtrabackup/mariabackup
#              dumps_recentes.txt       evidencia de backup em disco
#===============================================================================
set -uo pipefail

HOSTN=$(hostname -s 2>/dev/null || hostname)
OUT="./coleta_${HOSTN}_$(date +%Y%m%d)/12_mysql"
mkdir -p "$OUT"
DUMP_DEPTH="${WISEDB_DUMP_DEPTH:-5}"
EU=$(whoami)
TOUT=""; command -v timeout >/dev/null 2>&1 && TOUT="timeout 300"
SUDO_OK=0
if [ "${WISEDB_SUDO:-0}" = "1" ] && command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then SUDO_OK=1; fi
log(){ echo "[$(date +%H:%M:%S)] $*" >&2; }

MASKF=$(mktemp "${TMPDIR:-/tmp}/wisedb_mymask.XXXXXX") || exit 1
trap 'rm -f "$MASKF"' EXIT
cat > "$MASKF" <<'SEDEOF'
s/(([A-Za-z0-9_.-]*(password|passwd|pwd|senha|secret|token|passphrase|pass_phrase|cipher[-_]?pass|credential|api_?key|access_?key|key_id|keyid|private_?key|key))["']?[[:space:]]*[=:][[:space:]]*)("[^"]*"|'[^']*'|[^[:space:]",;]+)/\1***REMOVIDO***/Ig
s/(--?(password|passwd|pwd|senha|token|secret)[[:space:]]+)("[^"]*"|'[^']*'|[^-[:space:]][^[:space:]]*)/\1***REMOVIDO***/Ig
s/(identified[[:space:]]+by[[:space:]]+)("[^"]*"|[^[:space:];]+)/\1***REMOVIDO***/Ig
s#(//[^/:@[:space:]]+:)[^@[:space:]]+(@)#\1***REMOVIDO***\2#g
s#([A-Za-z0-9_.$]+)/[^[:space:]/@"'*]{2,}@#\1/***REMOVIDO***@#g
s#([A-Za-z0-9_.$]+)/[^[:space:]/@"'*]{2,}([[:space:]]+as[[:space:]]+sys)#\1/***REMOVIDO***\2#Ig
s#((connect|conn)[[:space:]]+((target|auxiliary|catalog)[[:space:]]+)?["']?[A-Za-z0-9_.$]+)/[^[:space:]@"']+#\1/***REMOVIDO***#Ig
s#((^|[[:space:]])(target|auxiliary|catalog)([[:space:]]+|[[:space:]]*=[[:space:]]*)["']?[A-Za-z0-9_.$]+)/[^[:space:]@"']+#\1/***REMOVIDO***#Ig
s#((sqlplus|sqlldr|expdp|impdp|exp|imp|dgmgrl)([[:space:]]+-[A-Za-z]+)*[[:space:]]+["']?[A-Za-z0-9_.$]+)/[^[:space:]@"']+#\1/***REMOVIDO***#g
s/(sqlcmd[^|;]*[[:space:]]-P[[:space:]]*)("[^"]*"|'[^']*'|[^[:space:]-][^[:space:]]*)/\1***REMOVIDO***/g
s/([[:space:]]-P[[:space:]]+)("[^"]*"|'[^']*'|[^[:space:]-][^[:space:]]*)/\1***REMOVIDO***/g
s/((mysql|mysqldump|mysqladmin|mysqlpump|mysqlcheck|mysqlbinlog|mariadb|mariadb-dump|mariadb-admin|mariabackup|xtrabackup|innobackupex|mydumper|myloader)[^|;]*[[:space:]]-p)("[^"]*"|'[^']*'|[^[:space:]"'-][^[:space:]]*)/\1***REMOVIDO***/g
s/(Bearer[[:space:]]+)[A-Za-z0-9._~+\/=-]{8,}/\1***REMOVIDO***/Ig
s/(AKIA|ASIA)[0-9A-Z]{16}/\1***REMOVIDO***/g
SEDEOF
mask(){ sed -E -f "$MASKF"; }

MYSQL=$(command -v mysql 2>/dev/null || command -v mariadb 2>/dev/null)
if [ -z "$MYSQL" ]; then
  echo "[ERRO] cliente mysql/mariadb nao encontrado no PATH." | tee "$OUT/ERRO_cliente_ausente.txt" >&2
  exit 1
fi

# Destino da conexao: socket ou host/porta explicitos; senao o padrao do cliente.
declare -a DEST=()
[ -n "${WISEDB_MY_SOCKET:-}" ] && DEST+=(--socket="$WISEDB_MY_SOCKET")
[ -n "${WISEDB_MY_HOST:-}" ] && DEST+=(--host="$WISEDB_MY_HOST" --protocol=TCP)
[ -n "${WISEDB_MY_PORT:-}" ] && DEST+=(--port="$WISEDB_MY_PORT")

#--------------------------- forma de conexao -----------------------------------
declare -a PRE=() USR=()
MODO_CON=""
testa(){ ${PRE[@]+"${PRE[@]}"} "$MYSQL" ${DEST[@]+"${DEST[@]}"} ${USR[@]+"${USR[@]}"} --connect-timeout=10 -N -B -e "SELECT 1" >/dev/null 2>&1; }
# Descarta o que sobrou no terminal (LF do CR+LF de terminal web/PAM).
limpa_tty(){ local _c _n=0; while [ "$_n" -lt 4096 ] && IFS= read -rsn1 -t 0.25 _c < /dev/tty 2>/dev/null; do _n=$((_n+1)); done; return 0; }
pede_senha(){ # pede_senha <usuario>
  if [ -z "${MYSQL_PWD:-}" ] && { : > /dev/tty; } 2>/dev/null; then
    printf 'Senha do MySQL/MariaDB para "%s": ' "$1" > /dev/tty
    limpa_tty; IFS= read -rs MYSQL_PWD < /dev/tty; echo > /dev/tty
    MYSQL_PWD="${MYSQL_PWD%$'\r'}"
  fi
  [ -n "${MYSQL_PWD:-}" ] && export MYSQL_PWD
}
if [ -n "${WISEDB_MY_USER:-}" ]; then
  USR=(--user="$WISEDB_MY_USER"); pede_senha "$WISEDB_MY_USER"; MODO_CON="usuario informado ($WISEDB_MY_USER)"
elif [ "$(id -u)" = "0" ] && testa; then
  MODO_CON="root (unix_socket ou /root/.my.cnf)"
elif [ "$SUDO_OK" = "1" ] && { PRE=(sudo -n); testa; }; then
  MODO_CON="sudo -n (unix_socket do root)"
else
  PRE=()
  if testa; then
    MODO_CON="usuario atual $EU (~/.my.cnf ou unix_socket)"
  elif { : > /dev/tty; } 2>/dev/null; then
    printf 'Usuario de LEITURA do MySQL/MariaDB (ENTER para pular): ' > /dev/tty
    limpa_tty; IFS= read -r MU < /dev/tty; MU="${MU%$'\r'}"; limpa_tty
    if [ -n "$MU" ]; then USR=(--user="$MU"); pede_senha "$MU"; MODO_CON="usuario informado ($MU)"; fi
  fi
fi
[ -z "$MODO_CON" ] && MODO_CON="sem credencial valida"

q(){ # q "titulo" "sql"  (saida em tabela)
  { echo "### $1"
    $TOUT ${PRE[@]+"${PRE[@]}"} "$MYSQL" ${DEST[@]+"${DEST[@]}"} ${USR[@]+"${USR[@]}"} --connect-timeout=10 -t -e "$2" 2>&1
    echo; } >> "$F"
}
qv(){ ${PRE[@]+"${PRE[@]}"} "$MYSQL" ${DEST[@]+"${DEST[@]}"} ${USR[@]+"${USR[@]}"} --connect-timeout=10 -N -B -e "$1" 2>/dev/null; }

F="$OUT/mysql_sql.txt"
{
  echo "################################################################"
  echo "## MYSQL / MARIADB - instancia local"
  echo "## Coletado em: $(date '+%d/%m/%Y %H:%M:%S %Z') | Host: $HOSTN | Usuario: $EU"
  echo "## Conexao: $MODO_CON ${DEST[*]:-(socket padrao do cliente)}"
  echo "## Processos mysqld/mariadbd neste host:"
  ps -eo user,pid,args 2>/dev/null | grep -E '(mysqld|mariadbd)( |$)' | grep -v grep | sed 's/^/##   /' | mask
  echo "################################################################"
} > "$F"

VER=$(qv "SELECT VERSION()")
if [ -z "$VER" ]; then
  {
    echo "[ERRO] Sem conexao ao MySQL/MariaDB local."
    echo "[ERRO] Detalhe:"
    ${PRE[@]+"${PRE[@]}"} "$MYSQL" ${DEST[@]+"${DEST[@]}"} ${USR[@]+"${USR[@]}"} --connect-timeout=10 -e "SELECT 1" 2>&1 | head -3
    echo "[PENDENTE] Reexecutar como root, com WISEDB_SUDO=1 ou com WISEDB_MY_USER=<usuario de leitura>"
    echo "[PENDENTE] (privilegios minimos: PROCESS, REPLICATION CLIENT, SELECT em information_schema)."
  } >> "$F"
  CONECTOU=0
else
  CONECTOU=1
  log "MySQL/MariaDB $VER | conexao: $MODO_CON"
  q "IDENTIFICACAO" "SELECT VERSION() AS versao, @@version_comment AS distribuicao, @@hostname AS host, @@port AS porta, @@datadir AS datadir, @@read_only AS read_only"
  q "CONFIGURACAO DE LOG BINARIO E DURABILIDADE" "SHOW GLOBAL VARIABLES WHERE Variable_name IN ('log_bin','log_bin_basename','binlog_format','expire_logs_days','binlog_expire_logs_seconds','max_binlog_size','sync_binlog','gtid_mode','gtid_strict_mode','server_id','innodb_flush_log_at_trx_commit','log_slave_updates','log_replica_updates','read_only','super_read_only','innodb_file_per_table','event_scheduler')"
  q "BANCOS E TAMANHO (GB) E TABELAS MYISAM" "SELECT table_schema AS banco, ROUND(SUM(data_length+index_length)/1024/1024/1024,2) AS gb, COUNT(*) AS tabelas, SUM(CASE WHEN engine='MyISAM' THEN 1 ELSE 0 END) AS myisam, SUM(CASE WHEN engine='InnoDB' THEN 1 ELSE 0 END) AS innodb FROM information_schema.tables WHERE table_schema NOT IN ('information_schema','performance_schema','sys','mysql') AND table_type='BASE TABLE' GROUP BY table_schema ORDER BY gb DESC"
  q "TAMANHO TOTAL (GB)" "SELECT ROUND(SUM(data_length+index_length)/1024/1024/1024,2) AS total_gb FROM information_schema.tables"

  # Janela de PITR: primeiro e ultimo binlog ainda presentes.
  {
    echo "### LOGS BINARIOS PRESENTES (janela de recuperacao ponto no tempo)"
    BL=$(qv "SHOW BINARY LOGS")
    if [ -z "$BL" ]; then
      echo "Sem logs binarios (log_bin=OFF) ou sem privilegio REPLICATION CLIENT para listar."
    else
      echo "Quantidade: $(printf '%s\n' "$BL" | grep -c .)"
      echo "Primeiro: $(printf '%s\n' "$BL" | head -1 | awk '{print $1, $2" bytes"}')"
      echo "Ultimo  : $(printf '%s\n' "$BL" | tail -1 | awk '{print $1, $2" bytes"}')"
      echo "Total GB: $(printf '%s\n' "$BL" | awk '{s+=$2} END{printf "%.2f", s/1024/1024/1024}')"
      BD=$(qv "SELECT @@log_bin_basename")
      if [ -n "$BD" ]; then
        primeiro=$(printf '%s\n' "$BL" | head -1 | awk '{print $1}')
        if [ -r "$(dirname "$BD")/$primeiro" ]; then
          echo "Data do binlog mais antigo: $(stat -c '%y' "$(dirname "$BD")/$primeiro" 2>/dev/null | cut -c1-16)"
        elif [ "$SUDO_OK" = "1" ]; then
          echo "Data do binlog mais antigo: $(sudo -n stat -c '%y' "$(dirname "$BD")/$primeiro" 2>/dev/null | cut -c1-16)"
        fi
      fi
    fi
    echo
  } >> "$F"

  # Replicacao: SHOW REPLICA STATUS (MySQL 8.0.22+/MariaDB 10.5+), senao SLAVE.
  {
    echo "### REPLICACAO (esta instancia como replica)"
    RS=$( { ${PRE[@]+"${PRE[@]}"} "$MYSQL" ${DEST[@]+"${DEST[@]}"} ${USR[@]+"${USR[@]}"} --connect-timeout=10 -e "SHOW REPLICA STATUS\\G" 2>/dev/null ||
            ${PRE[@]+"${PRE[@]}"} "$MYSQL" ${DEST[@]+"${DEST[@]}"} ${USR[@]+"${USR[@]}"} --connect-timeout=10 -e "SHOW SLAVE STATUS\\G" 2>/dev/null; } )
    if [ -z "$RS" ]; then echo "Esta instancia nao e replica (ou sem privilegio para consultar)."
    else printf '%s\n' "$RS" | grep -E '(Master|Source)_Host|(Master|Source)_Port|(Slave|Replica)_(IO|SQL)_Running:|Seconds_Behind_(Master|Source)|Last_(IO_|SQL_)?Error:|Channel_Name|Using_Gtid|Auto_Position' ; fi
    echo
    echo "### REPLICAS CONECTADAS A ESTA INSTANCIA"
    qv "SELECT COUNT(*) FROM information_schema.processlist WHERE command IN ('Binlog Dump','Binlog Dump GTID')" | sed 's/^/Conexoes de replica (Binlog Dump): /'
    echo
  } >> "$F"

  q "GALERA / CLUSTER (vazio se nao for cluster)" "SHOW GLOBAL STATUS WHERE Variable_name IN ('wsrep_cluster_size','wsrep_cluster_status','wsrep_local_state_comment','wsrep_ready')"
  q "CRIPTOGRAFIA EM REPOUSO" "SHOW GLOBAL VARIABLES WHERE Variable_name IN ('innodb_encrypt_tables','innodb_encrypt_log','encrypt_binlog','default_table_encryption','binlog_encryption','innodb_redo_log_encrypt','have_ssl','require_secure_transport')"
  q "EVENTOS AGENDADOS (EVENT SCHEDULER)" "SELECT event_schema, event_name, status, interval_value, interval_field, last_executed FROM information_schema.events ORDER BY 1,2"
  echo "### FIM" >> "$F"
fi

#--------------------------- ferramentas de backup ------------------------------
FER="$OUT/ferramentas_backup.txt"
{
  echo "################ FERRAMENTAS DE BACKUP MYSQL/MARIADB INSTALADAS ################"
  for t in mysqldump mariadb-dump mysqlpump mydumper xtrabackup mariabackup innobackupex mysqlbackup mysqlsh; do
    if command -v "$t" >/dev/null 2>&1; then
      v=$("$t" --version 2>&1 | grep -v '^\s*$' | head -1)
      echo "$t: $(command -v "$t") ${v:+| $v}"
    fi
  done
} > "$FER"

#--------------------------- diretorios candidatos -------------------------------
CAND=()
if [ -n "${WISEDB_DUMP_DIRS:-}" ]; then IFS=':' read -r -a EXTRA <<< "$WISEDB_DUMP_DIRS"; CAND+=(${EXTRA[@]+"${EXTRA[@]}"}); fi
CRONTXT=$( { crontab -l 2>/dev/null; cat /etc/crontab 2>/dev/null; cat /etc/cron.d/* 2>/dev/null
             for u in mysql root; do
               [ "$u" = "$EU" ] && continue
               if [ "$(id -u)" = "0" ]; then crontab -l -u "$u" 2>/dev/null
               elif [ "$SUDO_OK" = "1" ]; then sudo -n crontab -l -u "$u" 2>/dev/null; fi
             done; } 2>/dev/null)
for s in $(printf '%s\n' "$CRONTXT" | grep -oE '/[A-Za-z0-9._/-]+\.(sh|bash|ksh|py)' | sort -u); do
  [ -r "$s" ] && grep -qiE 'mysqldump|mariadb-dump|mydumper|xtrabackup|mariabackup|mysqlpump|mysqlsh' "$s" 2>/dev/null && CRONTXT="$CRONTXT
$(cat "$s" 2>/dev/null)"
done
while IFS= read -r p; do
  [ -n "$p" ] || continue
  d="$p"; [ -d "$d" ] || d=$(dirname "$p")
  [ -d "$d" ] && CAND+=("$d")
done < <(printf '%s\n' "$CRONTXT" | grep -iE 'mysqldump|mariadb-dump|mydumper|xtrabackup|mariabackup|backup|bkp|dump' |
         grep -oE '/[A-Za-z0-9._/-]{3,}' | grep -viE '\.(sh|bash|ksh|py|cnf|conf)$|^/(usr|bin|sbin|etc|dev|proc|sys)/' | sort -u)
while IFS= read -r p; do [ -n "$p" ] && CAND+=("$p"); done < <(df -P 2>/dev/null | awk 'NR>1{print $6}' | grep -iE '^/(u0[0-9]|backup|bkp|dados|dump|bck)' | sort -u)
CAND+=(/backup /Backup /bkp /dump /var/backups /var/lib/mysql-backup /var/lib/mysql-files /opt/backup /home/mysql)
DIRS=()
for d in "${CAND[@]}"; do
  d="${d%/}"; [ -n "$d" ] && [ -d "$d" ] || continue
  printf '%s\n' ${DIRS[@]+"${DIRS[@]}"} | grep -qxF "$d" || DIRS+=("$d")
done
DATADIR=$( [ "$CONECTOU" = "1" ] && qv "SELECT @@datadir" ); DATADIR="${DATADIR%/}"
PODA=(-path /proc -o -path /sys)
[ -n "$DATADIR" ] && PODA+=(-o -path "$DATADIR")

lista_dumps(){ # lista_dumps <dir> [mtime]
  local d="$1" mt="${2:-}"
  local -a idade=(); [ -n "$mt" ] && idade=(-mtime "-$mt")
  timeout 240 find "$d" -maxdepth "$DUMP_DEPTH" \( "${PODA[@]}" \) -prune -o -type f ${idade[@]+"${idade[@]}"} \
    \( -name 'xtrabackup_info' -o -name 'mariadb_backup_info' -o -name 'xtrabackup_checkpoints' -o -name '*.xbstream' \
       -o -name '*.xbstream.*' -o -name '*.qp' -o -name 'metadata' \
       -o \( \( -name '*.sql' -o -name '*.sql.gz' -o -name '*.sql.bz2' -o -name '*.sql.xz' -o -name '*.sql.zst' \
               -o -name '*.dump' -o -name '*.dump.gz' -o -name '*.tar.gz' -o -name '*.tgz' \) -size +100k \) \) \
    -printf '%TY-%Tm-%Td %TH:%TM %12s  %p\n' 2>/dev/null
}

#--------------------------- metadados de backup fisico --------------------------
{
  echo
  echo "### BACKUPS FISICOS (xtrabackup_info / mariadb_backup_info mais recentes)"
  ACH=0
  for d in ${DIRS[@]+"${DIRS[@]}"}; do
    timeout 240 find "$d" -maxdepth "$DUMP_DEPTH" \( "${PODA[@]}" \) -prune -o -type f \
      \( -name 'xtrabackup_info' -o -name 'mariadb_backup_info' \) -printf '%T@ %p\n' 2>/dev/null
  done | sort -rn | awk '!v[$2]++' | head -6 | while read -r _t f; do
    echo "-- $f"
    grep -E '^(tool_name|tool_version|server_version|start_time|end_time|incremental|format|compressed|encrypted|innodb_from_lsn|innodb_to_lsn|partial|tool_command)' "$f" 2>/dev/null
  done
  for d in ${DIRS[@]+"${DIRS[@]}"}; do
    timeout 120 find "$d" -maxdepth "$DUMP_DEPTH" -type f \( -name 'xtrabackup_info' -o -name 'mariadb_backup_info' \) 2>/dev/null | grep -q . && ACH=1
  done
  [ "$ACH" = "0" ] && echo "(nenhum xtrabackup_info/mariadb_backup_info nos diretorios varridos)"
} 2>&1 | mask >> "$FER"

EXP="$OUT/dumps_recentes.txt"
{
  echo "################ EVIDENCIA DE BACKUP MYSQL/MARIADB EM DISCO ################"
  echo "## Diretorios varridos (maxdepth $DUMP_DEPTH):"
  if [ ${#DIRS[@]} -eq 0 ]; then echo "##   (nenhum diretorio candidato existe neste host)"
  else for d in "${DIRS[@]}"; do echo "##   $d"; done; fi
  echo "## Linhas de cron com ferramenta de backup MySQL/MariaDB:"
  printf '%s\n' "$CRONTXT" | grep -E '^[^#]*(mysqldump|mariadb-dump|mydumper|xtrabackup|mariabackup|mysqlpump|mysqlsh)' | head -15 | sed 's/^/##   /'
  echo
  echo "----- ARTEFATOS COM MENOS DE 8 DIAS -----"
  for d in ${DIRS[@]+"${DIRS[@]}"}; do lista_dumps "$d" 8; done | sort -u | tail -60
  echo
  echo "----- 15 ARTEFATOS MAIS RECENTES, SEM LIMITE DE IDADE -----"
  for d in ${DIRS[@]+"${DIRS[@]}"}; do lista_dumps "$d"; done | sort -u | tail -15
  echo
  echo "----- TAIL DOS LOGS DE BACKUP COM MENOS DE 8 DIAS -----"
  for d in ${DIRS[@]+"${DIRS[@]}"}; do
    timeout 120 find "$d" -maxdepth "$DUMP_DEPTH" -type f \( -name '*.log' -o -name '*.out' \) -mtime -8 2>/dev/null
  done | sort -u | head -40 | while read -r lg; do
    if grep -qiE 'mysqldump|mariadb-dump|mydumper|xtrabackup|mariabackup|completed OK' "$lg" 2>/dev/null; then
      echo "----- $lg -----"; tail -20 "$lg"; echo
    fi
  done
} 2>&1 | mask > "$EXP"
ACHOU=0
for d in ${DIRS[@]+"${DIRS[@]}"}; do lista_dumps "$d" 8 | grep -q . && { ACHOU=1; break; }; done
if [ "$ACHOU" = "0" ]; then
  {
    echo "[SEM EVIDENCIA] Nenhum dump ou backup fisico com mtime inferior a 8 dias nos diretorios acima."
    echo "[SEM EVIDENCIA] Isto NAO prova que o backup nao existe: pode estar em diretorio nao varrido,"
    echo "[SEM EVIDENCIA] em outro host ou em object storage. Reexecute com o caminho real:"
    echo "[SEM EVIDENCIA]   WISEDB_DUMP_DIRS=\"/caminho/do/dump\" bash 12_coleta_mysql.sh"
  } >> "$EXP"
fi

# Base de ferramenta de monitoramento: nao e evidencia do cliente por padrao.
if [ "$CONECTOU" = "1" ] && qv "SHOW DATABASES" | grep -qxiE 'zabbix|zabbix_proxy|glpi|grafana'; then
  echo "[INFO] Base de ferramenta (zabbix/glpi/grafana) presente: confirmar se pertence ao escopo da politica do cliente." >> "$F"
fi
for f in "$OUT"/*.txt; do [ -f "$f" ] && { mask < "$f" > "$f.m" && mv "$f.m" "$f"; }; done
unset MYSQL_PWD
log "Coleta MySQL/MariaDB concluida em $OUT"
[ "$CONECTOU" = "1" ] || { echo "[ERRO] MySQL/MariaDB sem conexao: somente evidencia em disco coletada." >&2; exit 2; }
exit 0
