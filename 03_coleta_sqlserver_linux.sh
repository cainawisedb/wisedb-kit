#!/bin/bash
#===============================================================================
# 03_coleta_sqlserver_linux.sh - WiseDB | Kit de Coleta para Politica de Backup
#
# OBJETIVO : Coletar do SQL Server (on Linux) o historico REAL de backups
#            (msdb.dbo.backupset, 15 dias), recovery model por base, destinos
#            fisicos e jobs do SQL Server Agent.
# RISCO    : Zero. Somente SELECT em msdb/master.
# EXECUCAO : bash 03_coleta_sqlserver_linux.sh <servidor,porta> <usuario_leitura>
#            A senha e solicitada UMA unica vez, lida do terminal e exportada
#            em SQLCMDPASSWORD apenas para os processos filhos do sqlcmd.
#            Nao passe -P e nao grave senha em arquivo. Use um usuario com
#            permissao de leitura em msdb (ex.: db_datareader em msdb).
#            Modo nao interativo: exporte SQLCMDPASSWORD antes de chamar.
# SAIDA    : ./coleta_<hostname>_<data>/03_sqlserver/
#
# Versao 1.2.1 (outubro/2026)
#   [CORRIGIDO] Senha lida de terminal web/PAM (senhasegura) vinha com CR no
#               final e o login falhava. CR removido.
#
# Versao 1.2 (outubro/2026)
#   [NOVO]      Ultimo backup por base e tipo (lacuna de log = RPO real), checksum,
#               backups danificados, copy_only, compressao, tipo de destino (VDI
#               indica ferramenta de terceiro), criptografia do backup, TDE e
#               backup dos certificados, historico de RESTORE (teste de
#               restauracao), ultimo CHECKDB e paginas suspeitas, Always On
#               (inclusive preferencia de backup), log shipping, mirroring e
#               resultado dos jobs do Agent. Blocos de versao nova usam SQL
#               dinamico guardado por COL_LENGTH/OBJECT_ID (2008 R2+).
#===============================================================================
set -uo pipefail
SRV="${1:?Uso: $0 <servidor,porta> <usuario>}"
USR="${2:?Uso: $0 <servidor,porta> <usuario>}"

HOSTN=$(hostname -s 2>/dev/null || hostname)
OUT="./coleta_${HOSTN}_$(date +%Y%m%d)/03_sqlserver"
mkdir -p "$OUT"
SQLCMD=$(command -v sqlcmd 2>/dev/null)
# mssql-tools nao entra no PATH de sessao nao interativa/sudo: tenta v18 e v17.
[ -z "$SQLCMD" ] && for c in /opt/mssql-tools18/bin/sqlcmd /opt/mssql-tools/bin/sqlcmd; do [ -x "$c" ] && { SQLCMD="$c"; break; }; done
SQLCMD="${SQLCMD:-/opt/mssql-tools18/bin/sqlcmd}"
FALHAS=0

# Progresso e prompts vao para o terminal real. Como Q() redireciona 2>&1 para o
# arquivo de evidencia, sem isto o operador ve a tela parada sem saber que o
# script esta aguardando digitacao.
exec 9>&2
TEM_TTY=0
if ( : > /dev/tty ) 2>/dev/null; then exec 9>/dev/tty; TEM_TTY=1; fi
diga(){ printf '%s\n' "$*" >&9; }

if [ ! -x "$SQLCMD" ]; then
  diga "ERRO: sqlcmd nao encontrado (PATH, /opt/mssql-tools18/bin, /opt/mssql-tools/bin). Instale mssql-tools18."
  exit 1
fi

if [ -z "${SQLCMDPASSWORD:-}" ]; then
  if [ "$TEM_TTY" = "1" ]; then
    printf '%s' "Senha de leitura do SQL Server ($USR): " >&9
    IFS= read -rs SQLCMDPASSWORD < /dev/tty
    SQLCMDPASSWORD="${SQLCMDPASSWORD%$'\r'}"
    diga ""
  else
    diga "ERRO: sem terminal para ler a senha. Exporte SQLCMDPASSWORD antes de executar."
    exit 1
  fi
fi
export SQLCMDPASSWORD

# Valida login antes das consultas: senha errada aqui retorna erro visivel, em
# vez de gravar seis blocos de falha dentro do arquivo de evidencia.
if ! "$SQLCMD" -S "$SRV" -U "$USR" -C -l 15 -Q "SET NOCOUNT ON; SELECT 1;" > "$OUT/.login_test" 2>&1; then
  diga "ERRO: falha de conexao/login em '$SRV' com o usuario '$USR'."
  sed -n '1,5p' "$OUT/.login_test" >&9 2>/dev/null || true
  rm -f "$OUT/.login_test"
  exit 1
fi
rm -f "$OUT/.login_test"
diga "Conexao validada em $SRV. Coletando evidencias..."

Q(){ # Q "titulo" "query"
  diga "  -> $1"
  echo "################ $1 ################" >> "$OUT/sqlserver_evidencias.txt"
  if ! "$SQLCMD" -S "$SRV" -U "$USR" -C -W -s ' | ' -Q "SET NOCOUNT ON; $2" >> "$OUT/sqlserver_evidencias.txt" 2>&1; then
    FALHAS=$((FALHAS+1))
    diga "     FALHA neste bloco. Detalhe em $OUT/sqlserver_evidencias.txt"
  fi
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

Q "ULTIMO BACKUP POR BASE E TIPO (RPO E LACUNA DE LOG)" "
SELECT d.name AS base, d.recovery_model_desc AS recovery,
 CONVERT(varchar(16), MAX(CASE WHEN b.type='D' THEN b.backup_finish_date END), 120) AS ultimo_full,
 CONVERT(varchar(16), MAX(CASE WHEN b.type='I' THEN b.backup_finish_date END), 120) AS ultimo_diff,
 CONVERT(varchar(16), MAX(CASE WHEN b.type='L' THEN b.backup_finish_date END), 120) AS ultimo_log,
 DATEDIFF(HOUR, MAX(CASE WHEN b.type IN ('D','I') THEN b.backup_finish_date END), GETDATE()) AS horas_desde_full_diff,
 DATEDIFF(MINUTE, MAX(CASE WHEN b.type='L' THEN b.backup_finish_date END), GETDATE()) AS min_desde_log
FROM sys.databases d LEFT JOIN msdb.dbo.backupset b ON b.database_name = d.name
WHERE d.name <> 'tempdb'
GROUP BY d.name, d.recovery_model_desc ORDER BY d.name;"

Q "QUALIDADE DOS BACKUPS - 15 DIAS (checksum, danificado, copy_only, compressao)" "
SELECT database_name AS base,
 CASE type WHEN 'D' THEN 'FULL' WHEN 'I' THEN 'DIFF' WHEN 'L' THEN 'LOG' ELSE type END AS tipo,
 COUNT(*) AS backups,
 SUM(CASE WHEN has_backup_checksums = 1 THEN 1 ELSE 0 END) AS com_checksum,
 SUM(CASE WHEN is_damaged = 1 THEN 1 ELSE 0 END) AS danificados,
 SUM(CASE WHEN is_copy_only = 1 THEN 1 ELSE 0 END) AS copy_only,
 CAST(SUM(backup_size)/1024.0/1024/1024 AS decimal(12,2)) AS gb,
 CAST(SUM(compressed_backup_size)/1024.0/1024/1024 AS decimal(12,2)) AS gb_comprimido
FROM msdb.dbo.backupset
WHERE backup_start_date >= DATEADD(DAY,-15,GETDATE())
GROUP BY database_name, type ORDER BY 1,2;"

Q "TIPO DE DESTINO DOS BACKUPS - 15 DIAS (disco, VDI de terceiro, URL)" "
SELECT CASE bmf.device_type WHEN 2 THEN 'DISCO' WHEN 5 THEN 'FITA' WHEN 7 THEN 'VIRTUAL (VDI: Veeam/Commvault/agente)' WHEN 9 THEN 'URL (Azure Blob/S3)' ELSE CAST(bmf.device_type AS varchar(10)) END AS tipo_destino,
 COUNT(DISTINCT bs.backup_set_id) AS backups, MIN(bmf.physical_device_name) AS exemplo
FROM msdb.dbo.backupset bs JOIN msdb.dbo.backupmediafamily bmf ON bmf.media_set_id = bs.media_set_id
WHERE bs.backup_start_date >= DATEADD(DAY,-15,GETDATE())
GROUP BY bmf.device_type ORDER BY 2 DESC;"

Q "CRIPTOGRAFIA DO BACKUP, TDE E BACKUP DOS CERTIFICADOS" "
IF COL_LENGTH('msdb.dbo.backupset','encryptor_type') IS NOT NULL
BEGIN
  EXEC('SELECT database_name AS base, ISNULL(encryptor_type,''NENHUMA'') AS criptografia, ISNULL(key_algorithm,''-'') AS algoritmo, COUNT(*) AS backups FROM msdb.dbo.backupset WHERE backup_start_date >= DATEADD(DAY,-15,GETDATE()) GROUP BY database_name, encryptor_type, key_algorithm ORDER BY 1')
END
ELSE
BEGIN
  SELECT 'Versao anterior ao SQL Server 2014: sem criptografia nativa de backup' AS criptografia
END;
IF COL_LENGTH('sys.certificates','pvt_key_last_backup_date') IS NOT NULL
BEGIN
  EXEC('SELECT name AS certificado, CONVERT(varchar(16), pvt_key_last_backup_date, 120) AS ultimo_backup_chave, CONVERT(varchar(10), expiry_date, 120) AS expira FROM master.sys.certificates WHERE name NOT LIKE ''##%''')
END;
SELECT DB_NAME(database_id) AS base_tde, encryption_state AS estado_tde FROM sys.dm_database_encryption_keys;"

Q "HISTORICO DE RESTORES - 365 DIAS (evidencia de teste de restauracao)" "
SELECT TOP 40 CONVERT(varchar(16), rh.restore_date, 120) AS data_restore, rh.destination_database_name AS base_destino,
 CASE rh.restore_type WHEN 'D' THEN 'DATABASE' WHEN 'I' THEN 'DIFERENCIAL' WHEN 'L' THEN 'LOG' WHEN 'F' THEN 'FILE' WHEN 'G' THEN 'FILEGROUP' WHEN 'V' THEN 'VERIFYONLY' ELSE rh.restore_type END AS tipo,
 bs.database_name AS base_origem, bs.server_name AS servidor_origem,
 CONVERT(varchar(16), bs.backup_finish_date, 120) AS backup_usado, rh.user_name AS executor
FROM msdb.dbo.restorehistory rh LEFT JOIN msdb.dbo.backupset bs ON bs.backup_set_id = rh.backup_set_id
WHERE rh.restore_date >= DATEADD(DAY,-365,GETDATE())
ORDER BY rh.restore_date DESC;"

Q "INTEGRIDADE - ULTIMO CHECKDB SEM ERRO E PAGINAS SUSPEITAS" "
SELECT name AS base, CONVERT(varchar(16), CAST(DATABASEPROPERTYEX(name,'LastGoodCheckDbTime') AS datetime), 120) AS ultimo_checkdb_ok
FROM sys.databases WHERE name <> 'tempdb' AND state_desc = 'ONLINE' ORDER BY name;
SELECT DB_NAME(database_id) AS base, file_id, page_id, event_type, error_count, CONVERT(varchar(16), last_update_date, 120) AS atualizado FROM msdb.dbo.suspect_pages;"

Q "ALTA DISPONIBILIDADE - ALWAYS ON, LOG SHIPPING E MIRRORING" "
IF OBJECT_ID('sys.availability_groups') IS NOT NULL
BEGIN
  EXEC('SELECT ag.name AS ag, ag.automated_backup_preference_desc AS preferencia_backup, ar.replica_server_name AS replica, ar.availability_mode_desc AS modo, ISNULL(rs.role_desc,''-'') AS papel, ISNULL(rs.synchronization_health_desc,''-'') AS saude FROM sys.availability_groups ag JOIN sys.availability_replicas ar ON ar.group_id = ag.group_id LEFT JOIN sys.dm_hadr_availability_replica_states rs ON rs.replica_id = ar.replica_id ORDER BY ag.name, ar.replica_server_name')
END;
SELECT primary_server, primary_database, CONVERT(varchar(16), last_backup_date, 120) AS ultimo_backup_log, backup_threshold AS limite_min FROM msdb.dbo.log_shipping_monitor_primary;
SELECT secondary_server, secondary_database, CONVERT(varchar(16), last_restored_date, 120) AS ultimo_restore, restore_threshold AS limite_min FROM msdb.dbo.log_shipping_monitor_secondary;
SELECT DB_NAME(database_id) AS base, mirroring_role_desc AS papel, mirroring_state_desc AS estado, mirroring_partner_instance AS parceiro FROM sys.database_mirroring WHERE mirroring_guid IS NOT NULL;"

Q "RESULTADO DOS JOBS DO AGENT - 15 DIAS E RETENCAO DO HISTORICO NO MSDB" "
SELECT j.name AS job,
 SUM(CASE WHEN h.run_status = 1 THEN 1 ELSE 0 END) AS sucesso,
 SUM(CASE WHEN h.run_status = 0 THEN 1 ELSE 0 END) AS falha,
 MAX(h.run_date) AS ultima_data
FROM msdb.dbo.sysjobs j JOIN msdb.dbo.sysjobhistory h ON h.job_id = j.job_id AND h.step_id = 0
WHERE h.run_date >= CONVERT(int, CONVERT(char(8), DATEADD(DAY,-15,GETDATE()), 112))
GROUP BY j.name ORDER BY j.name;
SELECT CONVERT(varchar(16), MIN(backup_start_date), 120) AS backup_mais_antigo_no_historico, COUNT(*) AS registros FROM msdb.dbo.backupset;"

unset SQLCMDPASSWORD
diga ""
if [ "$FALHAS" -gt 0 ]; then
  diga "Coleta SQL Server concluida com $FALHAS bloco(s) em erro. Revise $OUT/sqlserver_evidencias.txt"
else
  diga "Coleta SQL Server concluida sem erros."
fi
echo "Coleta SQL Server concluida em $OUT. Revise antes de enviar."
echo "Obs: rode tambem o 01_coleta_linux_geral.sh neste servidor para capturar o crontab que dispara os backups."
