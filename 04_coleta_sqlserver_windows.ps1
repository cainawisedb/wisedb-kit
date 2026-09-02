<#
===============================================================================
 04_coleta_sqlserver_windows.ps1 - WiseDB | Kit de Coleta para Politica de Backup

 OBJETIVO : Coletar em servidores Windows: agendamentos (Task Scheduler),
            historico real de backups do SQL Server (msdb, 15 dias),
            Maintenance Plans/Jobs do Agent e jobs do Veeam (se instalado).
 RISCO    : Zero. Somente leitura (Get-*, SELECT).
 EXECUCAO : PowerShell como administrador, no proprio servidor:
              powershell -ExecutionPolicy Bypass -File .\04_coleta_sqlserver_windows.ps1
            Parametro opcional -Instancia "SERVIDOR\INSTANCIA" (padrao: local).
            Autenticacao Windows (-E). Nao ha senha em arquivo.
 SAIDA    : .\coleta_<hostname>_<data>\04_windows\
===============================================================================
#>
param([string]$Instancia = $env:COMPUTERNAME)

$Hostn = $env:COMPUTERNAME
$Out = ".\coleta_${Hostn}_$(Get-Date -Format yyyyMMdd)\04_windows"
New-Item -ItemType Directory -Force -Path $Out | Out-Null
$Arq = Join-Path $Out "windows_evidencias.txt"

function Sec($t){ "`n################ $t ################" | Out-File $Arq -Append -Encoding utf8 }

Sec "IDENTIFICACAO DO SERVIDOR ($(Get-Date -Format 'dd/MM/yyyy HH:mm'))"
Get-ComputerInfo -Property CsName, OsName, OsVersion, OsArchitecture |
  Format-List | Out-File $Arq -Append -Encoding utf8

Sec "DISCOS E VOLUMES"
Get-Volume | Select-Object DriveLetter, FileSystemLabel,
  @{n='Total_GB';e={[math]::Round($_.Size/1GB,1)}},
  @{n='Livre_GB';e={[math]::Round($_.SizeRemaining/1GB,1)}} |
  Format-Table -Auto | Out-File $Arq -Append -Encoding utf8

Sec "MAPEAMENTOS DE REDE (destinos de backup)"
Get-SmbMapping -ErrorAction SilentlyContinue | Format-Table -Auto | Out-File $Arq -Append -Encoding utf8

Sec "TAREFAS AGENDADAS RELACIONADAS A BACKUP"
Get-ScheduledTask | Where-Object { $_.TaskName -match 'backup|bkp|sql|veeam|rman|dump' -and $_.State -ne 'Disabled' } |
  ForEach-Object {
    $info = $_ | Get-ScheduledTaskInfo
    [pscustomobject]@{
      Tarefa = $_.TaskName; Caminho = $_.TaskPath; Estado = $_.State
      UltimaExec = $info.LastRunTime; ProximaExec = $info.NextRunTime
      Acao = ($_.Actions | ForEach-Object { "$($_.Execute) $($_.Arguments)" }) -join ' ; '
    }
  } | Format-List | Out-File $Arq -Append -Encoding utf8

# ----------------- SQL Server: historico real via msdb -----------------------
$Queries = @{
"VERSAO SQL SERVER" = "SELECT @@SERVERNAME AS servidor, @@VERSION AS versao;"
"BASES E RECOVERY MODEL" = "SELECT name, state_desc, recovery_model_desc FROM sys.databases ORDER BY name;"
"HISTORICO DE BACKUPS - 15 DIAS" = @"
SELECT bs.database_name,
 CASE bs.type WHEN 'D' THEN 'FULL' WHEN 'I' THEN 'DIFERENCIAL' WHEN 'L' THEN 'TRANSACTION LOG' ELSE bs.type END AS tipo,
 CONVERT(varchar(16), bs.backup_start_date, 120) AS inicio,
 CAST(bs.backup_size/1024.0/1024/1024 AS decimal(12,2)) AS tamanho_gb,
 bmf.physical_device_name AS destino
FROM msdb.dbo.backupset bs
JOIN msdb.dbo.backupmediafamily bmf ON bmf.media_set_id=bs.media_set_id
WHERE bs.backup_start_date >= DATEADD(DAY,-15,GETDATE())
ORDER BY bs.backup_start_date;
"@
"BASES SEM FULL EM 15 DIAS" = @"
SELECT d.name FROM sys.databases d
LEFT JOIN msdb.dbo.backupset bs ON bs.database_name=d.name AND bs.type='D'
 AND bs.backup_start_date >= DATEADD(DAY,-15,GETDATE())
WHERE d.name NOT IN ('tempdb') AND bs.database_name IS NULL;
"@
"JOBS DO SQL AGENT / MAINTENANCE PLANS" = @"
SELECT j.name AS job, j.enabled, s.name AS schedule,
 RIGHT('000000'+CAST(s.active_start_time AS varchar(6)),6) AS hora_hhmmss
FROM msdb.dbo.sysjobs j
LEFT JOIN msdb.dbo.sysjobschedules js ON js.job_id=j.job_id
LEFT JOIN msdb.dbo.sysschedules s ON s.schedule_id=js.schedule_id
ORDER BY j.name;
"@
}
foreach ($k in $Queries.Keys) {
  Sec "SQL: $k"
  sqlcmd -S $Instancia -E -W -s ' | ' -Q "SET NOCOUNT ON; $($Queries[$k])" 2>&1 |
    Out-File $Arq -Append -Encoding utf8
}

# ----------------- Veeam (se o modulo estiver presente) ----------------------
Sec "VEEAM - JOBS E SESSOES (7 DIAS)"
try {
  Import-Module Veeam.Backup.PowerShell -ErrorAction Stop
  Get-VBRJob | Select-Object Name, JobType, IsScheduleEnabled,
    @{n='Agendamento';e={$_.ScheduleOptions.OptionsDaily}} |
    Format-List | Out-File $Arq -Append -Encoding utf8
  Get-VBRBackupSession | Where-Object { $_.CreationTime -gt (Get-Date).AddDays(-7) } |
    Select-Object JobName, CreationTime, Result, State |
    Sort-Object CreationTime | Format-Table -Auto | Out-File $Arq -Append -Encoding utf8
} catch { "Modulo Veeam nao encontrado neste servidor (ok se Veeam nao for usado aqui)." |
    Out-File $Arq -Append -Encoding utf8 }

Write-Host "Coleta Windows concluida em $Out. Revise antes de enviar."
