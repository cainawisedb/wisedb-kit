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
#===============================================================================
set -uo pipefail
SRV="${1:?Uso: $0 <servidor,porta> <usuario>}"
USR="${2:?Uso: $0 <servidor,porta> <usuario>}"

HOSTN=$(hostname -s 2>/dev/null || hostname)
OUT="./coleta_${HOSTN}_$(date +%Y%m%d)/03_sqlserver"
mkdir -p "$OUT"
SQLCMD=$(command -v sqlcmd || echo /opt/mssql-tools18/bin/sqlcmd)
FALHAS=0

# Progresso e prompts vao para o terminal real. Como Q() redireciona 2>&1 para o
# arquivo de evidencia, sem isto o operador ve a tela parada sem saber que o
# script esta aguardando digitacao.
exec 9>&2
TEM_TTY=0
if ( : > /dev/tty ) 2>/dev/null; then exec 9>/dev/tty; TEM_TTY=1; fi
diga(){ printf '%s\n' "$*" >&9; }

if [ ! -x "$SQLCMD" ]; then
  diga "ERRO: sqlcmd nao encontrado em '$SQLCMD'. Instale mssql-tools18 ou ajuste o PATH."
  exit 1
fi

if [ -z "${SQLCMDPASSWORD:-}" ]; then
  if [ "$TEM_TTY" = "1" ]; then
    printf '%s' "Senha de leitura do SQL Server ($USR): " >&9
    read -rs SQLCMDPASSWORD < /dev/tty
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

unset SQLCMDPASSWORD
diga ""
if [ "$FALHAS" -gt 0 ]; then
  diga "Coleta SQL Server concluida com $FALHAS bloco(s) em erro. Revise $OUT/sqlserver_evidencias.txt"
else
  diga "Coleta SQL Server concluida sem erros."
fi
echo "Coleta SQL Server concluida em $OUT. Revise antes de enviar."
echo "Obs: rode tambem o 01_coleta_linux_geral.sh neste servidor para capturar o crontab que dispara os backups."
