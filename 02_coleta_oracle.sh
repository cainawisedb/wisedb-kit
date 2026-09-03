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
#            Diretorios extras de dump (opcional, separados por ":"):
#              WISEDB_DUMP_DIRS="/u02/Backup:/dados/dump" bash 02_coleta_oracle.sh
# SAIDA    : ./coleta_<hostname>_<data>/02_oracle/
#
# Versao 1.1 (setembro/2026)
#   [CORRIGIDO] Nivel 0 x nivel 1 agora vem de v$backup_datafile.incremental_level.
#               Antes era inferido por limiar fixo de 100 GB, o que classificava
#               nivel 0 comprimido (COMPRESSED BACKUPSET) como nivel 1.
#   [CORRIGIDO] Autobackup de controlfile: v$backup_piece_details nao possui
#               AUTOBACKUP_DATE (gerava ORA-00904). Passa a usar v$backup_piece
#               e, como prova independente, LIST BACKUP OF CONTROLFILE no RMAN.
#   [CORRIGIDO] Destinos de archive via v$archive_dest, sem o ruido das dezenas
#               de log_archive_dest_NN vazios que o SHOW PARAMETER trazia.
#   [CORRIGIDO] Descoberta de logs/dumps de Data Pump deixa de usar 3 caminhos
#               fixos. Varre diretorios do DBA_DIRECTORIES, mounts de dados e
#               lista fixa, e escreve marcador [SEM EVIDENCIA] quando nada for
#               achado, para nao confundir "nao coletado" com "nao existe".
#   [NOVO]      Detalhe operacional das falhas (v$rman_status) e output do RMAN
#               da falha mais recente (v$rman_output), que aponta a causa raiz.
#   [NOVO]      Jobs de Data Pump registrados no banco (dba_datapump_jobs).
#   [CORRIGIDO] Arquivos de saida sao truncados no inicio; reexecutar a coleta
#               no mesmo dia nao concatena mais o conteudo anterior.
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
  : > "${F}_sql.txt"    # trunca: reexecucao no mesmo dia nao duplica evidencia
  : > "${F}_rman.txt"
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
col destino for a45
col alvo for a10
select dest_id, destination destino, status, target alvo, binding
from v$archive_dest where destination is not null order by dest_id;
select round(space_used/1024/1024/1024,2) fra_usado_gb,
       round(space_limit/1024/1024/1024,2) fra_limite_gb,
       round(space_used/decode(space_limit,0,null,space_limit)*100,1) pct
from v$recovery_file_dest;
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
prompt ### RMAN - NIVEL 0 x NIVEL 1 (por dia, via v$backup_datafile)
col dia for a12
select to_char(trunc(completion_time),'DD/MM DY') dia,
       incremental_level nivel,
       count(*) datafiles,
       round(sum(blocks*block_size)/1024/1024/1024,2) gb
from v$backup_datafile
where completion_time > sysdate-35 and incremental_level is not null
group by trunc(completion_time), incremental_level
order by trunc(completion_time) desc, incremental_level;
prompt ### RMAN - FALHAS (v$rman_backup_job_details, ultimos 35 dias)
select to_char(start_time,'DD/MM/YYYY HH24:MI') inicio, input_type, status
from v$rman_backup_job_details
where start_time > sysdate-35 and status not like 'COMPLETED%' order by start_time desc fetch first 15 rows only;
prompt ### RMAN - FALHAS (v$rman_status, detalhe operacional)
col operacao for a28
col objeto for a14
col device for a10
select to_char(start_time,'DD/MM HH24:MI') inicio, operation operacao,
       object_type objeto, status, output_device_type device
from v$rman_status
where start_time > sysdate-35 and status like '%FAILED%'
order by start_time desc fetch first 20 rows only;
prompt ### RMAN - OUTPUT DA FALHA MAIS RECENTE (causa raiz)
col output for a110
select output from v$rman_output
where session_key = (select max(session_key) from v$rman_status
                     where status like '%FAILED%' and start_time > sysdate-35)
order by recid fetch first 40 rows only;
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
from v$backup_piece
where autobackup_date is not null and completion_time > sysdate-35 and status='A';
prompt ### DIRECTORIES nao padrao (destinos de expdp)
col directory_path for a70
select directory_name, directory_path from dba_directories
where directory_path not like '%/dbhome%' and directory_path not like '/u01/app/oracle' order by 1;
prompt ### DATAPUMP - JOBS REGISTRADOS NO BANCO
col owner_name for a18
col job_name for a30
col operation for a10
col job_mode for a10
select owner_name, job_name, operation, job_mode, state
from dba_datapump_jobs order by 1,2;
prompt ### JOBS DBMS_SCHEDULER de backup
col job_name for a40
col repeat_interval for a45
select owner||'.'||job_name job_name, enabled, state, repeat_interval
from dba_scheduler_jobs
where upper(job_name) like '%BKP%' or upper(job_name) like '%BACKUP%' or upper(job_name) like '%EXP%';
exit
EOF

  #--- Configuracao e catalogo RMAN (somente SHOW/LIST/REPORT) -----------------
  rman target / >> "${F}_rman.txt" 2>&1 <<'EOF'
SHOW ALL;
SHOW ENCRYPTION ALGORITHM;
REPORT NEED BACKUP;
REPORT UNRECOVERABLE;
LIST BACKUP OF CONTROLFILE COMPLETED AFTER 'SYSDATE-8';
exit
EOF

done

#--- Evidencia de backup logico (Data Pump) ------------------------------------
# Monta a lista de diretorios candidatos em vez de usar caminhos fixos:
#   1) WISEDB_DUMP_DIRS (separado por ":")
#   2) DIRECTORY_PATH do DBA_DIRECTORIES ja coletado nos *_sql.txt
#   3) mounts de dados do df que pareçam area de dump/backup
#   4) lista fixa de caminhos historicamente usados pela WiseDB
EXP="$OUT/expdp_logs_recentes.txt"
: > "$EXP"

CAND=()
if [ -n "${WISEDB_DUMP_DIRS:-}" ]; then
  IFS=':' read -r -a EXTRA <<< "$WISEDB_DUMP_DIRS"
  CAND+=("${EXTRA[@]}")
fi
while IFS= read -r p; do
  [ -n "$p" ] && CAND+=("$p")
done < <(grep -hoE '(^|[[:space:]])/[A-Za-z0-9._/-]{3,}' "$OUT"/*_sql.txt 2>/dev/null |
         tr -d ' ' | grep -Ei 'dump|dmp|backup|bkp|expdp|logs?$' | sort -u)
while IFS= read -r p; do
  [ -n "$p" ] && CAND+=("$p")
done < <(df -P 2>/dev/null | awk 'NR>1 {print $6}' | grep -E '^/(u0[0-9]|[Bb]ackup|bkp|dados|dump)' | sort -u)
CAND+=(/u01/Dumps /u01/expdp /u02 /u02/Backup /u02/Backup_Logico /u03/app/oracle/backup \
       /backup /Backup /bkp /dump /WiseDb/scripts/logs)

# Dedup preservando ordem
DIRS=()
for d in "${CAND[@]}"; do
  [ -d "$d" ] || continue
  dup=0
  for e in "${DIRS[@]:-}"; do [ "$e" = "$d" ] && dup=1 && break; done
  [ "$dup" = "0" ] && DIRS+=("$d")
done

{
  echo "################ EVIDENCIA DE BACKUP LOGICO (Data Pump) ################"
  echo "## Diretorios varridos (maxdepth 3):"
  if [ ${#DIRS[@]} -eq 0 ]; then
    echo "##   (nenhum diretorio candidato existe neste host)"
  else
    for d in "${DIRS[@]}"; do echo "##   $d"; done
  fi
  echo
} >> "$EXP"

ACHOU=0
if [ ${#DIRS[@]} -gt 0 ]; then
  {
    echo "----- DUMPS E LOGS COM MENOS DE 8 DIAS -----"
    for d in "${DIRS[@]}"; do
      find "$d" -maxdepth 3 -type f \
        \( -name "*.dmp" -o -name "*.dmp.gz" -o -name "*.dmp.tar.gz" -o -name "*.log" \) \
        -mtime -8 -printf '%TY-%Tm-%Td %TH:%TM %10s  %p\n' 2>/dev/null
    done | sort -u | tail -60
    echo
    echo "----- 15 DUMPS MAIS RECENTES, SEM LIMITE DE IDADE (mostra ha quanto tempo nao ha dump) -----"
    for d in "${DIRS[@]}"; do
      find "$d" -maxdepth 3 -type f \
        \( -name "*.dmp" -o -name "*.dmp.gz" -o -name "*.dmp.tar.gz" \) \
        -printf '%TY-%Tm-%Td %TH:%TM %10s  %p\n' 2>/dev/null
    done | sort -u | tail -15
    echo
    echo "----- TAIL DOS LOGS DE EXPDP COM MENOS DE 8 DIAS -----"
    for d in "${DIRS[@]}"; do
      find "$d" -maxdepth 3 -type f -name "*.log" -mtime -8 2>/dev/null
    done | sort -u | head -12 | while read -r lg; do
      if grep -qiE 'Export:|expdp|Dump file set' "$lg" 2>/dev/null; then
        echo "----- $lg -----"
        tail -25 "$lg"
        echo
      fi
    done
  } >> "$EXP" 2>&1

  for d in "${DIRS[@]}"; do
    if find "$d" -maxdepth 3 -type f \( -name "*.dmp*" -o -name "*.log" \) -mtime -8 2>/dev/null | grep -q .; then
      ACHOU=1; break
    fi
  done
fi

if [ "$ACHOU" = "0" ]; then
  {
    echo "[SEM EVIDENCIA] Nenhum dump ou log com mtime inferior a 8 dias nos diretorios acima."
    echo "[SEM EVIDENCIA] Isto NAO prova que o backup logico nao existe: pode estar em"
    echo "[SEM EVIDENCIA] diretorio nao varrido. Reexecute informando o caminho real:"
    echo "[SEM EVIDENCIA]   WISEDB_DUMP_DIRS=\"/caminho/do/dump\" bash 02_coleta_oracle.sh $*"
  } >> "$EXP"
fi

echo "Coleta Oracle concluida em $OUT. Revise antes de enviar."
