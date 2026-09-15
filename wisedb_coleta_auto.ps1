<#
===============================================================================
 wisedb_coleta_auto.ps1 - WiseDB | Coleta AUTOMATICA para Politica de Backup

 CONCEITO : Automatico first. Um unico comando no servidor Windows (PS admin):

   irm https://raw.githubusercontent.com/cainawisedb/wisedb-kit/main/wisedb_coleta_auto.ps1 | iex

 FLUXO    : 1) DETECTA: SQL Server, Veeam B&R, Veeam Agent, Hyper-V, PowerCLI
            2) WIZARD de confirmacao + itens fora do escopo (com justificativa)
            3) BAIXA da mesma origem os modulos necessarios (04, 06, 07a)
            4) Executa a coleta read-only, SANITIZA, mostra RESUMO e pede OK
            5) GERA resultado_final.txt (colar na IA), resultado.json e .zip
 RISCO    : Zero. Somente leitura.
===============================================================================
#>
# TLS 1.2 obrigatorio: Windows 2008R2/2012R2 negociam TLS 1.0 por padrao no .NET e o GitHub recusa
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072 } catch {}

$BaseUrl = if ($env:WISEDB_BASE_URL) { $env:WISEDB_BASE_URL } else { "https://raw.githubusercontent.com/cainawisedb/wisedb-kit/main" }
$Versao = "2.0"
$Hostn = $env:COMPUTERNAME
$Data = Get-Date -Format yyyyMMdd
$Work = Join-Path (Get-Location) "wisedb_coleta_${Hostn}_${Data}"
$Tmp = Join-Path $Work ".modulos"
New-Item -ItemType Directory -Force -Path $Tmp | Out-Null

Write-Host "==============================================================="
Write-Host " WiseDB - Coleta Automatica de Backup v$Versao | $Hostn | $(Get-Date -Format 'dd/MM/yyyy HH:mm')"
Write-Host "==============================================================="

#=========================== 1. DETECCAO ========================================
$Det = [ordered]@{
  windows   = @{ on = $true;  desc = "Servidor Windows (Task Scheduler, discos, mapeamentos)" }
  sqlserver = @{ on = [bool](Get-Service -Name 'MSSQL*' -ErrorAction SilentlyContinue | Where-Object Status -eq 'Running'); desc = "SQL Server (servico ativo)" }
  veeamvbr  = @{ on = [bool](Get-Service -Name 'VeeamBackupSvc' -ErrorAction SilentlyContinue); desc = "Veeam Backup & Replication (servidor)" }
  hyperv    = @{ on = [bool](Get-Service -Name 'vmms' -ErrorAction SilentlyContinue | Where-Object Status -eq 'Running'); desc = "Hyper-V (host)" }
  vmware    = @{ on = [bool](Get-Module -ListAvailable VMware.PowerCLI); desc = "VMware PowerCLI disponivel (coleta via vCenter)" }
}
$Keys = @($Det.Keys)
Write-Host "`nComponentes detectados automaticamente:"
for ($i=0; $i -lt $Keys.Count; $i++) {
  $m = if ($Det[$Keys[$i]].on) { "[X]" } else { "[ ]" }
  Write-Host ("  {0}) {1} {2}" -f ($i+1), $m, $Det[$Keys[$i]].desc)
}

#=========================== 2. WIZARD ==========================================
Write-Host "`n--- WIZARD -------------------------------------------------------------"
$toggle = Read-Host "Digite numeros para ligar/desligar itens (ex.: '4 5'), ENTER para aceitar"
foreach ($n in ($toggle -split '\s+' | Where-Object { $_ })) {
  $k = $Keys[[int]$n - 1]; if ($k) { $Det[$k].on = -not $Det[$k].on }
}
$Excluidos = @()
while ($true) {
  $item = Read-Host "Marcar algum ambiente/base como FORA do escopo da politica? (nome ou ENTER p/ seguir)"
  if (-not $item) { break }
  $just = Read-Host "  Justificativa para '$item'"
  $Excluidos += [pscustomobject]@{ item = $item; justificativa = $just }
}
$Cliente = Read-Host "Nome do cliente"; if (-not $Cliente) { $Cliente = "NAO_INFORMADO" }
$RPO = Read-Host "RPO acordado (ENTER se nao definido)"; if (-not $RPO) { $RPO = "A combinar com o cliente" }
$RTO = Read-Host "RTO acordado (ENTER se nao definido)"; if (-not $RTO) { $RTO = "A combinar com o cliente" }
$VCenter = ""
if ($Det.vmware.on) { $VCenter = Read-Host "Endereco do vCenter (ENTER para pular VMware)" }

#=========================== 3. MODULOS + COLETA ================================
function DL($m) {
  $dst = Join-Path $Tmp $m
  if (Test-Path ".\kit_coleta_backup\$m") { Copy-Item ".\kit_coleta_backup\$m" $dst -Force }
  elseif (Test-Path ".\$m") { Copy-Item ".\$m" $dst -Force }
  else {
    try { Invoke-WebRequest -Uri "$BaseUrl/$m" -OutFile $dst -UseBasicParsing -ErrorAction Stop }
    catch { Write-Host "ERRO: falha ao baixar $m de $BaseUrl" -ForegroundColor Red; Write-Host "  $($_.Exception.Message)" -ForegroundColor Red; return $null }
  }
  if (-not (Test-Path $dst)) { Write-Host "ERRO: modulo $m indisponivel, etapa ignorada" -ForegroundColor Red; return $null }
  return $dst
}
Push-Location $Work
Write-Host "`n--- COLETA (somente leitura) -------------------------------------------"
if ($Det.sqlserver.on -or $Det.windows.on) { $mod = DL "04_coleta_sqlserver_windows.ps1"; if ($mod) { & $mod } }
if ($Det.veeamvbr.on) { $mod = DL "06_coleta_veeam_vbr.ps1"; if ($mod) { & $mod } }
if ($Det.hyperv.on -or ($Det.vmware.on -and $VCenter)) {
  $mod = DL "07_coleta_hypervisor_windows.ps1"; if ($mod) { & $mod -VCenter $VCenter }
}
Pop-Location

#=========================== 4. SANITIZACAO =====================================
Get-ChildItem $Work -Recurse -Include *.txt,*.log,*.json | ForEach-Object {
  $c = Get-Content $_.FullName -Raw
  $c = $c -replace '(?i)((password|passwd|pwd|secret|token|apikey)\s*[=:]\s*)[^\s",]+', '$1***REMOVIDO***'
  Set-Content $_.FullName $c -Encoding utf8
}

#=========================== 5. CONSOLIDACAO ====================================
$FinalTxt = Join-Path $Work "resultado_final.txt"
$cab = @"
================================================================
 WISEDB - COLETA AUTOMATICA | Cliente: $Cliente | Host: $Hostn
 Data da coleta: $(Get-Date -Format 'dd/MM/yyyy HH:mm') | Script v$Versao
 RPO informado: $RPO | RTO informado: $RTO
 Itens fora do escopo declarados no wizard: $(if ($Excluidos.Count -eq 0){'(nenhum)'} else {($Excluidos | ForEach-Object { "$($_.item) [$($_.justificativa)]" }) -join '; '})
================================================================
"@
$cab | Out-File $FinalTxt -Encoding utf8
Get-ChildItem $Work -Recurse -Filter *.txt | Where-Object Name -ne 'resultado_final.txt' | Sort-Object FullName | ForEach-Object {
  "`n########## ARQUIVO: $($_.FullName.Replace($Work,'')) ##########" | Out-File $FinalTxt -Append -Encoding utf8
  Get-Content $_.FullName | Out-File $FinalTxt -Append -Encoding utf8
}
[ordered]@{
  schema = "wisedb.coleta.backup/v1"; cliente = $Cliente
  coleta = @{ host = $Hostn; data = (Get-Date -Format s); script_versao = $Versao; modo = "automatico" }
  deteccao = @{}; escopo = @{ fora_do_escopo = $Excluidos }
  rpo_informado = $RPO; rto_informado = $RTO
  evidencias_arquivos = @(Get-ChildItem $Work -Recurse -Filter *.txt | ForEach-Object { $_.FullName.Replace("$Work\","") })
} | ForEach-Object { $j = $_; foreach ($k in $Keys) { $j.deteccao[$k] = $Det[$k].on }; $j } |
  ConvertTo-Json -Depth 5 | Out-File (Join-Path $Work "resultado.json") -Encoding utf8

#=========================== 6. RESUMO + OK =====================================
Write-Host "`n=============================== RESUMO ================================"
Write-Host " Cliente: $Cliente | Host: $Hostn"
Write-Host " Arquivos de evidencia: $((Get-ChildItem $Work -Recurse -Filter *.txt).Count)"
Write-Host " Fora do escopo: $($Excluidos.Count) item(ns) | RPO: $RPO | RTO: $RTO"
$rest = Select-String -Path "$Work\*\*.txt" -Pattern 'password|passwd|secret|token' -ErrorAction SilentlyContinue | Where-Object Line -notmatch 'REMOVIDO' | Select-Object -First 5
if ($rest) { Write-Host " ATENCAO - revisar antes de enviar:"; $rest | ForEach-Object { Write-Host "   $($_.Path):$($_.LineNumber)" } }
else { Write-Host " Verificacao de segredos: nenhum remanescente" }
Write-Host "========================================================================"
$ok = Read-Host "Gerar pacote final? (S/n)"
if ($ok -ne 'n' -and $ok -ne 'N') {
  $zip = "wisedb_coleta_$($Cliente -replace ' ','_')_${Hostn}_${Data}.zip"
  Compress-Archive -Path $Work -DestinationPath $zip -Force
  Write-Host "`nPRONTO."
  Write-Host "  1) Pacote completo : $zip"
  Write-Host "  2) Para a IA       : $FinalTxt (+ resultado.json)"
  Write-Host "  Cole o conteudo na IA junto com o Modelo_Politica_de_Backup_WiseDB.md"
  Write-Host "  e o prompt Backup Policy Engineer para gerar a politica e o PDF."
} else { Write-Host "Pacote nao gerado. Arquivos em $Work para revisao." }
