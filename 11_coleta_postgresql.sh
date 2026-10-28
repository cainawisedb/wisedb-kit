#!/bin/bash
#===============================================================================
# 11_coleta_postgresql.sh - WiseDB | Kit de Coleta para Politica de Backup
# v1.0.1 (outubro/2026): senha lida de terminal web/PAM vinha com CR no final.
# v1.0 (outubro/2026)
#
# OBJETIVO : Coletar, por cluster PostgreSQL local, o que a politica precisa:
#            versao, bancos e tamanho, WAL/archive (PITR), estatisticas do
#            archiver, replicacao/standby e atraso, slots, checksums,
#            ferramentas de backup (pgBackRest, Barman, WAL-G, pg_probackup),
#            agendamentos (pg_cron) e evidencia de dumps (pg_dump/pg_dumpall)
#            e basebackups recentes em disco.
# RISCO    : Zero. Somente SELECT/SHOW no catalogo, "pgbackrest info",
#            "barman list-*", find e stat. Nada e alterado.
# EXECUCAO : Como postgres (autenticacao peer), ou como root/sudo (o script
#            usa runuser/sudo -u postgres). Outros usuarios:
#              WISEDB_PG_CONN="host=10.0.0.5 user=leitura" bash 11_coleta_postgresql.sh
#            (a senha e pedida uma vez e fica apenas em PGPASSWORD do processo)
#            Opcionais:
#              WISEDB_PG_PORTS="5432 5433"        clusters a consultar
#              WISEDB_DUMP_DIRS="/backup/pg:/dump" diretorios extras de dump
#              WISEDB_DUMP_DEPTH=5                 profundidade da varredura
#              WISEDB_SUDO=1                       permite sudo -n -u postgres
# SAIDA    : ./coleta_<hostname>_<data>/11_postgresql/
#              <porta>_sql.txt           consultas do cluster
#              ferramentas_backup.txt    pgBackRest/Barman/WAL-G e configuracao
#              dumps_recentes.txt        evidencia de backup logico e basebackup
#===============================================================================
set -uo pipefail

HOSTN=$(hostname -s 2>/dev/null || hostname)
OUT="./coleta_${HOSTN}_$(date +%Y%m%d)/11_postgresql"
mkdir -p "$OUT"
DUMP_DEPTH="${WISEDB_DUMP_DEPTH:-5}"
EU=$(whoami)
TOUT=""; command -v timeout >/dev/null 2>&1 && TOUT="timeout 300"

SUDO_OK=0
if [ "${WISEDB_SUDO:-0}" = "1" ] && command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then SUDO_OK=1; fi

log(){ echo "[$(date +%H:%M:%S)] $*" >&2; }

# Mascara unica do kit (igual a do orquestrador v3.8).
MASKF=$(mktemp "${TMPDIR:-/tmp}/wisedb_pgmask.XXXXXX") || exit 1
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

if ! command -v psql >/dev/null 2>&1; then
  for c in /usr/pgsql-*/bin/psql /usr/lib/postgresql/*/bin/psql /opt/PostgreSQL/*/bin/psql; do
    [ -x "$c" ] && { PATH="$(dirname "$c"):$PATH"; export PATH; break; }
  done
fi
if ! command -v psql >/dev/null 2>&1; then
  echo "[ERRO] psql nao encontrado (PATH, /usr/pgsql-*, /usr/lib/postgresql/*, /opt/PostgreSQL/*)." | tee "$OUT/ERRO_psql_ausente.txt" >&2
  exit 1
fi

#--------------------------- forma de conexao -----------------------------------
# PG_RUN: prefixo que executa psql como o dono do cluster (peer) quando possivel.
PG_RUN=(); MODO_CON=""
if [ -n "${WISEDB_PG_CONN:-}" ]; then
  MODO_CON="conninfo informado (WISEDB_PG_CONN)"
  if [ -z "${PGPASSWORD:-}" ] && { : > /dev/tty; } 2>/dev/null; then
    printf 'Senha do PostgreSQL para "%s" (ENTER se nao houver): ' "$WISEDB_PG_CONN" > /dev/tty
    IFS= read -rs PGPASSWORD < /dev/tty; echo > /dev/tty
    PGPASSWORD="${PGPASSWORD%$'\r'}"
    [ -n "$PGPASSWORD" ] && export PGPASSWORD
  fi
elif [ "$EU" = "postgres" ]; then
  MODO_CON="usuario postgres (peer)"
elif [ "$(id -u)" = "0" ]; then
  if command -v runuser >/dev/null 2>&1; then PG_RUN=(runuser -u postgres --); else PG_RUN=(su postgres -s /bin/sh -c); fi
  MODO_CON="root -> postgres (peer)"
elif [ "$SUDO_OK" = "1" ] && sudo -n -u postgres true 2>/dev/null; then
  PG_RUN=(sudo -n -u postgres)
  MODO_CON="sudo -u postgres (peer)"
else
  MODO_CON="usuario atual $EU (sem privilegio de postgres; depende de .pgpass/trust)"
fi

# Executa psql com stdin (SQL) e argumentos. Com "su -c" o comando vira string.
pg(){ # pg <socketdir|host> <porta> [banco]
  local h="$1" p="$2" db="${3:-postgres}"
  if [ -n "${WISEDB_PG_CONN:-}" ]; then
    (cd /tmp && $TOUT psql -X -w -P pager=off "$WISEDB_PG_CONN port=$p dbname=$db" 2>&1)
  elif [ "${PG_RUN[0]:-}" = "su" ]; then
    (cd /tmp && $TOUT su postgres -s /bin/sh -c "psql -X -w -P pager=off -h '$h' -p '$p' -d '$db'" 2>&1)
  else
    (cd /tmp && $TOUT ${PG_RUN[@]+"${PG_RUN[@]}"} psql -X -w -P pager=off -h "$h" -p "$p" -d "$db" 2>&1)
  fi
}
pgv(){ # valor unico, sem cabecalho
  local h="$1" p="$2"; shift 2
  local sql="$*"
  if [ -n "${WISEDB_PG_CONN:-}" ]; then
    (cd /tmp && psql -X -w -At "$WISEDB_PG_CONN port=$p dbname=postgres" -c "$sql" 2>/dev/null)
  elif [ "${PG_RUN[0]:-}" = "su" ]; then
    (cd /tmp && su postgres -s /bin/sh -c "psql -X -w -At -h '$h' -p '$p' -d postgres -c \"$sql\"" 2>/dev/null)
  else
    (cd /tmp && ${PG_RUN[@]+"${PG_RUN[@]}"} psql -X -w -At -h "$h" -p "$p" -d postgres -c "$sql" 2>/dev/null)
  fi
}
como_postgres(){ # executa um comando como o dono do cluster (para pgbackrest info)
  if [ "$EU" = "postgres" ]; then (cd /tmp && $TOUT "$@" 2>&1)
  elif [ "${PG_RUN[0]:-}" = "su" ]; then (cd /tmp && $TOUT su postgres -s /bin/sh -c "$*" 2>&1)
  elif [ ${#PG_RUN[@]} -gt 0 ]; then (cd /tmp && $TOUT "${PG_RUN[@]}" "$@" 2>&1)
  else (cd /tmp && $TOUT "$@" 2>&1); fi
}

#--------------------------- descoberta dos clusters ----------------------------
# Lista "dir_socket|porta". Ordem: variavel, pg_lsclusters (Debian/Ubuntu),
# sockets .s.PGSQL.<porta>, e por ultimo a porta padrao.
declare -a ALVOS=()
add_alvo(){ local a="$1|$2"; printf '%s\n' ${ALVOS[@]+"${ALVOS[@]}"} | grep -qxF "$a" || ALVOS+=("$a"); }
sockdir(){ local p="$1" d
  for d in /var/run/postgresql /run/postgresql /tmp; do [ -S "$d/.s.PGSQL.$p" ] && { echo "$d"; return; }; done
  echo "localhost"
}
if [ -n "${WISEDB_PG_CONN:-}" ]; then
  for p in ${WISEDB_PG_PORTS:-5432}; do add_alvo "conninfo" "$p"; done
elif [ -n "${WISEDB_PG_PORTS:-}" ]; then
  for p in $WISEDB_PG_PORTS; do add_alvo "$(sockdir "$p")" "$p"; done
else
  if command -v pg_lsclusters >/dev/null 2>&1; then
    while read -r _v _c p st _r; do
      case "$st" in online*) add_alvo "$(sockdir "$p")" "$p";; esac
    done < <(pg_lsclusters -h 2>/dev/null)
  fi
  for s in /var/run/postgresql/.s.PGSQL.* /run/postgresql/.s.PGSQL.* /tmp/.s.PGSQL.*; do
    [ -S "$s" ] || continue
    p="${s##*.}"; case "$p" in ''|*[!0-9]*) continue;; esac
    printf '%s\n' ${ALVOS[@]+"${ALVOS[@]}"} | grep -q "|$p$" || add_alvo "$(dirname "$s")" "$p"
  done
  [ ${#ALVOS[@]} -eq 0 ] && add_alvo "$(sockdir 5432)" "5432"
fi
log "PostgreSQL: ${#ALVOS[@]} cluster(s) a consultar | conexao: $MODO_CON"

#--------------------------- consultas por cluster ------------------------------
FALHAS=0; DATADIRS=(); ARCHCMDS=()
for alvo in "${ALVOS[@]}"; do
  H="${alvo%%|*}"; P="${alvo##*|}"
  F="$OUT/${P}_sql.txt"
  log "Consultando cluster da porta $P ($H)"
  VNUM=$(pgv "$H" "$P" "select current_setting('server_version_num')" | tr -dc '0-9')
  {
    echo "################################################################"
    echo "## POSTGRESQL - cluster porta $P | socket/host: $H"
    echo "## Coletado em: $(date '+%d/%m/%Y %H:%M:%S %Z') | Host: $HOSTN | Usuario: $EU"
    echo "## Conexao: $MODO_CON"
    echo "################################################################"
  } > "$F"
  if [ -z "$VNUM" ]; then
    {
      echo "[ERRO] Sem conexao ao cluster da porta $P."
      echo "[ERRO] Detalhe da tentativa:"
      echo "select 1;" | pg "$H" "$P" | head -5
      echo "[PENDENTE] Reexecutar como postgres, como root, com WISEDB_SUDO=1 ou com"
      echo "[PENDENTE] WISEDB_PG_CONN=\"host=... user=...\" (usuario com pg_read_all_settings/pg_monitor)."
    } >> "$F"
    FALHAS=$((FALHAS+1)); continue
  fi
  echo "server_version_num: $VNUM" >> "$F"

  # Bloco portavel (9.2+)
  pg "$H" "$P" >> "$F" <<'SQL_EOF'
\echo ### IDENTIFICACAO
select version();
select current_setting('server_version') versao, inet_server_port() porta,
       pg_is_in_recovery() em_recuperacao, pg_postmaster_start_time() inicio_instancia;
\echo ### BANCOS E TAMANHO
select datname banco, pg_size_pretty(pg_database_size(datname)) tamanho,
       round(pg_database_size(datname)/1024.0/1024/1024,2) gb, datallowconn aceita_conexao
from pg_database where not datistemplate order by pg_database_size(datname) desc;
\echo ### TAMANHO TOTAL DO CLUSTER (GB)
select round(sum(pg_database_size(datname))/1024.0/1024/1024,2) total_gb from pg_database;
\echo ### CONFIGURACAO DE WAL, ARCHIVE E REPLICACAO
select name, setting, unit from pg_settings
where name in ('data_directory','wal_level','archive_mode','archive_command','archive_library',
               'archive_timeout','restore_command','recovery_target_timeline','max_wal_senders',
               'wal_keep_segments','wal_keep_size','max_wal_size','checkpoint_timeout',
               'hot_standby','primary_conninfo','primary_slot_name','synchronous_commit',
               'synchronous_standby_names','full_page_writes','fsync','log_directory',
               'data_checksums','ssl')
order by name;
\echo ### REPLICACAO - STANDBYS CONECTADOS A ESTE SERVIDOR
select client_addr, application_name, state, sync_state from pg_stat_replication;
\echo ### STANDBY - ATRASO DE APLICACAO (somente se este cluster for standby)
select pg_is_in_recovery() em_recuperacao,
       case when pg_is_in_recovery() then now() - pg_last_xact_replay_timestamp() end atraso_replay,
       case when pg_is_in_recovery() then pg_last_xact_replay_timestamp() end ultima_transacao_aplicada;
\echo ### EXTENSOES INSTALADAS (banco postgres)
select extname, extversion from pg_extension order by 1;
SQL_EOF

  # Blocos dependentes de versao
  if [ "${VNUM:-0}" -ge 90400 ]; then
    pg "$H" "$P" >> "$F" <<'SQL_EOF'
\echo ### ARCHIVER (pg_stat_archiver)
select archived_count arquivados, last_archived_wal ultimo_wal, last_archived_time ultimo_arquivamento,
       failed_count falhas, last_failed_wal wal_com_falha, last_failed_time ultima_falha, stats_reset desde
from pg_stat_archiver;
\echo ### SLOTS DE REPLICACAO (slot inativo retem WAL e enche o disco)
select slot_name, slot_type, database, active, restart_lsn from pg_replication_slots;
SQL_EOF
  fi
  if [ "${VNUM:-0}" -ge 90600 ]; then
    pg "$H" "$P" >> "$F" <<'SQL_EOF'
\echo ### STANDBY - RECEPTOR DE WAL (pg_stat_wal_receiver)
select status, last_msg_receipt_time ultima_mensagem, latest_end_time ultimo_wal_recebido, slot_name
from pg_stat_wal_receiver;
SQL_EOF
  fi
  if [ "${VNUM:-0}" -ge 100000 ]; then
    pg "$H" "$P" >> "$F" <<'SQL_EOF'
\echo ### REPLICACAO - ATRASO POR STANDBY (10+)
select application_name, client_addr, write_lag, flush_lag, replay_lag from pg_stat_replication;
SQL_EOF
  fi
  if [ "$(pgv "$H" "$P" "select count(*) from pg_extension where extname='pg_cron'")" = "1" ]; then
    pg "$H" "$P" >> "$F" <<'SQL_EOF'
\echo ### AGENDAMENTOS PG_CRON
select jobid, schedule, database, active, command from cron.job order by jobid;
SQL_EOF
  fi
  echo "### FIM" >> "$F"

  DD=$(pgv "$H" "$P" "select setting from pg_settings where name='data_directory'")
  [ -n "$DD" ] && DATADIRS+=("$DD")
  AC=$(pgv "$H" "$P" "select setting from pg_settings where name='archive_command'")
  [ -n "$AC" ] && ARCHCMDS+=("$AC")
  grep -qE '^### IDENTIFICACAO' "$F" || FALHAS=$((FALHAS+1))
done

#--------------------------- destino do archive (janela de PITR) ----------------
# archive_command tipico: cp %p /backup/wal/%f, rsync ... host:/dir/%f,
# pgbackrest archive-push %p, barman-wal-archive ..., wal-g wal-push %p.
ARQ="$OUT/archive_wal_destino.txt"
{
  echo "################ DESTINO DO ARCHIVE DE WAL (janela de recuperacao ponto no tempo) ################"
  if [ ${#ARCHCMDS[@]} -eq 0 ]; then
    echo "archive_command vazio ou nao legivel: sem archive de WAL configurado (ou sem permissao para ler)."
  fi
  for ac in ${ARCHCMDS[@]+"${ARCHCMDS[@]}"}; do
    echo "archive_command: $ac"
    case "$ac" in
      *pgbackrest*) echo "Ferramenta: pgBackRest (ver ferramentas_backup.txt)";;
      *barman*)     echo "Ferramenta: Barman (ver ferramentas_backup.txt)";;
      *wal-g*|*wal-e*) echo "Ferramenta: WAL-G/WAL-E (copia para object storage)";;
      *pg_probackup*) echo "Ferramenta: pg_probackup";;
      *rsync*|*scp*) echo "Copia para outro host via rsync/scp (verificar o destino no host remoto)";;
    esac
    for d in $(printf '%s\n' "$ac" | grep -oE '/[A-Za-z0-9._/-]+' | grep -v '%' | sort -u); do
      dir="$d"; [ -d "$dir" ] || dir=$(dirname "$d")
      [ -d "$dir" ] || continue
      case "$dir" in /|/bin|/usr|/usr/bin|/usr/local/bin) continue;; esac
      n=$(find "$dir" -maxdepth 1 -type f 2>/dev/null | wc -l)
      echo "-- Diretorio de archive local: $dir | arquivos: $n"
      echo "   mais antigo: $(find "$dir" -maxdepth 1 -type f -printf '%TY-%Tm-%Td %TH:%TM  %f\n' 2>/dev/null | sort | head -1)"
      echo "   mais recente: $(find "$dir" -maxdepth 1 -type f -printf '%TY-%Tm-%Td %TH:%TM  %f\n' 2>/dev/null | sort | tail -1)"
      echo "   uso: $(du -sh "$dir" 2>/dev/null | cut -f1)"
    done
  done
} | mask > "$ARQ"

#--------------------------- ferramentas de backup ------------------------------
FER="$OUT/ferramentas_backup.txt"
{
  echo "################ FERRAMENTAS DE BACKUP POSTGRESQL INSTALADAS ################"
  for t in pg_dump pg_dumpall pg_basebackup pgbackrest barman barman-cloud-backup wal-g wal-e pg_probackup; do
    if command -v "$t" >/dev/null 2>&1; then
      v=$("$t" --version 2>/dev/null | head -1)
      echo "$t: $(command -v "$t") ${v:+| $v}"
    fi
  done
  echo
  if command -v pgbackrest >/dev/null 2>&1; then
    echo "### PGBACKREST INFO (stanzas, backups full/diff/incr e janela de WAL)"
    como_postgres pgbackrest info | head -150
    echo
    echo "### PGBACKREST CONFIGURACAO (mascarada)"
    for c in /etc/pgbackrest.conf /etc/pgbackrest/pgbackrest.conf /etc/pgbackrest/conf.d/*.conf; do
      [ -f "$c" ] || continue
      echo "-- $c"
      if [ -r "$c" ]; then cat "$c"; elif [ "$SUDO_OK" = "1" ]; then sudo -n cat "$c" 2>/dev/null; else echo "(sem permissao de leitura)"; fi
    done
    echo
  fi
  if command -v barman >/dev/null 2>&1; then
    echo "### BARMAN (servidores e backups)"
    if [ "$(id -u)" = "0" ] && id barman >/dev/null 2>&1 && command -v runuser >/dev/null 2>&1; then
      (cd /tmp && $TOUT runuser -u barman -- barman list-servers 2>&1 | head -40)
      (cd /tmp && $TOUT runuser -u barman -- barman list-backup all 2>&1 | head -80)
    else
      (cd /tmp && $TOUT barman list-servers 2>&1 | head -40)
      (cd /tmp && $TOUT barman list-backup all 2>&1 | head -80)
    fi
    echo
  fi
  if command -v wal-g >/dev/null 2>&1 || command -v wal-e >/dev/null 2>&1; then
    echo "### WAL-G / WAL-E: arquivos de configuracao encontrados (somente nomes)"
    ls -la /etc/wal-g.d /etc/wal-e.d 2>/dev/null
    for hd in /var/lib/postgresql /var/lib/pgsql; do ls -la "$hd"/.walg.json 2>/dev/null; done
    echo "(backup-list exige as variaveis do envdir do archive_command; anexar 'wal-g backup-list' manualmente)"
    echo
  fi
  if command -v pg_probackup >/dev/null 2>&1; then
    echo "### PG_PROBACKUP: catalogos encontrados (pg_probackup.conf)"
    timeout 120 find / -xdev -maxdepth 6 -name pg_probackup.conf 2>/dev/null | head -10
    echo
  fi
} 2>&1 | mask > "$FER"

#--------------------------- evidencia de dumps e basebackups --------------------
EXP="$OUT/dumps_recentes.txt"
CAND=()
if [ -n "${WISEDB_DUMP_DIRS:-}" ]; then IFS=':' read -r -a EXTRA <<< "$WISEDB_DUMP_DIRS"; CAND+=(${EXTRA[@]+"${EXTRA[@]}"}); fi
# Diretorios citados nas linhas de cron (e nos scripts que elas chamam) que usam
# ferramentas de backup do PostgreSQL.
CRONTXT=$( { crontab -l 2>/dev/null; cat /etc/crontab 2>/dev/null; cat /etc/cron.d/* 2>/dev/null
             for u in postgres root; do
               [ "$u" = "$EU" ] && continue
               if [ "$(id -u)" = "0" ]; then crontab -l -u "$u" 2>/dev/null
               elif [ "$SUDO_OK" = "1" ]; then sudo -n crontab -l -u "$u" 2>/dev/null; fi
             done; } 2>/dev/null)
SCR=$(printf '%s\n' "$CRONTXT" | grep -oE '/[A-Za-z0-9._/-]+\.(sh|bash|ksh|py)' | sort -u)
for s in $SCR; do [ -r "$s" ] && grep -qiE 'pg_dump|pg_dumpall|pg_basebackup|pgbackrest|barman' "$s" 2>/dev/null && CRONTXT="$CRONTXT
$(cat "$s" 2>/dev/null)"; done
while IFS= read -r p; do
  [ -n "$p" ] || continue
  d="$p"; [ -d "$d" ] || d=$(dirname "$p")
  [ -d "$d" ] && CAND+=("$d")
done < <(printf '%s\n' "$CRONTXT" | grep -iE 'pg_dump|pg_dumpall|pg_basebackup|backup|bkp|dump' |
         grep -oE '/[A-Za-z0-9._/-]{3,}' | grep -viE '\.(sh|bash|ksh|py|conf)$|^/(usr|bin|sbin|etc|dev|proc|sys)/' | sort -u)
while IFS= read -r p; do [ -n "$p" ] && CAND+=("$p"); done < <(df -P 2>/dev/null | awk 'NR>1{print $6}' | grep -iE '^/(u0[0-9]|backup|bkp|dados|dump|pgbackup|bck)' | sort -u)
CAND+=(/backup /Backup /bkp /dump /var/backups /var/lib/postgresql /var/lib/pgsql /home/postgres /opt/backup)
DIRS=()
for d in "${CAND[@]}"; do
  d="${d%/}"; [ -n "$d" ] && [ -d "$d" ] || continue
  printf '%s\n' ${DIRS[@]+"${DIRS[@]}"} | grep -qxF "$d" || DIRS+=("$d")
done
# Poda: diretorios de dados do PostgreSQL (nunca varrer o PGDATA inteiro)
PODA=(-path /proc -o -path /sys -o -name 'pg_wal' -o -name 'pg_xlog' -o -name 'base' -o -name 'global' -o -name 'pg_tblspc')
for dd in ${DATADIRS[@]+"${DATADIRS[@]}"}; do PODA+=(-o -path "$dd"); done

lista_dumps(){ # lista_dumps <dir> [mtime]
  local d="$1" mt="${2:-}"
  local -a idade=(); [ -n "$mt" ] && idade=(-mtime "-$mt")
  timeout 240 find "$d" -maxdepth "$DUMP_DEPTH" \( "${PODA[@]}" \) -prune -o -type f ${idade[@]+"${idade[@]}"} \
    \( -name '*.dump' -o -name '*.backup' -o -name '*.pgdump' -o -name '*.pg_dump' -o -name '*.custom' \
       -o -name 'toc.dat' -o -name 'backup_manifest' -o -name 'backup_label' -o -name 'base.tar*' -o -name 'pg_wal.tar*' \
       -o \( \( -name '*.sql' -o -name '*.sql.gz' -o -name '*.sql.bz2' -o -name '*.sql.xz' -o -name '*.sql.zst' \
               -o -name '*.dump.gz' -o -name '*.tar.gz' -o -name '*.tgz' \) -size +100k \) \) \
    -printf '%TY-%Tm-%Td %TH:%TM %12s  %p\n' 2>/dev/null
}
{
  echo "################ EVIDENCIA DE BACKUP LOGICO (pg_dump) E BASEBACKUP ################"
  echo "## Diretorios varridos (maxdepth $DUMP_DEPTH):"
  if [ ${#DIRS[@]} -eq 0 ]; then echo "##   (nenhum diretorio candidato existe neste host)"
  else for d in "${DIRS[@]}"; do echo "##   $d"; done; fi
  echo "## Linhas de cron com ferramenta de backup PostgreSQL:"
  printf '%s\n' "$CRONTXT" | grep -E '^[^#]*(pg_dump|pg_dumpall|pg_basebackup|pgbackrest|barman)' | head -15 | sed 's/^/##   /'
  echo
  echo "----- DUMPS/BASEBACKUPS COM MENOS DE 8 DIAS -----"
  for d in ${DIRS[@]+"${DIRS[@]}"}; do lista_dumps "$d" 8; done | sort -u | tail -60
  echo
  echo "----- 15 ARTEFATOS MAIS RECENTES, SEM LIMITE DE IDADE (mostra ha quanto tempo nao ha dump) -----"
  for d in ${DIRS[@]+"${DIRS[@]}"}; do lista_dumps "$d"; done | sort -u | tail -15
  echo
  echo "----- TAIL DOS LOGS DE DUMP COM MENOS DE 8 DIAS -----"
  for d in ${DIRS[@]+"${DIRS[@]}"}; do
    timeout 120 find "$d" -maxdepth "$DUMP_DEPTH" -type f \( -name '*.log' -o -name '*.out' \) -mtime -8 2>/dev/null
  done | sort -u | head -40 | while read -r lg; do
    if grep -qiE 'pg_dump|pg_dumpall|pg_basebackup|pgbackrest' "$lg" 2>/dev/null; then
      echo "----- $lg -----"; tail -20 "$lg"; echo
    fi
  done
} 2>&1 | mask > "$EXP"
ACHOU=0
for d in ${DIRS[@]+"${DIRS[@]}"}; do lista_dumps "$d" 8 | grep -q . && { ACHOU=1; break; }; done
if [ "$ACHOU" = "0" ]; then
  {
    echo "[SEM EVIDENCIA] Nenhum dump/basebackup com mtime inferior a 8 dias nos diretorios acima."
    echo "[SEM EVIDENCIA] Isto NAO prova que o backup logico nao existe: pode estar em diretorio nao"
    echo "[SEM EVIDENCIA] varrido, em outro host ou em object storage. Reexecute com o caminho real:"
    echo "[SEM EVIDENCIA]   WISEDB_DUMP_DIRS=\"/caminho/do/dump\" bash 11_coleta_postgresql.sh"
  } >> "$EXP"
fi

# Mascara final de tudo que foi gravado (primary_conninfo, cron.job, archive_command)
for f in "$OUT"/*.txt; do [ -f "$f" ] && { mask < "$f" > "$f.m" && mv "$f.m" "$f"; }; done

log "Coleta PostgreSQL concluida em $OUT"
if [ "$FALHAS" -ge "${#ALVOS[@]}" ]; then echo "[ERRO] Nenhum cluster PostgreSQL consultado com sucesso." >&2; exit 2
elif [ "$FALHAS" -gt 0 ]; then echo "[AVISO] $FALHAS de ${#ALVOS[@]} cluster(s) sem consulta." >&2; exit 3; fi
exit 0
