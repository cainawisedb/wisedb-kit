<#
===============================================================================
 06_coleta_veeam_vbr.ps1 - WiseDB | Kit de Coleta para Politica de Backup

 OBJETIVO : Coletar no servidor Veeam Backup & Replication tudo que a politica
            precisa sobre backup de VMs: jobs e agendamentos, retencao,
            repositorios (incluindo IMUTABILIDADE / hardened repository),
            copias secundarias e off-site (Backup Copy, SOBR Capacity Tier,
            Tape), sessoes dos ultimos 14 dias e lista de VMs protegidas.
 RISCO    : Zero. Somente Get-*.
 EXECUCAO : PowerShell como administrador NO SERVIDOR VEEAM:
              powershell -ExecutionPolicy Bypass -File .\06_coleta_veeam_vbr.ps1
 SAIDA    : .\coleta_<hostname>_<data>\06_veeam\
===============================================================================
#>
$Hostn = $env:COMPUTERNAME
$Out = ".\coleta_${Hostn}_$(Get-Date -Format yyyyMMdd)\06_veeam"
New-Item -ItemType Directory -Force -Path $Out | Out-Null
$Arq = Join-Path $Out "veeam_evidencias.txt"

function Sec($t){ "`n################ $t ################" | Out-File $Arq -Append -Encoding utf8 }
function Try-Block($titulo, [scriptblock]$sb){
  Sec $titulo
  try { & $sb | Out-File $Arq -Append -Encoding utf8 }
  catch { "[AVISO] $($_.Exception.Message)" | Out-File $Arq -Append -Encoding utf8 }
}

Sec "COLETA VEEAM B&R ($(Get-Date -Format 'dd/MM/yyyy HH:mm')) - Host: $Hostn"
try { Import-Module Veeam.Backup.PowerShell -ErrorAction Stop }
catch { Add-PSSnapin VeeamPSSnapin -ErrorAction SilentlyContinue }

Try-Block "VERSAO DO VEEAM" {
  Get-ItemProperty 'HKLM:\SOFTWARE\Veeam\Veeam Backup and Replication' -ErrorAction SilentlyContinue |
    Select-Object CorePath, @{n='Versao';e={(Get-Item (Join-Path $_.CorePath 'Veeam.Backup.Core.dll')).VersionInfo.ProductVersion}}
}

# ---------------- Jobs de backup: agendamento e retencao ----------------------
Try-Block "JOBS DE BACKUP (tipo, agendamento, retencao, repositorio)" {
  Get-VBRJob | ForEach-Object {
    $o = $_.Options
    [pscustomobject]@{
      Job          = $_.Name
      Tipo         = $_.JobType
      Habilitado   = $_.IsScheduleEnabled
      Agendamento  = $_.ScheduleOptions.OptionsDaily.Kind.ToString() + ' ' + ($_.ScheduleOptions.OptionsDaily.TimeLocal)
      Periodico    = if($_.ScheduleOptions.OptionsPeriodically.Enabled){"$($_.ScheduleOptions.OptionsPeriodically.FullPeriod) min"}else{'-'}
      Retencao     = if($o.RetentionPolicy){"$($o.RetentionPolicy.Type) = $($o.RetentionPolicy.Count)"}
                     else{"RetainCycles=$($o.BackupStorageOptions.RetainCycles) / RetainDays=$($o.BackupStorageOptions.RetainDaysToKeep)"}
      GFS          = if($o.GfsPolicy -and $o.GfsPolicy.IsEnabled){'Sim (semanal/mensal/anual - ver JSON)'}else{'Nao'}
      Repositorio  = $_.GetTargetRepository().Name
      SinteticoFull= $o.BackupStorageOptions.EnableFullBackup
    }
  } | Format-List
}

Try-Block "AGENT BACKUP JOBS (Veeam Agent gerenciado, se houver)" {
  Get-VBRComputerBackupJob -ErrorAction Stop |
    Select-Object Name, Type, Mode, @{n='Agendamento';e={$_.ScheduleOptions}}, BackupRepository |
    Format-List
}

Try-Block "BACKUP COPY JOBS (copia secundaria / off-site)" {
  Get-VBRBackupCopyJob -ErrorAction SilentlyContinue | Select-Object Name, IsEnabled, Mode,
    @{n='RetencaoPontos';e={$_.RetentionNumber}}, @{n='Repositorio';e={$_.Target}} | Format-List
}

Try-Block "TAPE JOBS (se houver fita)" {
  Get-VBRTapeJob -ErrorAction Stop | Select-Object Name, Enabled, Type, FullBackupMediaPool | Format-List
}

# ---------------- Repositorios: onde estao os dados e imutabilidade -----------
Try-Block "REPOSITORIOS (caminho, tipo, IMUTABILIDADE/hardened)" {
  Get-VBRBackupRepository | ForEach-Object {
    [pscustomobject]@{
      Repositorio  = $_.Name
      Tipo         = $_.Type
      Caminho      = $_.FriendlyPath
      Host         = $_.Host.Name
      Imutavel     = try { if($_.GetImmutabilitySettings().IsEnabled){"Sim - $($_.GetImmutabilitySettings().Period) dias"} else {'Nao'} } catch {'Nao suportado/verificar'}
    }
  } | Format-List
}

Try-Block "SCALE-OUT REPOSITORY + CAPACITY TIER (off-site em object storage)" {
  Get-VBRScaleOutBackupRepository -ErrorAction Stop | ForEach-Object {
    [pscustomobject]@{
      SOBR          = $_.Name
      Extents       = ($_.Extent.Name -join ', ')
      CapacityTier  = if($_.EnableCapacityTier){"Sim -> $($_.CapacityExtent.Repository.Name)"}else{'Nao'}
      CopiaImediata = $_.CapacityTierCopyPolicyEnabled
      MoverApos     = if($_.CapacityTierMovePolicyEnabled){"$($_.OperationalRestorePeriod) dias"}else{'-'}
      ImutavelCloud = try { $_.CapacityExtent.Repository.BackupImmutabilityEnabled } catch {'verificar'}
    }
  } | Format-List
}

# ---------------- Execucoes reais e cobertura ---------------------------------
Try-Block "SESSOES DOS ULTIMOS 14 DIAS (execucao real)" {
  Get-VBRBackupSession | Where-Object { $_.CreationTime -gt (Get-Date).AddDays(-14) } |
    Sort-Object CreationTime |
    Select-Object JobName, JobType, CreationTime, EndTime, Result, State |
    Format-Table -Auto
}

Try-Block "RESUMO POR JOB (14 DIAS): sucessos/avisos/falhas" {
  Get-VBRBackupSession | Where-Object { $_.CreationTime -gt (Get-Date).AddDays(-14) } |
    Group-Object JobName | ForEach-Object {
      [pscustomobject]@{
        Job     = $_.Name
        Total   = $_.Count
        Sucesso = ($_.Group | Where-Object Result -eq 'Success').Count
        Alerta  = ($_.Group | Where-Object Result -eq 'Warning').Count
        Falha   = ($_.Group | Where-Object Result -eq 'Failed').Count
      }
    } | Format-Table -Auto
}

Try-Block "VMs/OBJETOS PROTEGIDOS POR JOB" {
  Get-VBRJob | ForEach-Object {
    $j = $_.Name
    Get-VBRJobObject -Job $_ | Select-Object @{n='Job';e={$j}}, Name, Type
  } | Format-Table -Auto
}

Try-Block "RESTORE POINTS MAIS RECENTES POR VM (janela real de recuperacao)" {
  Get-VBRBackup | ForEach-Object {
    $b = $_.JobName
    $_.GetLastOibs($true) | Select-Object @{n='Job';e={$b}},
      @{n='VM';e={$_.Name}}, @{n='UltimoPonto';e={$_.CreationTime}}
  } | Sort-Object VM | Format-Table -Auto
}

Try-Block "VMs DO HYPERVISOR SEM JOB (gap de cobertura - comparar manualmente)" {
  "Compare a lista de VMs protegidas acima com o inventario dos hypervisors (script 07)."
}

Write-Host "Coleta Veeam concluida em $Out. Revise antes de enviar."
