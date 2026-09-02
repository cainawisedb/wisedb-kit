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
set pages 200 lines 200 trimspool on feedback off
col name for a15
col value for a55
prompt ### IDENTIFICACAO
select name, dbid, database_role role, log_mode, open_mode, created from v$database;
select banner_full from v$version where rownum=1;
select instance_name, host_name, status, to_char(startup_time,'DD/MM/YYYY HH24:MI') startup from v$instance;
prompt ### PDBs (multitenant)
col pdb for a25
select name pdb, open_mode, restricted from v$pdbs order by name;
prompt ### TAMANHO REAL (CDB + PDBs, GB)
select round(sum(bytes)/1024/1024/1024,2) total_gb from cdb_data_files;
select con_id, round(sum(bytes)/1024/1024/1024,2) gb from cdb_data_files group by con_id order by 1;
prompt ### DESTINOS DE ARCHIVE / FRA
show parameter db_recovery_file_dest
show parameter log_archive_dest_1
prompt ### RMAN 35 DIAS - RESUMO AGREGADO POR TIPO
col input_type for a12
col primeiro for a16
col ultimo for a16
select input_type,
       count(*) execucoes,
       sum(case when status like 'COMPLETED%' then 1 else 0 end) ok,
       sum(case when status like '%FAILED%' then 1 else 0 end) falhas,
       to_char(min(start_time),'DD/MM HH24:MI') primeiro,
       to_char(max(start_time),'DD/MM HH24:MI') ultimo,
       round(avg(output_bytes)/1024/1024/1024,2) media_gb,
       round(max(elapsed_seconds)/60,1) max_min
from v$rman_backup_job_details where start_time > sysdate-35
group by input_type order by 1;
prompt ### RMAN 35 DIAS - HORARIO TIPICO POR TIPO
select input_type, to_char(start_time,'HH24') hora, count(*) qtd
from v$rman_backup_job_details where start_time > sysdate-35
group by input_type, to_char(start_time,'HH24') having count(*) > 2 order by 1,2;
prompt ### RMAN - NIVEL 0 x NIVEL 1 (DB INCR, ultimos 35 dias)
select to_char(start_time,'DD/MM DY HH24:MI') inicio,
       round(output_bytes/1024/1024/1024,2) output_gb,
       round(elapsed_seconds/60,1) min,
       case when output_bytes > 100*1024*1024*1024 then 'NIVEL 0 (full)' else 'Nivel 1 (incr)' end tipo
from v$rman_backup_job_details
where input_type='DB INCR' and start_time > sysdate-35 order by start_time desc;
prompt ### RMAN - FALHAS (ultimos 35 dias, detalhe)
select to_char(start_time,'DD/MM/YYYY HH24:MI') inicio, input_type, status
from v$rman_backup_job_details
where start_time > sysdate-35 and status not like 'COMPLETED%' order by start_time desc fetch first 15 rows only;
prompt ### ARCHIVELOG - VOLUME REAL POR DIA (7 DIAS)
select to_char(completion_time,'DD/MM') dia, count(*) qtd_archives,
       round(sum(blocks*block_size)/1024/1024/1024,1) gb
from v$archived_log where completion_time > sysdate-7
group by to_char(completion_time,'DD/MM') order by 1;
prompt ### ARCHIVELOG - MAIOR INTERVALO SEM ARCHIVE (7 DIAS, indica RPO real)
select round(max(gap)*24*60) maior_gap_min from (
  select completion_time - lag(completion_time) over (order by completion_time) gap
  from v$archived_log where completion_time > sysdate-7);
prompt ### BACKUPSETS EM DISCO x SBT (onde as copias realmente estao)
select device_type, count(*) pecas, round(sum(bytes)/1024/1024/1024,2) gb,
       to_char(max(completion_time),'DD/MM HH24:MI') mais_recente
from v$backup_piece_details where completion_time > sysdate-35
group by device_type order by 1;
prompt ### CONTROLFILE AUTOBACKUP (evidencia do catalogo de metadados)
select count(*) autobackups_35d, to_char(max(completion_time),'DD/MM/YYYY HH24:MI') ultimo
from v$backup_piece_details where autobackup_date is not null and completion_time > sysdate-35;
prompt ### DIRECTORIES nao padrao (destinos de expdp)
col directory_path for a70
select directory_name, directory_path from dba_directories
where directory_path not like '%/dbhome%' and directory_path not like '/u01/app/oracle' order by 1;
prompt ### JOBS DBMS_SCHEDULER de backup
col job_name for a40
col repeat_interval for a45
select owner||'.'||job_name job_name, enabled, state, repeat_interval
from dba_scheduler_jobs
where upper(job_name) like '%BKP%' or upper(job_name) like '%BACKUP%' or upper(job_name) like '%EXP%';
exit
EOF

  #--- Configuracao e catalogo RMAN (somente SHOW/LIST) -------------------------
  rman target / >> "${F}_rman.txt" 2>&1 <<'EOF'
SHOW ALL;
SHOW ENCRYPTION ALGORITHM;
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
