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

 COMPATIBILIDADE : PowerShell 2.0+ (Windows Server 2008 R2, 2012, 2012 R2, 2016+)
            Cmdlets modernos (Get-ComputerInfo, Get-Volume, Get-SmbMapping,
            Get-ScheduledTask) sao testados com Get-Command e substituidos por
            WMI/schtasks/net use quando ausentes.
===============================================================================
#>
param([string]$Instancia = $env:COMPUTERNAME)

$Hostn = $env:COMPUTERNAME
$Out = ".\coleta_${Hostn}_$(Get-Date -Format yyyyMMdd)\04_windows"
New-Item -ItemType Directory -Force -Path $Out | Out-Null
$Arq = Join-Path $Out "windows_evidencias.txt"

function Sec($t){ "`n################ $t ################" | Out-File $Arq -Append -Encoding utf8 }
function Has($c){ [bool](Get-Command $c -ErrorAction SilentlyContinue) }

Sec "IDENTIFICACAO DO SERVIDOR ($(Get-Date -Format 'dd/MM/yyyy HH:mm'))"
if (Has 'Get-ComputerInfo') {
  Get-ComputerInfo -Property CsName, OsName, OsVersion, OsArchitecture |
    Format-List | Out-File $Arq -Append -Encoding utf8
} else {
  # PS < 5.1 (Server 2008 R2 / 2012 / 2012 R2): equivalente via WMI
  $cs = Get-WmiObject Win32_ComputerSystem -ErrorAction SilentlyContinue
  $os = Get-WmiObject Win32_OperatingSystem -ErrorAction SilentlyContinue
  New-Object psobject -Property @{
    CsName                  = $cs.Name
    CsDomain                = $cs.Domain
    CsManufacturer          = $cs.Manufacturer
    CsModel                 = $cs.Model
    CsTotalPhysicalMemoryGB = if ($cs) { [math]::Round($cs.TotalPhysicalMemory/1GB,2) } else { $null }
    OsName                  = $os.Caption
    OsVersion               = $os.Version
    OsArchitecture          = $os.OSArchitecture
    OsLastBootUpTime        = if ($os) { $os.ConvertToDateTime($os.LastBootUpTime) } else { $null }
    PSVersion               = $PSVersionTable.PSVersion.ToString()
  } | Format-List CsName, CsDomain, CsManufacturer, CsModel, CsTotalPhysicalMemoryGB,
                  OsName, OsVersion, OsArchitecture, OsLastBootUpTime, PSVersion |
    Out-File $Arq -Append -Encoding utf8
  "(coletado via WMI: Get-ComputerInfo indisponivel em PowerShell $($PSVersionTable.PSVersion))" |
    Out-File $Arq -Append -Encoding utf8
}

Sec "DISCOS E VOLUMES"
if (Has 'Get-Volume') {
  Get-Volume | Select-Object DriveLetter, FileSystemLabel,
    @{n='Total_GB';e={[math]::Round($_.Size/1GB,1)}},
    @{n='Livre_GB';e={[math]::Round($_.SizeRemaining/1GB,1)}} |
    Format-Table -Auto | Out-File $Arq -Append -Encoding utf8
} else {
  Get-WmiObject Win32_LogicalDisk -Filter "DriveType=2 or DriveType=3 or DriveType=4" -ErrorAction SilentlyContinue |
    Select-Object @{n='DriveLetter';e={$_.DeviceID}},
      @{n='FileSystemLabel';e={$_.VolumeName}},
      @{n='FileSystem';e={$_.FileSystem}},
      @{n='Total_GB';e={[math]::Round($_.Size/1GB,1)}},
      @{n='Livre_GB';e={[math]::Round($_.FreeSpace/1GB,1)}} |
    Format-Table -Auto | Out-File $Arq -Append -Encoding utf8
}

Sec "MAPEAMENTOS DE REDE (destinos de backup)"
if (Has 'Get-SmbMapping') {
  Get-SmbMapping -ErrorAction SilentlyContinue | Format-Table -Auto | Out-File $Arq -Append -Encoding utf8
} else {
  & net.exe use 2>&1 | Out-File $Arq -Append -Encoding utf8
  Get-WmiObject Win32_MappedLogicalDisk -ErrorAction SilentlyContinue |
    Select-Object DeviceID, ProviderName, @{n='Livre_GB';e={[math]::Round($_.FreeSpace/1GB,1)}} |
    Format-Table -Auto | Out-File $Arq -Append -Encoding utf8
}

Sec "TAREFAS AGENDADAS RELACIONADAS A BACKUP"
if (Has 'Get-ScheduledTask') {
  Get-ScheduledTask | Where-Object { $_.TaskName -match 'backup|bkp|sql|veeam|rman|dump' -and $_.State -ne 'Disabled' } |
    ForEach-Object {
      $info = $_ | Get-ScheduledTaskInfo
      New-Object psobject -Property @{
        Tarefa = $_.TaskName; Caminho = $_.TaskPath; Estado = $_.State
        UltimaExec = $info.LastRunTime; ProximaExec = $info.NextRunTime
        Acao = ($_.Actions | ForEach-Object { "$($_.Execute) $($_.Arguments)" }) -join ' ; '
      } | Format-List Tarefa, Caminho, Estado, UltimaExec, ProximaExec, Acao
    } | Out-File $Arq -Append -Encoding utf8
} else {
  # Fallback universal: schtasks existe desde o Windows XP/2003
  $raw = & schtasks.exe /query /fo LIST /v 2>&1 | Out-String
  $blocos = $raw -split "`r`n`r`n"
  $blocos | Where-Object { $_ -match '(?i)backup|bkp|sql|veeam|rman|dump' -and $_ -notmatch '(?i)Status:\s*(Desabilitado|Disabled)' } |
    Out-File $Arq -Append -Encoding utf8
  "(coletado via schtasks: Get-ScheduledTask indisponivel neste host)" |
    Out-File $Arq -Append -Encoding utf8
}

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
if (Has 'sqlcmd') {
  foreach ($k in $Queries.Keys) {
    Sec "SQL: $k"
    sqlcmd -S $Instancia -E -W -s ' | ' -Q "SET NOCOUNT ON; $($Queries[$k])" 2>&1 |
      Out-File $Arq -Append -Encoding utf8
  }
} else {
  Sec "SQL SERVER"
  "sqlcmd nao encontrado no PATH. Historico do msdb NAO coletado neste host." |
    Out-File $Arq -Append -Encoding utf8
  "Instalar 'Microsoft Command Line Utilities for SQL Server' ou executar as queries manualmente." |
    Out-File $Arq -Append -Encoding utf8
  Write-Host "AVISO: sqlcmd nao encontrado - historico de backups do SQL Server nao coletado." -ForegroundColor Yellow
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
