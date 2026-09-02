#!/bin/bash
#===============================================================================
# 02_coleta_oracle.sh - WiseDB | Kit de Coleta para Politica de Backup
#
# OBJETIVO : Coletar, por instancia Oracle, a configuracao do RMAN, o
#            historico real de execucoes (35 dias), modo de log, DBID e
#            evidencias de backups logicos (Data Pump).
# RISCO    : Zero. Somente SELECT, SHOW e LIST. Nenhum comando altera o banco.
# EXECUCAO : Como usuario oracle, com ambiente do Grid/DB configurado.
#              bash 02_coleta_oracle.sh            -> percorre /etc/oratab
#              bash 02_coleta_oracle.sh SID1 SID2  -> apenas os SIDs informados
# SAIDA    : ./coleta_<hostname>_<data>/02_oracle/
#===============================================================================
set -uo pipefail

HOSTN=$(hostname -s 2>/dev/null || hostname)
OUT="./coleta_${HOSTN}_$(date +%Y%m%d)/02_oracle"
mkdir -p "$OUT"

# Lista de SIDs: argumentos ou /etc/oratab (ignora linhas comentadas e agent)
if [ $# -gt 0 ]; then
  SIDS=("$@")
else
  mapfile -t SIDS < <(grep -Ev '^\s*(#|$)' /etc/oratab 2>/dev/null | cut -d: -f1 | grep -Ev '^(\+ASM|agent|-MGMTDB)')
fi
if [ ${#SIDS[@]} -eq 0 ]; then
  echo "[ERRO] Nenhum SID encontrado. Informe os SIDs como argumento."; exit 1
fi
echo "SIDs a coletar: ${SIDS[*]}"

for SID in "${SIDS[@]}"; do
  export ORACLE_SID="$SID"
  export ORAENV_ASK=NO
  . oraenv >/dev/null 2>&1 || echo "[AVISO] oraenv falhou para $SID; usando ambiente atual"
  F="$OUT/${SID}"
  echo "=== Coletando $SID ==="

  #--- Consultas SQL (somente SELECT) -----------------------------------------
  sqlplus -S / as sysdba >> "${F}_sql.txt" 2>&1 <<'EOF'
set pages 200 lines 220 trimspool on
col name for a15
col value for a60
prompt ################ IDENTIFICACAO DO BANCO ################
select name, dbid, database_role, log_mode, open_mode, created from v$database;
select banner_full from v$version where rownum=1;
select instance_name, host_name, status, startup_time from v$instance;
prompt ################ TAMANHO DO BANCO (GB) ################
select round(sum(bytes)/1024/1024/1024,2) size_gb from dba_data_files;
prompt ################ FRA / DESTINOS DE ARCHIVE ################
show parameter db_recovery_file_dest
show parameter log_archive_dest_1
prompt ################ HISTORICO RMAN - ULTIMOS 35 DIAS ################
col input_type for a14
col status for a24
col inicio for a17
col fim for a17
select session_key, input_type, status,
       to_char(start_time,'DD/MM/YYYY HH24:MI') inicio,
       to_char(end_time,'DD/MM/YYYY HH24:MI') fim,
       round(input_bytes/1024/1024/1024,2)  input_gb,
       round(output_bytes/1024/1024/1024,2) output_gb,
       round(elapsed_seconds/60,1) min
from v$rman_backup_job_details
where start_time > sysdate-35
order by start_time;
prompt ################ ARCHIVELOG - FREQUENCIA REAL (7 DIAS) ################
select to_char(completion_time,'DD/MM') dia, count(*) qtd_archives
from v$archived_log where completion_time > sysdate-7
group by to_char(completion_time,'DD/MM') order by 1;
prompt ################ DIRECTORIES (destinos de expdp) ################
col directory_name for a25
col directory_path for a80
select directory_name, directory_path from dba_directories order by 1;
prompt ################ JOBS DBMS_SCHEDULER de backup (se houver) ################
col job_name for a35
col repeat_interval for a60
select owner||'.'||job_name job_name, enabled, state, repeat_interval
from dba_scheduler_jobs
where upper(job_name) like '%BKP%' or upper(job_name) like '%BACKUP%' or upper(job_name) like '%EXP%';
exit
EOF

  #--- Configuracao e catalogo RMAN (somente SHOW/LIST) -------------------------
  rman target / >> "${F}_rman.txt" 2>&1 <<'EOF'
SHOW ALL;
LIST BACKUP SUMMARY COMPLETED AFTER 'SYSDATE-15';
LIST BACKUP OF CONTROLFILE COMPLETED AFTER 'SYSDATE-15';
REPORT NEED BACKUP;
REPORT UNRECOVERABLE;
exit
EOF

done

#--- Logs recentes do Data Pump (evidencia de backup logico) --------------------
{
  echo "################ LOGS EXPDP RECENTES (ultimos 8 dias) ################"
  for d in /u02/Backup_Logico /u03/app/oracle/backup /backup; do
    [ -d "$d" ] || continue
    find "$d" -name "*.log" -mtime -8 2>/dev/null | while read -r lg; do
      echo "----- $lg -----"
      tail -25 "$lg"
      echo
    done
  done
} >> "$OUT/expdp_logs_recentes.txt" 2>&1

echo "Coleta Oracle concluida em $OUT. Revise antes de enviar."
