<#
===============================================================================
 07_coleta_hypervisor_windows.ps1 - WiseDB | Kit de Coleta para Politica de Backup

 OBJETIVO : Inventariar as VMs dos hypervisors (Hyper-V local e/ou VMware via
            PowerCLI) para cruzar com os jobs de backup (Veeam/OCI/etc.) e
            identificar VMs SEM protecao. Coleta tambem checkpoints/snapshots
            antigos, que nao sao backup mas costumam ser confundidos com um.
 RISCO    : Zero. Somente Get-*.
 EXECUCAO : PowerShell como administrador no host Hyper-V, ou em maquina com
            PowerCLI para o caso VMware:
              powershell -ExecutionPolicy Bypass -File .\07_coleta_hypervisor_windows.ps1
              powershell ... -File .\07_coleta_hypervisor_windows.ps1 -VCenter "vcenter01.dominio"
            No VMware, a credencial de LEITURA e solicitada interativamente.
 SAIDA    : .\coleta_<hostname>_<data>\07_hypervisor\
===============================================================================
#>
param([string]$VCenter = "")

$Hostn = $env:COMPUTERNAME
$Out = ".\coleta_${Hostn}_$(Get-Date -Format yyyyMMdd)\07_hypervisor"
New-Item -ItemType Directory -Force -Path $Out | Out-Null
$Arq = Join-Path $Out "hypervisor_evidencias.txt"

function Sec($t){ "`n################ $t ################" | Out-File $Arq -Append -Encoding utf8 }

Sec "INVENTARIO DE HYPERVISOR ($(Get-Date -Format 'dd/MM/yyyy HH:mm')) - Host: $Hostn"

# ------------------------------- HYPER-V --------------------------------------
if (Get-Command Get-VM -Module Hyper-V -ErrorAction SilentlyContinue) {
  Sec "HYPER-V: VMs (estado, geracao, discos)"
  Get-VM | Select-Object Name, State, Generation,
    @{n='vCPU';e={$_.ProcessorCount}},
    @{n='RAM_GB';e={[math]::Round($_.MemoryAssigned/1GB,1)}},
    @{n='Discos';e={($_.HardDrives.Path) -join ' ; '}} |
    Format-List | Out-File $Arq -Append -Encoding utf8

  Sec "HYPER-V: CHECKPOINTS (snapshots antigos = risco, nao sao backup)"
  Get-VM | Get-VMSnapshot -ErrorAction SilentlyContinue |
    Select-Object VMName, Name, CreationTime, SnapshotType |
    Sort-Object CreationTime | Format-Table -Auto | Out-File $Arq -Append -Encoding utf8

  Sec "HYPER-V: REPLICACAO (se usada como DR)"
  Get-VMReplication -ErrorAction SilentlyContinue |
    Select-Object VMName, State, Mode, ReplicaServer, FrequencySec |
    Format-Table -Auto | Out-File $Arq -Append -Encoding utf8
} else {
  Sec "HYPER-V"
  "Modulo Hyper-V nao encontrado neste host." | Out-File $Arq -Append -Encoding utf8
}

# ------------------------------- VMWARE ---------------------------------------
if ($VCenter -ne "") {
  Sec "VMWARE ($VCenter): conexao com credencial de leitura (solicitada agora)"
  try {
    Import-Module VMware.PowerCLI -ErrorAction Stop
    Set-PowerCLIConfiguration -InvalidCertificateAction Ignore -Confirm:$false | Out-Null
    Connect-VIServer -Server $VCenter | Out-Null

    Sec "VMWARE: VMs (estado, host, datastore)"
    Get-VM | Select-Object Name, PowerState, NumCpu, MemoryGB,
      @{n='Host';e={$_.VMHost.Name}},
      @{n='Datastores';e={($_ | Get-Datastore).Name -join ' ; '}} |
      Format-Table -Auto | Out-File $Arq -Append -Encoding utf8

    Sec "VMWARE: SNAPSHOTS (antigos = risco, nao sao backup)"
    Get-VM | Get-Snapshot |
      Select-Object VM, Name, Created, @{n='Tamanho_GB';e={[math]::Round($_.SizeGB,1)}} |
      Sort-Object Created | Format-Table -Auto | Out-File $Arq -Append -Encoding utf8

    Disconnect-VIServer -Confirm:$false | Out-Null
  } catch { "[AVISO] $($_.Exception.Message)" | Out-File $Arq -Append -Encoding utf8 }
} else {
  Sec "VMWARE"
  "Parametro -VCenter nao informado; etapa VMware ignorada." | Out-File $Arq -Append -Encoding utf8
}

Write-Host "Inventario de hypervisor concluido em $Out. Cruze com os jobs do Veeam (script 06)."
