<#
===============================================================================
 wisedb_coleta_auto.ps1 - WiseDB | Coleta AUTOMATICA para Politica de Backup

 CONCEITO : Automatico first. Um unico comando no servidor Windows (PS admin):

   irm https://raw.githubusercontent.com/cainawisedb/wisedb-kit/main/wisedb_coleta_auto.ps1 | iex

 FLUXO    : 1) DETECTA: SQL Server, Veeam B&R, Veeam Agent, Hyper-V, PowerCLI
            2) WIZARD de confirmacao + cliente + itens fora do escopo
            3) CRIA a pasta de trabalho com nome do cliente e hora da coleta
            4) BAIXA da mesma origem os modulos necessarios (04, 06, 07a)
            5) Executa a coleta read-only, SANITIZA, mostra RESUMO e pede OK
            6) GERA resultado_final.txt (colar na IA), resultado.json e .zip
 RISCO    : Zero. Somente leitura.

 COMPATIBILIDADE : PowerShell 2.0+ (Windows Server 2008 R2, 2012, 2012 R2, 2016+)
            Compress-Archive (PS 5.0+) substituido por New-WiseZip, com cadeia
            de fallback: Compress-Archive -> System.IO.Compression.FileSystem
            (.NET 4.5) -> Shell.Application (COM, funciona em qualquer versao).
===============================================================================
#>
# TLS 1.2 obrigatorio: Windows 2008R2/2012R2 negociam TLS 1.0 por padrao no .NET e o GitHub recusa
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072 } catch {}

$BaseUrl = if ($env:WISEDB_BASE_URL) { $env:WISEDB_BASE_URL } else { "https://raw.githubusercontent.com/cainawisedb/wisedb-kit/main" }
$Versao = "2.2"
$Hostn = $env:COMPUTERNAME
$Data = Get-Date -Format yyyyMMdd
$Carimbo = Get-Date -Format 'yyyyMMdd_HHmm'
$Inicio = Get-Date
$ModulosFalharam = @()

Write-Host "==============================================================="
Write-Host " WiseDB - Coleta Automatica de Backup v$Versao | $Hostn | $(Get-Date -Format 'dd/MM/yyyy HH:mm')"
Write-Host " PowerShell $($PSVersionTable.PSVersion) | $([Environment]::OSVersion.VersionString)"
Write-Host "==============================================================="

#=========================== 0. COMPATIBILIDADE =================================
function Test-Cmd($c){ [bool](Get-Command $c -ErrorAction SilentlyContinue) }
function Diga($t){ Write-Host ("[{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $t) }

# Diretorio base da coleta. Executar a partir de C:\Windows\system32 (padrao do
# "Executar como administrador") jogava a pasta de trabalho, o resultado_final e
# o .zip para dentro do system32.
$BaseDir = (Get-Location).Path
if ($BaseDir -like "$env:SystemRoot*") {
  $alvo = Join-Path $env:PUBLIC "wisedb_coletas"
  try {
    New-Item -ItemType Directory -Force -Path $alvo -ErrorAction Stop | Out-Null
    $BaseDir = $alvo
  } catch {
    $BaseDir = $env:TEMP
  }
  Write-Host " AVISO: sessao iniciada em $env:SystemRoot. A coleta sera gravada em:" -ForegroundColor Yellow
  Write-Host "        $BaseDir" -ForegroundColor Yellow
}

function New-WiseZip {
<#
  Gera um .zip a partir de um diretorio, incluindo o diretorio base.
  Cadeia de fallback para hosts com PowerShell anterior a 5.0.
#>
  param(
    [Parameter(Mandatory=$true)][string]$SourceDir,
    [Parameter(Mandatory=$true)][string]$ZipPath
  )

  if (Test-Path $ZipPath) { Remove-Item $ZipPath -Force -ErrorAction SilentlyContinue }
  $src = (Resolve-Path $SourceDir).Path

  # 1) PS 5.0+
  if (Test-Cmd 'Compress-Archive') {
    Compress-Archive -Path $src -DestinationPath $ZipPath -Force
    return $true
  }

  # 2) .NET 4.5 (presente por padrao no Server 2012 / 2012 R2)
  try {
    Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction Stop
    [System.IO.Compression.ZipFile]::CreateFromDirectory(
      $src, $ZipPath,
      [System.IO.Compression.CompressionLevel]::Optimal,
      $true)
    Write-Host "  (zip gerado via System.IO.Compression - Compress-Archive indisponivel)" -ForegroundColor DarkGray
    return $true
  } catch { }

  # 3) COM Shell.Application - funciona sem dependencia de versao
  try {
    $eocd = [byte[]](0x50,0x4B,0x05,0x06) + (New-Object byte[] 18)
    [System.IO.File]::WriteAllBytes($ZipPath, $eocd)

    $shell = New-Object -ComObject Shell.Application
    $zipNs = $shell.NameSpace((Resolve-Path $ZipPath).Path)
    $itens = @(Get-ChildItem -Path $src -Force)

    foreach ($i in $itens) { $zipNs.CopyHere($i.FullName, 16) ; Start-Sleep -Milliseconds 500 }

    $limite = (Get-Date).AddMinutes(10)
    while ($zipNs.Items().Count -lt $itens.Count -and (Get-Date) -lt $limite) { Start-Sleep -Seconds 1 }

    [System.Runtime.InteropServices.Marshal]::ReleaseComObject($shell) | Out-Null
    Write-Host "  (zip gerado via Shell.Application - metodos modernos indisponiveis)" -ForegroundColor DarkGray
    return $true
  } catch {
    Write-Host "ERRO: nao foi possivel gerar o .zip automaticamente." -ForegroundColor Red
    Write-Host "  $($_.Exception.Message)" -ForegroundColor Red
    return $false
  }
}

#=========================== 1. DETECCAO ========================================
$EhAdmin = $false
try {
  $EhAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
} catch {}
if (-not $EhAdmin) {
  Write-Host " AVISO: sessao SEM privilegio administrativo. Task Scheduler, Veeam e msdb" -ForegroundColor Yellow
  Write-Host "        podem retornar vazio ou parcial. Isso sera registrado como pendencia." -ForegroundColor Yellow
}

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

# Pasta de trabalho so e criada aqui, ja com cliente e hora no nome. Duas coletas
# no mesmo host e no mesmo dia, para clientes diferentes, nao se misturam mais.
$ClienteSan = ($Cliente -replace '[\\/:*?"<>|]','_') -replace '\s+','_'
$Work = Join-Path $BaseDir ("wisedb_coleta_{0}_{1}_{2}" -f $ClienteSan, $Hostn, $Carimbo)
$Tmp = Join-Path $Work ".modulos"
New-Item -ItemType Directory -Force -Path $Tmp | Out-Null
$Cliente | Out-File (Join-Path $Work ".cliente") -Encoding utf8
Diga "Pasta de trabalho desta coleta: $Work"

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
function Roda($nome, $mod, $args2) {
  $t0 = Get-Date
  Diga "Iniciando $nome"
  try {
    if ($args2 -and $args2.Count -gt 0) { & $mod @args2 } else { & $mod }
    Diga ("$nome concluido em {0}s" -f [int]((Get-Date) - $t0).TotalSeconds)
  } catch {
    Write-Host "ERRO durante $nome : $($_.Exception.Message)" -ForegroundColor Red
    $script:ModulosFalharam += $nome
  }
}

Push-Location $Work
Write-Host "`n--- COLETA (somente leitura) -------------------------------------------"
Write-Host "Cada modulo grava em arquivo e mostra o progresso abaixo. Nao interrompa."
if ($Det.sqlserver.on -or $Det.windows.on) {
  $mod = DL "04_coleta_sqlserver_windows.ps1"
  if ($mod) {
    # Em servidor VBR o bloco Veeam do 04 duplicaria a varredura de sessoes feita
    # pelo 06, que e a chamada mais cara da coleta.
    $p = @{}
    if ($Det.veeamvbr.on) { $p = @{ SkipVeeam = $true } }
    Roda "modulo 04 (Windows/SQL Server)" $mod $p
  } else { $ModulosFalharam += "04_coleta_sqlserver_windows.ps1(download)" }
}
if ($Det.veeamvbr.on) {
  $mod = DL "06_coleta_veeam_vbr.ps1"
  if ($mod) { Roda "modulo 06 (Veeam B&R)" $mod $null }
  else { $ModulosFalharam += "06_coleta_veeam_vbr.ps1(download)" }
}
if ($Det.hyperv.on -or ($Det.vmware.on -and $VCenter)) {
  $mod = DL "07_coleta_hypervisor_windows.ps1"
  if ($mod) { Roda "modulo 07 (Hypervisor)" $mod @{ VCenter = $VCenter } }
  else { $ModulosFalharam += "07_coleta_hypervisor_windows.ps1(download)" }
}
Pop-Location

# Registro explicito do nivel de privilegio, para quem le a politica saber se
# Task Scheduler, msdb e Veeam foram de fato auditados.
$priv = @()
$priv += "## NIVEL DE PRIVILEGIO DESTA COLETA"
$priv += "## Usuario .........: $env:USERDOMAIN\$env:USERNAME"
$priv += "## Administrador ...: $(if ($EhAdmin) {'SIM'} else {'NAO'})"
if (-not $EhAdmin) {
  $priv += "## [PENDENCIA] Sem privilegio administrativo: tarefas do Task Scheduler,"
  $priv += "## [PENDENCIA] consulta ao msdb e cmdlets do Veeam podem ter retornado"
  $priv += "## [PENDENCIA] vazio ou parcial. Revalidar antes de fechar a politica."
}
$priv += "## Pasta de trabalho: $Work"
$priv += "## Modulos com falha: $(if ($ModulosFalharam.Count -eq 0) {'nenhum'} else {$ModulosFalharam -join ', '})"
$priv | Out-File (Join-Path $Work "nivel_privilegio_coleta.txt") -Encoding utf8

#=========================== 4. SANITIZACAO =====================================
Diga "Sanitizando evidencias (remocao de segredos)"
Get-ChildItem $Work -Recurse -Include *.txt,*.log,*.json | ForEach-Object {
  $c = Get-Content $_.FullName -Raw
  $c = $c -replace '(?i)((password|passwd|pwd|secret|token|apikey)\s*[=:]\s*)[^\s",]+', '$1***REMOVIDO***'
  Set-Content $_.FullName $c -Encoding utf8
}

#=========================== 5. CONSOLIDACAO ====================================
Diga "Consolidando resultado_final.txt"
$FinalTxt = Join-Path $Work "resultado_final.txt"
$cab = @"
================================================================
 WISEDB - COLETA AUTOMATICA | Cliente: $Cliente | Host: $Hostn
 Data da coleta: $(Get-Date -Format 'dd/MM/yyyy HH:mm') | Script v$Versao
 PowerShell: $($PSVersionTable.PSVersion) | SO: $([Environment]::OSVersion.VersionString)
 Privilegio administrativo: $(if ($EhAdmin) {'SIM'} else {'NAO - evidencias podem estar parciais'})
 RPO informado: $RPO | RTO informado: $RTO
 Itens fora do escopo declarados no wizard: $(if ($Excluidos.Count -eq 0){'(nenhum)'} else {($Excluidos | ForEach-Object { "$($_.item) [$($_.justificativa)]" }) -join '; '})
 Modulos com falha: $(if ($ModulosFalharam.Count -eq 0){'nenhum'} else {$ModulosFalharam -join ', '})
================================================================
"@
$cab | Out-File $FinalTxt -Encoding utf8
Get-ChildItem $Work -Recurse -Filter *.txt | Where-Object Name -ne 'resultado_final.txt' | Sort-Object FullName | ForEach-Object {
  "`n########## ARQUIVO: $($_.FullName.Replace($Work,'')) ##########" | Out-File $FinalTxt -Append -Encoding utf8
  Get-Content $_.FullName | Out-File $FinalTxt -Append -Encoding utf8
}
$Pendencias = @()
if ($RPO -like 'A combinar*') { $Pendencias += "RPO nao definido formalmente" }
if ($RTO -like 'A combinar*') { $Pendencias += "RTO nao definido formalmente" }
if (-not $EhAdmin) { $Pendencias += "Coleta sem privilegio administrativo: agendamentos e msdb podem estar parciais" }
if ($ModulosFalharam.Count -gt 0) { $Pendencias += "Modulos com falha: $($ModulosFalharam -join ', ')" }
[ordered]@{
  schema = "wisedb.coleta.backup/v1"; cliente = $Cliente
  coleta = @{ host = $Hostn; data = (Get-Date -Format s); script_versao = $Versao; modo = "automatico"
              pasta = $Work; administrador = $EhAdmin
              powershell = $PSVersionTable.PSVersion.ToString(); so = [Environment]::OSVersion.VersionString }
  deteccao = @{}; escopo = @{ fora_do_escopo = $Excluidos }
  rpo_informado = $RPO; rto_informado = $RTO
  pendencias = $Pendencias
  evidencias_arquivos = @(Get-ChildItem $Work -Recurse -Filter *.txt | ForEach-Object { $_.FullName.Replace("$Work\","") })
} | ForEach-Object { $j = $_; foreach ($k in $Keys) { $j.deteccao[$k] = $Det[$k].on }; $j } |
  ConvertTo-Json -Depth 5 | Out-File (Join-Path $Work "resultado.json") -Encoding utf8

# ---- RESUMO COMPACTO (opcional: so quando ha Python neste host) --------------
$Resumo = Join-Path $Work ("RESUMO_{0}_{1}.txt" -f $ClienteSan, $Hostn)
$Py = $null
foreach ($cand in @('python','python3','py')) { if (Test-Cmd $cand) { $Py = $cand; break } }
if ($Py) {
  $dg = DL "wisedb_digest.py"
  if ($dg) {
    Diga "Gerando RESUMO com $Py"
    try { & $Py $dg $Work $Cliente "HOST_DO_CLIENTE" $Resumo } catch { Write-Host "  Digest nao gerado: $($_.Exception.Message)" -ForegroundColor Yellow }
    if ((Test-Path $Resumo) -and -not (Select-String -Path $Resumo -Pattern '^== (SERVIDOR|ORACLE|SQL SERVER|VEEAM|OCI)' -Quiet)) {
      Write-Host "  AVISO: RESUMO sem secoes de evidencia. Use o resultado_final.txt" -ForegroundColor Yellow
    }
  }
}

#=========================== 6. RESUMO + OK =====================================
Write-Host "`n=============================== RESUMO ================================"
Write-Host " Cliente: $Cliente | Host: $Hostn"
Write-Host " Pasta de trabalho: $Work"
Write-Host " Arquivos de evidencia: $((Get-ChildItem $Work -Recurse -Filter *.txt).Count)"
Write-Host " Fora do escopo: $($Excluidos.Count) item(ns) | RPO: $RPO | RTO: $RTO"
Write-Host (" Tempo total: {0} min" -f [int]((Get-Date) - $Inicio).TotalMinutes)
if ($ModulosFalharam.Count -gt 0) { Write-Host " Modulos com falha: $($ModulosFalharam -join ', ')" -ForegroundColor Yellow }
$rest = Get-ChildItem $Work -Recurse -Filter *.txt -ErrorAction SilentlyContinue |
  Select-String -Pattern 'password|passwd|secret|token' -ErrorAction SilentlyContinue |
  Where-Object { $_.Line -notmatch 'REMOVIDO' } | Select-Object -First 5
if ($rest) { Write-Host " ATENCAO - revisar antes de enviar:"; $rest | ForEach-Object { Write-Host "   $($_.Path):$($_.LineNumber)" } }
else { Write-Host " Verificacao de segredos: nenhum remanescente" }
Write-Host "========================================================================"
$ok = Read-Host "Gerar pacote final? (S/n)"
if ($ok -ne 'n' -and $ok -ne 'N') {
  $zip = Join-Path $BaseDir ("wisedb_coleta_{0}_{1}_{2}.zip" -f $ClienteSan, $Hostn, $Carimbo)
  $gerado = New-WiseZip -SourceDir $Work -ZipPath $zip
  Write-Host "`nPRONTO."
  if ($gerado) { Write-Host "  1) Pacote completo : $zip" }
  else { Write-Host "  1) Pacote NAO gerado - compacte manualmente a pasta $Work" -ForegroundColor Yellow }
  if (Test-Path $Resumo) { Write-Host "  2) COLE ISTO NA IA : $Resumo" }
  Write-Host "  3) Bruto completo  : $FinalTxt (+ resultado.json)"
  Write-Host "  Cole o conteudo na IA junto com o Modelo_Politica_de_Backup_WiseDB.md"
  Write-Host "  e o prompt Backup Policy Engineer para gerar a politica e o PDF."
} else { Write-Host "Pacote nao gerado. Arquivos em $Work para revisao." }
