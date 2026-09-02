#!/bin/bash
#===============================================================================
# 03_coleta_sqlserver_linux.sh - WiseDB | Kit de Coleta para Politica de Backup
#
# OBJETIVO : Coletar do SQL Server (on Linux) o historico REAL de backups
#            (msdb.dbo.backupset, 15 dias), recovery model por base, destinos
#            fisicos e jobs do SQL Server Agent.
# RISCO    : Zero. Somente SELECT em msdb/master.
# EXECUCAO : bash 03_coleta_sqlserver_linux.sh <servidor,porta> <usuario_leitura>
#            A senha sera solicitada interativamente pelo sqlcmd (nao passe -P,
#            nao grave senha em arquivo). Use um usuario com permissao de
#            leitura em msdb (ex.: role db_datareader em msdb).
# SAIDA    : ./coleta_<hostname>_<data>/03_sqlserver/
#===============================================================================
set -uo pipefail
SRV="${1:?Uso: $0 <servidor,porta> <usuario>}"
USR="${2:?Uso: $0 <servidor,porta> <usuario>}"

HOSTN=$(hostname -s 2>/dev/null || hostname)
OUT="./coleta_${HOSTN}_$(date +%Y%m%d)/03_sqlserver"
mkdir -p "$OUT"
SQLCMD=$(command -v sqlcmd || echo /opt/mssql-tools18/bin/sqlcmd)

Q(){ # Q "titulo" "query"
  echo "################ $1 ################" >> "$OUT/sqlserver_evidencias.txt"
  "$SQLCMD" -S "$SRV" -U "$USR" -C -W -s ' | ' -Q "SET NOCOUNT ON; $2" >> "$OUT/sqlserver_evidencias.txt" 2>&1
  echo >> "$OUT/sqlserver_evidencias.txt"
}

Q "VERSAO" "SELECT @@SERVERNAME AS servidor, @@VERSION AS versao;"

Q "BASES E RECOVERY MODEL" "
SELECT name, state_desc, recovery_model_desc,
       CONVERT(varchar(16), create_date, 120) AS criada_em
FROM sys.databases ORDER BY name;"

Q "HISTORICO DE BACKUPS - ULTIMOS 15 DIAS (msdb.backupset)" "
SELECT bs.database_name,
       CASE bs.type WHEN 'D' THEN 'FULL' WHEN 'I' THEN 'DIFERENCIAL'
                    WHEN 'L' THEN 'TRANSACTION LOG' ELSE bs.type END AS tipo,
       CONVERT(varchar(16), bs.backup_start_date, 120) AS inicio,
       CONVERT(varchar(16), bs.backup_finish_date, 120) AS fim,
       CAST(bs.backup_size/1024.0/1024/1024 AS decimal(12,2)) AS tamanho_gb,
       bmf.physical_device_name AS destino
FROM msdb.dbo.backupset bs
JOIN msdb.dbo.backupmediafamily bmf ON bmf.media_set_id = bs.media_set_id
WHERE bs.backup_start_date >= DATEADD(DAY,-15,GETDATE())
ORDER BY bs.backup_start_date;"

Q "RESUMO: FREQUENCIA POR BASE/TIPO (15 DIAS)" "
SELECT database_name,
       CASE type WHEN 'D' THEN 'FULL' WHEN 'I' THEN 'DIFF' WHEN 'L' THEN 'LOG' ELSE type END AS tipo,
       COUNT(*) AS execucoes,
       CONVERT(varchar(16), MIN(backup_start_date), 120) AS primeira,
       CONVERT(varchar(16), MAX(backup_start_date), 120) AS ultima
FROM msdb.dbo.backupset
WHERE backup_start_date >= DATEADD(DAY,-15,GETDATE())
GROUP BY database_name, type ORDER BY database_name, tipo;"

Q "BASES SEM BACKUP FULL NOS ULTIMOS 15 DIAS (gap de cobertura)" "
SELECT d.name
FROM sys.databases d
LEFT JOIN msdb.dbo.backupset bs
  ON bs.database_name = d.name AND bs.type='D'
 AND bs.backup_start_date >= DATEADD(DAY,-15,GETDATE())
WHERE d.name NOT IN ('tempdb') AND bs.database_name IS NULL;"

Q "JOBS DO SQL SERVER AGENT (se em uso)" "
SELECT j.name AS job, j.enabled,
       s.name AS schedule,
       CAST(s.active_start_time AS varchar(10)) AS hora_hhmmss,
       s.freq_type
FROM msdb.dbo.sysjobs j
LEFT JOIN msdb.dbo.sysjobschedules js ON js.job_id=j.job_id
LEFT JOIN msdb.dbo.sysschedules s ON s.schedule_id=js.schedule_id
ORDER BY j.name;"

echo "Coleta SQL Server concluida em $OUT. Revise antes de enviar."
echo "Obs: rode tambem o 01_coleta_linux_geral.sh neste servidor para capturar o crontab que dispara os backups."
