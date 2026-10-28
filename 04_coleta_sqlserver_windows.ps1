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
            Parametro opcional -SkipVeeam: ignora o bloco Veeam deste modulo
            quando o host e servidor VBR e o 06_coleta_veeam_vbr.ps1 vai rodar
            em seguida (evita varrer o historico de sessoes duas vezes).
            Autenticacao Windows (-E). Nao ha senha em arquivo.
 SAIDA    : .\coleta_<hostname>_<data>\04_windows\

 COMPATIBILIDADE : PowerShell 2.0+ (Windows Server 2008 R2, 2012, 2012 R2, 2016+)
            Cmdlets modernos (Get-ComputerInfo, Get-Volume, Get-SmbMapping,
            Get-ScheduledTask) sao testados com Get-Command e substituidos por
            WMI/schtasks/net use quando ausentes.
===============================================================================
#>
param([string[]]$Instancia = @(), [switch]$SkipVeeam)

# v1.3 (outubro/2026): mesmos blocos do 03 v1.2 (lacuna de log, checksum, destino
# VDI/URL, criptografia/TDE/certificados, historico de RESTORE, CHECKDB, paginas
# suspeitas, Always On, log shipping, mirroring, resultado dos jobs do Agent).

# v1.2 (outubro/2026): instancias nomeadas (MSSQL$NOME) detectadas sozinhas; antes
# so a instancia padrao era consultada e servidor TOTVS/Express saia sem msdb.
if ($Instancia.Count -eq 0) {
  $Instancia = @(Get-Service -Name 'MSSQL*' -ErrorAction SilentlyContinue |
    Where-Object { $_.Status -eq 'Running' -and ($_.Name -eq 'MSSQLSERVER' -or $_.Name -like 'MSSQL$*') } |
    ForEach-Object { if ($_.Name -eq 'MSSQLSERVER') { $env:COMPUTERNAME } else { "$env:COMPUTERNAME\" + ($_.Name -replace '^MSSQL\$','') } })
  # Sem servico SQL ativo nao consulta nada: antes caia na instancia padrao e
  # gerava "sem conexao" em servidor que nem tem SQL Server (ruido na politica).
}

$Hostn = $env:COMPUTERNAME
$Out = ".\coleta_${Hostn}_$(Get-Date -Format yyyyMMdd)\04_windows"
New-Item -ItemType Directory -Force -Path $Out | Out-Null
$Arq = Join-Path $Out "windows_evidencias.txt"

function Sec($t){ "`n################ $t ################" | Out-File $Arq -Append -Encoding utf8 }
function Has($c){ [bool](Get-Command $c -ErrorAction SilentlyContinue) }
# Toda a saida deste modulo vai para arquivo. Sem progresso na tela o operador
# ve a janela parada e nao sabe se a coleta travou ou esta trabalhando.
function Diga($t){ Write-Host ("  [{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $t) }
function Etapa($t){ Sec $t; Diga $t }

Diga "Modulo 04 iniciado (saida em $Out)"

Etapa "IDENTIFICACAO DO SERVIDOR ($(Get-Date -Format 'dd/MM/yyyy HH:mm'))"
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

Etapa "DISCOS E VOLUMES"
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

Etapa "MAPEAMENTOS DE REDE (destinos de backup)"
if (Has 'Get-SmbMapping') {
  Get-SmbMapping -ErrorAction SilentlyContinue | Format-Table -Auto | Out-File $Arq -Append -Encoding utf8
} else {
  & net.exe use 2>&1 | Out-File $Arq -Append -Encoding utf8
  Get-WmiObject Win32_MappedLogicalDisk -ErrorAction SilentlyContinue |
    Select-Object DeviceID, ProviderName, @{n='Livre_GB';e={[math]::Round($_.FreeSpace/1GB,1)}} |
    Format-Table -Auto | Out-File $Arq -Append -Encoding utf8
}

Etapa "TAREFAS AGENDADAS RELACIONADAS A BACKUP"
if (Has 'Get-ScheduledTask') {
  # Filtra pelo nome E pela acao: tarefa "Rotina_Noturna" chamando expdp.cmd ficava de fora.
  $rxTask = 'backup|bkp|sql|veeam|rman|dump|expdp|exp\.exe|datapump|robocopy|wbadmin'
  Get-ScheduledTask | Where-Object { $_.State -ne 'Disabled' -and ($_.TaskName -match $rxTask -or
      (($_.Actions | ForEach-Object { "$($_.Execute) $($_.Arguments)" }) -join ' ') -match $rxTask) } |
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
"ULTIMO BACKUP POR BASE E TIPO (RPO E LACUNA DE LOG)" = @"
SELECT d.name AS base, d.recovery_model_desc AS recovery,
 CONVERT(varchar(16), MAX(CASE WHEN b.type='D' THEN b.backup_finish_date END), 120) AS ultimo_full,
 CONVERT(varchar(16), MAX(CASE WHEN b.type='I' THEN b.backup_finish_date END), 120) AS ultimo_diff,
 CONVERT(varchar(16), MAX(CASE WHEN b.type='L' THEN b.backup_finish_date END), 120) AS ultimo_log,
 DATEDIFF(HOUR, MAX(CASE WHEN b.type IN ('D','I') THEN b.backup_finish_date END), GETDATE()) AS horas_desde_full_diff,
 DATEDIFF(MINUTE, MAX(CASE WHEN b.type='L' THEN b.backup_finish_date END), GETDATE()) AS min_desde_log
FROM sys.databases d LEFT JOIN msdb.dbo.backupset b ON b.database_name = d.name
WHERE d.name <> 'tempdb'
GROUP BY d.name, d.recovery_model_desc ORDER BY d.name;
"@
"QUALIDADE DOS BACKUPS - 15 DIAS (checksum, danificado, copy_only, compressao)" = @"
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
GROUP BY database_name, type ORDER BY 1,2;
"@
"TIPO DE DESTINO DOS BACKUPS - 15 DIAS (disco, VDI de terceiro, URL)" = @"
SELECT CASE bmf.device_type WHEN 2 THEN 'DISCO' WHEN 5 THEN 'FITA' WHEN 7 THEN 'VIRTUAL (VDI: Veeam/Commvault/agente)' WHEN 9 THEN 'URL (Azure Blob/S3)' ELSE CAST(bmf.device_type AS varchar(10)) END AS tipo_destino,
 COUNT(DISTINCT bs.backup_set_id) AS backups, MIN(bmf.physical_device_name) AS exemplo
FROM msdb.dbo.backupset bs JOIN msdb.dbo.backupmediafamily bmf ON bmf.media_set_id = bs.media_set_id
WHERE bs.backup_start_date >= DATEADD(DAY,-15,GETDATE())
GROUP BY bmf.device_type ORDER BY 2 DESC;
"@
"CRIPTOGRAFIA DO BACKUP, TDE E BACKUP DOS CERTIFICADOS" = @"
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
SELECT DB_NAME(database_id) AS base_tde, encryption_state AS estado_tde FROM sys.dm_database_encryption_keys;
"@
"HISTORICO DE RESTORES - 365 DIAS (evidencia de teste de restauracao)" = @"
SELECT TOP 40 CONVERT(varchar(16), rh.restore_date, 120) AS data_restore, rh.destination_database_name AS base_destino,
 CASE rh.restore_type WHEN 'D' THEN 'DATABASE' WHEN 'I' THEN 'DIFERENCIAL' WHEN 'L' THEN 'LOG' WHEN 'F' THEN 'FILE' WHEN 'G' THEN 'FILEGROUP' WHEN 'V' THEN 'VERIFYONLY' ELSE rh.restore_type END AS tipo,
 bs.database_name AS base_origem, bs.server_name AS servidor_origem,
 CONVERT(varchar(16), bs.backup_finish_date, 120) AS backup_usado, rh.user_name AS executor
FROM msdb.dbo.restorehistory rh LEFT JOIN msdb.dbo.backupset bs ON bs.backup_set_id = rh.backup_set_id
WHERE rh.restore_date >= DATEADD(DAY,-365,GETDATE())
ORDER BY rh.restore_date DESC;
"@
"INTEGRIDADE - ULTIMO CHECKDB SEM ERRO E PAGINAS SUSPEITAS" = @"
SELECT name AS base, CONVERT(varchar(16), CAST(DATABASEPROPERTYEX(name,'LastGoodCheckDbTime') AS datetime), 120) AS ultimo_checkdb_ok
FROM sys.databases WHERE name <> 'tempdb' AND state_desc = 'ONLINE' ORDER BY name;
SELECT DB_NAME(database_id) AS base, file_id, page_id, event_type, error_count, CONVERT(varchar(16), last_update_date, 120) AS atualizado FROM msdb.dbo.suspect_pages;
"@
"ALTA DISPONIBILIDADE - ALWAYS ON, LOG SHIPPING E MIRRORING" = @"
IF OBJECT_ID('sys.availability_groups') IS NOT NULL
BEGIN
  EXEC('SELECT ag.name AS ag, ag.automated_backup_preference_desc AS preferencia_backup, ar.replica_server_name AS replica, ar.availability_mode_desc AS modo, ISNULL(rs.role_desc,''-'') AS papel, ISNULL(rs.synchronization_health_desc,''-'') AS saude FROM sys.availability_groups ag JOIN sys.availability_replicas ar ON ar.group_id = ag.group_id LEFT JOIN sys.dm_hadr_availability_replica_states rs ON rs.replica_id = ar.replica_id ORDER BY ag.name, ar.replica_server_name')
END;
SELECT primary_server, primary_database, CONVERT(varchar(16), last_backup_date, 120) AS ultimo_backup_log, backup_threshold AS limite_min FROM msdb.dbo.log_shipping_monitor_primary;
SELECT secondary_server, secondary_database, CONVERT(varchar(16), last_restored_date, 120) AS ultimo_restore, restore_threshold AS limite_min FROM msdb.dbo.log_shipping_monitor_secondary;
SELECT DB_NAME(database_id) AS base, mirroring_role_desc AS papel, mirroring_state_desc AS estado, mirroring_partner_instance AS parceiro FROM sys.database_mirroring WHERE mirroring_guid IS NOT NULL;
"@
"RESULTADO DOS JOBS DO AGENT - 15 DIAS E RETENCAO DO HISTORICO NO MSDB" = @"
SELECT j.name AS job,
 SUM(CASE WHEN h.run_status = 1 THEN 1 ELSE 0 END) AS sucesso,
 SUM(CASE WHEN h.run_status = 0 THEN 1 ELSE 0 END) AS falha,
 MAX(h.run_date) AS ultima_data
FROM msdb.dbo.sysjobs j JOIN msdb.dbo.sysjobhistory h ON h.job_id = j.job_id AND h.step_id = 0
WHERE h.run_date >= CONVERT(int, CONVERT(char(8), DATEADD(DAY,-15,GETDATE()), 112))
GROUP BY j.name ORDER BY j.name;
SELECT CONVERT(varchar(16), MIN(backup_start_date), 120) AS backup_mais_antigo_no_historico, COUNT(*) AS registros FROM msdb.dbo.backupset;
"@
}
if ($Instancia.Count -eq 0) {
  Sec "SQL SERVER"
  "Nenhum servico SQL Server (MSSQLSERVER / MSSQL`$<instancia>) em execucao neste host." | Out-File $Arq -Append -Encoding utf8
} elseif (Has 'sqlcmd') {
  # -l 15 evita que uma instancia inacessivel segure o modulo por minutos.
  # sqlcmd 18 (ODBC 18) exige -C com certificado autoassinado; versoes antigas nao tem -C.
  $opC = @(); if ((& sqlcmd -? 2>&1 | Out-String) -match '-C\s') { $opC = @('-C') }
  foreach ($inst in $Instancia) {
    foreach ($k in $Queries.Keys) {
      Etapa "SQL [$inst]: $k"
      & sqlcmd -S $inst -E -W -s ' | ' -l 15 @opC -Q "SET NOCOUNT ON; $($Queries[$k])" 2>&1 |
        Out-File $Arq -Append -Encoding utf8
    }
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
if ($SkipVeeam) {
  Sec "VEEAM - DELEGADO AO MODULO 06"
  "Bloco Veeam ignorado neste modulo por opcao do orquestrador: este host e servidor VBR" |
    Out-File $Arq -Append -Encoding utf8
  "e a evidencia completa (jobs, repositorios, imutabilidade, sessoes) vem do 06_coleta_veeam_vbr.ps1." |
    Out-File $Arq -Append -Encoding utf8
  Diga "VEEAM: delegado ao modulo 06 (evita varrer o historico de sessoes duas vezes)"
} else {
  Etapa "VEEAM - JOBS E SESSOES (7 DIAS)"
  try {
    # VBR 10+ expoe o modulo; VBR 9.5 e anterior so tem o snapin.
    try { Import-Module Veeam.Backup.PowerShell -ErrorAction Stop }
    catch { Add-PSSnapin VeeamPSSnapin -ErrorAction Stop }
    Diga "  Veeam carregado; lendo jobs..."
    Get-VBRJob | Select-Object Name, JobType, IsScheduleEnabled,
      @{n='Agendamento';e={$_.ScheduleOptions.OptionsDaily}} |
      Format-List | Out-File $Arq -Append -Encoding utf8
    Diga "  Lendo sessoes (pode levar minutos em historico longo)..."
    $ses = @(Get-VBRBackupSession | Where-Object { $_.CreationTime -gt (Get-Date).AddDays(-7) })
    Diga ("  Sessoes nos ultimos 7 dias: {0}" -f $ses.Count)
    $ses | Select-Object JobName, CreationTime, Result, State |
      Sort-Object CreationTime | Format-Table -Auto | Out-File $Arq -Append -Encoding utf8
  } catch {
    "Modulo/snapin Veeam nao encontrado neste servidor (ok se Veeam nao for usado aqui)." |
      Out-File $Arq -Append -Encoding utf8
    "Detalhe: $($_.Exception.Message)" | Out-File $Arq -Append -Encoding utf8
    Diga "  Veeam nao disponivel neste host"
  }
}

Diga "Modulo 04 concluido"
Write-Host "Coleta Windows concluida em $Out. Revise antes de enviar."
