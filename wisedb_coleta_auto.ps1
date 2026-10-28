<#
===============================================================================
 wisedb_coleta_auto.ps1 - WiseDB | Coleta AUTOMATICA para Politica de Backup

 CONCEITO : Automatico first. Um unico comando no servidor Windows (PS admin):

   irm https://raw.githubusercontent.com/cainawisedb/wisedb-kit/main/wisedb_coleta_auto.ps1 | iex

 SEM INTERNET : copie a pasta inteira do kit para o servidor e rode de dentro dela:
   powershell -ExecutionPolicy Bypass -File .\wisedb_coleta_auto.ps1
   Rodando de um arquivo numa pasta com os modulos, NADA e buscado na rede.
   $env:WISEDB_OFFLINE='1' forca o modo local; $env:WISEDB_KIT_DIR aponta o kit.

 FLUXO    : 1) DETECTA: SQL Server, Veeam B&R, Veeam Agent, Hyper-V, PowerCLI
            2) WIZARD de confirmacao + cliente + itens fora do escopo
            3) CRIA a pasta de trabalho com nome do cliente e hora da coleta
            4) BAIXA da mesma origem os modulos necessarios (04, 06, 07a)
            5) Executa a coleta read-only, SANITIZA, mostra RESUMO e pede OK
            6) GERA resultado_final.txt (colar na IA), resultado.json e .zip
 RISCO    : Zero. Somente leitura.

 v2.6 (outubro/2026) - vulnerabilidades e inconformidades (igual ao Linux v4.0)
   [NOVO]     Modulo 13 Windows: unidade de rede de backup mapeada, shares e
              pastas de backup com escrita ampla, SMBv1, firewall, RDP sem NLA,
              antivirus/EDR, Windows fora de suporte e sem atualizacao. Entra na
              matriz VUL-xxx do digest 2.6 e no insumo comercial interno.

 v2.5 (outubro/2026) - modo local real, igual ao Linux v3.9
   [NOVO]     Origem dos modulos: LOCAL quando o script roda de um arquivo numa
              pasta com os modulos (zero rede); GITHUB quando vem por irm|iex,
              com fallback automatico para a copia local se o download falhar.
   [CORRIGIDO] Pasta do proprio script ($PSScriptRoot) passa a ser procurada;
              antes so a pasta atual e .\kit_coleta_backup.
   [CORRIGIDO] Download com -TimeoutSec e, apos a primeira falha, os demais
              modulos vao direto para a copia local (sem esperar de novo).
   [NOVO]     Unblock-File nos modulos copiados (arquivo vindo de ZIP baixado).

 v2.4 (outubro/2026)
   [CRITICO]  Mascara igual a do Linux v3.8: mysqldump -pSENHA, rman target
              user/senha, sqlplus/expdp user/senha local e cipher-pass.
   [NOVO]     Modulo 04 v1.3 (historico de RESTORE, lacuna de log, checksum,
              criptografia/TDE, CHECKDB, Always On), 06 v1.2 (SureBackup,
              restauracoes, backup da configuracao) e 10 v1.1 (retencao real,
              TDE, standby; corrigida a classificacao do SBT).
   [ALTERADO] PostgreSQL/MySQL em Windows continuam como alerta: os coletores
              11/12 existem so para Linux.

 v2.3 (outubro/2026) - rodada de testes multiplataforma
   [CRITICO]  Mascara de segredos igual a do Linux v3.7 (SENHA, KEY, aspas,
              --password, -P do sqlcmd, user/senha@, Bearer, chave AWS). Pacote
              exige confirmacao se sobrar segredo.
   [CORRIGIDO] RESUMO nunca era gerado no Windows (digest usava os.uname).
   [NOVO]     Oracle no Windows (modulo 10), instancias SQL nomeadas (modulo 04),
              alerta para PostgreSQL, MySQL/MariaDB e Veeam Agent standalone.
   [ALTERADO] RPO/RTO deixam de ser perguntados: A DEFINIR (igual ao Linux).
   [NOVO]     escopo_wizard.txt (exclusoes/justificativas/alertas) vai ao RESUMO.
   [CORRIGIDO] Modulos locais (modo offline) eram procurados na pasta de
              trabalho; agora na pasta de onde o script foi chamado.
   [CORRIGIDO] Requisito real declarado: PowerShell 3.0+ (WMF 3.0/5.1 no 2008 R2).

 COMPATIBILIDADE : PowerShell 3.0+ (Windows Server 2008 R2 com WMF 3.0+, 2012, 2012 R2, 2016+)
            Compress-Archive (PS 5.0+) substituido por New-WiseZip, com cadeia
            de fallback: Compress-Archive -> System.IO.Compression.FileSystem
            (.NET 4.5) -> Shell.Application (COM, funciona em qualquer versao).
===============================================================================
#>
# TLS 1.2 obrigatorio: Windows 2008R2/2012R2 negociam TLS 1.0 por padrao no .NET e o GitHub recusa
try { [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor 3072 } catch {}

$BaseUrl = if ($env:WISEDB_BASE_URL) { $env:WISEDB_BASE_URL } else { "https://raw.githubusercontent.com/cainawisedb/wisedb-kit/main" }
$Versao = "2.6"
if ($PSVersionTable.PSVersion.Major -lt 3) {
  Write-Host "ERRO: PowerShell $($PSVersionTable.PSVersion) detectado. O kit exige 3.0+." -ForegroundColor Red
  Write-Host "Instale o WMF 5.1 (KB3191566) ou rode os modulos 04/06/07 manualmente." -ForegroundColor Red
  exit 1
}
$OrigDir = (Get-Location).Path
# Origem dos modulos (v2.5): pasta local do kit ou GitHub com fallback local
function Test-Kit($d) { if ($d) { Test-Path (Join-Path $d '04_coleta_sqlserver_windows.ps1') } else { $false } }
$SelfDir = if ($PSScriptRoot) { $PSScriptRoot } else { $null }
$KitDir = $null
foreach ($c in @($env:WISEDB_KIT_DIR, $SelfDir, $OrigDir, (Join-Path $OrigDir 'kit_coleta_backup'))) {
  if (Test-Kit $c) { $KitDir = (Resolve-Path $c).Path; break }
}
if ($env:WISEDB_OFFLINE -eq '1' -or (Test-Kit $env:WISEDB_KIT_DIR) -or (Test-Kit $SelfDir)) { $Origem = 'LOCAL' } else { $Origem = 'GITHUB' }
if ($Origem -eq 'LOCAL' -and -not $KitDir) {
  Write-Host "ERRO: modo local pedido, mas nenhuma pasta com os modulos foi encontrada." -ForegroundColor Red
  Write-Host "Rode de dentro da pasta do kit: powershell -ExecutionPolicy Bypass -File .\wisedb_coleta_auto.ps1" -ForegroundColor Red
  exit 1
}
$script:NetOk = $true
$Alertas = @()
$Hostn = $env:COMPUTERNAME
$Data = Get-Date -Format yyyyMMdd
$Carimbo = Get-Date -Format 'yyyyMMdd_HHmm'
$Inicio = Get-Date
$ModulosFalharam = @()

Write-Host "==============================================================="
Write-Host " WiseDB - Coleta Automatica de Backup v$Versao | $Hostn | $(Get-Date -Format 'dd/MM/yyyy HH:mm')"
Write-Host " PowerShell $($PSVersionTable.PSVersion) | $([Environment]::OSVersion.VersionString)"
if ($Origem -eq 'LOCAL') { Write-Host " Modulos: pasta local $KitDir (nenhum acesso a rede para buscar modulos)" -ForegroundColor Green }
else { Write-Host " Modulos: GitHub ($BaseUrl)$(if ($KitDir) { "; reserva local em $KitDir" })" }
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

function Svc($padrao) { @(Get-Service -Name $padrao -ErrorAction SilentlyContinue | Where-Object { $_.Status -eq 'Running' }) }
$Det = [ordered]@{
  windows   = @{ on = $true;  desc = "Servidor Windows (Task Scheduler, discos, mapeamentos)" }
  sqlserver = @{ on = [bool](Get-Service -Name 'MSSQL*' -ErrorAction SilentlyContinue | Where-Object Status -eq 'Running'); desc = "SQL Server (servico ativo)" }
  veeamvbr  = @{ on = [bool](Get-Service -Name 'VeeamBackupSvc' -ErrorAction SilentlyContinue); desc = "Veeam Backup & Replication (servidor)" }
  hyperv    = @{ on = [bool](Get-Service -Name 'vmms' -ErrorAction SilentlyContinue | Where-Object Status -eq 'Running'); desc = "Hyper-V (host)" }
  vmware    = @{ on = [bool](Get-Module -ListAvailable VMware.PowerCLI); desc = "VMware PowerCLI disponivel (coleta via vCenter)" }
  oracle    = @{ on = [bool](Svc 'OracleService*'); desc = "Oracle Database (servico OracleService* ativo)" }
}
$Keys = @($Det.Keys)
Write-Host "`nComponentes detectados automaticamente:"
for ($i=0; $i -lt $Keys.Count; $i++) {
  $m = if ($Det[$Keys[$i]].on) { "[X]" } else { "[ ]" }
  Write-Host ("  {0}) {1} {2}" -f ($i+1), $m, $Det[$Keys[$i]].desc)
}

# Componentes sem coletor automatico: viram alerta e pendencia explicita, para a
# IA nunca concluir "sem backup" por ausencia de evidencia.
foreach ($x in @(@('postgresql*','PostgreSQL','pg_dump/pgBackRest/Barman e agendamento'),
                 @('MySQL*','MySQL','mysqldump/xtrabackup e agendamento'),
                 @('MariaDB*','MariaDB','mariadb-dump/mariabackup e agendamento'),
                 @('VeeamEndpointBackupSvc','Veeam Agent for Windows (standalone)','job, destino e ultimos resultados do Agent (console ou print)'))) {
  $sv = Svc $x[0]
  if ($sv.Count -gt 0) {
    $a = "$($x[1]) ativo ($(($sv | ForEach-Object { $_.Name }) -join ', ')) sem coletor automatico para Windows (no Linux: modulos 11/12): anexar manualmente $($x[2])"
    $Alertas += $a; Write-Host "  ! $a" -ForegroundColor Yellow
  }
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
# RPO/RTO acordados nao sao perguntados (igual ao Linux v3.6+): A DEFINIR, sem default.
$RPO = "A DEFINIR"; $RTO = "A DEFINIR"
$VCenter = ""
if ($Det.vmware.on) { $VCenter = Read-Host "Endereco do vCenter (ENTER para pular VMware)" }

# Pasta de trabalho so e criada aqui, ja com cliente e hora no nome. Duas coletas
# no mesmo host e no mesmo dia, para clientes diferentes, nao se misturam mais.
$ClienteSan = ($Cliente -replace '[\\/:*?"<>|]','_') -replace '\s+','_'
$Work = Join-Path $BaseDir ("wisedb_coleta_{0}_{1}_{2}" -f $ClienteSan, $Hostn, $Carimbo)
$Tmp = Join-Path ([IO.Path]::GetTempPath()) ("wisedb_mod_" + $PID)
New-Item -ItemType Directory -Force -Path $Work | Out-Null
New-Item -ItemType Directory -Force -Path $Tmp | Out-Null
$Cliente | Out-File (Join-Path $Work ".cliente") -Encoding utf8
Diga "Pasta de trabalho desta coleta: $Work"

#=========================== 3. MODULOS + COLETA ================================
function DL($m) {
  $dst = Join-Path $Tmp $m
  $loc = if ($KitDir) { Join-Path $KitDir $m } else { $null }
  $ok = $false
  if ($Origem -eq 'LOCAL') {
    if ($loc -and (Test-Path $loc)) { Copy-Item $loc $dst -Force; $ok = $true }
    else { Write-Host "ERRO: modulo $m nao esta na pasta do kit ($KitDir)" -ForegroundColor Red; return $null }
  } else {
    if ($script:NetOk) {
      try {
        Invoke-WebRequest -Uri "$BaseUrl/$m" -OutFile $dst -UseBasicParsing -TimeoutSec 30 -ErrorAction Stop
        $ok = (Test-Path $dst) -and ((Get-Item $dst).Length -gt 0)
      } catch {
        $script:NetOk = $false
        Write-Host "AVISO: falha ao baixar $m de $BaseUrl ($($_.Exception.Message))" -ForegroundColor Yellow
      }
    }
    if (-not $ok -and $loc -and (Test-Path $loc)) {
      Write-Host "AVISO: usando a copia local de $m em $KitDir" -ForegroundColor Yellow
      Copy-Item $loc $dst -Force; $ok = $true
    }
  }
  if (-not $ok -or -not (Test-Path $dst)) { Write-Host "ERRO: modulo $m indisponivel (GitHub e copia local), etapa ignorada" -ForegroundColor Red; return $null }
  if (Get-Command Unblock-File -ErrorAction SilentlyContinue) { try { Unblock-File -Path $dst -ErrorAction Stop } catch {} }
  return $dst
}
function Roda($nome, $mod, $args2) {
  $t0 = Get-Date
  Diga "Iniciando $nome"
  try {
    $global:LASTEXITCODE = 0
    if ($args2 -and $args2.Count -gt 0) { & $mod @args2 } else { & $mod }
    if ($LASTEXITCODE -ne 0) {
      Write-Host "ERRO: $nome terminou com codigo $LASTEXITCODE (coleta parcial)" -ForegroundColor Red
      $script:ModulosFalharam += "$nome(codigo $LASTEXITCODE)"
    }
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
if ($Det.oracle.on) {
  $mod = DL "10_coleta_oracle_windows.ps1"
  if ($mod) { Roda "modulo 10 (Oracle Windows)" $mod $null }
  else { $ModulosFalharam += "10_coleta_oracle_windows.ps1(download)" }
}
# Seguranca e conformidade do backup (modulo 13, v2.6)
  $mod = DL "13_coleta_seguranca_windows.ps1"
  if ($mod) { Roda "modulo 13 (Seguranca e conformidade)" $mod $null }
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
# Mesmas regras do wisedb_coleta_auto.sh v3.7 (a v2.2 nao cobria SENHA, KEY, aspas, -P, user/senha@).
Diga "Sanitizando evidencias (remocao de segredos)"
$escopo = @("Cliente ............: $Cliente", "Modo da coleta .....: COMPLETA (Windows)", "Papel do host ......: HOST_DO_CLIENTE",
            "Usuario / admin ....: $env:USERDOMAIN\$env:USERNAME / $(if ($EhAdmin) {'SIM'} else {'NAO'})",
            "Coleta incompleta ..: $(if ($ModulosFalharam.Count) {'SIM (' + ($ModulosFalharam -join ', ') + ')'} else {'NAO'})",
            "Fora do escopo (declarado pelo operador, NAO tratar como servico assegurado):")
if ($Excluidos.Count -eq 0) { $escopo += "  (nenhum)" } else { $Excluidos | ForEach-Object { $escopo += "  - $($_.item) | Justificativa: $($_.justificativa)" } }
$escopo += "Alertas do wizard:"
if ($Alertas.Count -eq 0) { $escopo += "  (nenhum)" } else { $Alertas | ForEach-Object { $escopo += "  ! $_" } }
$escopo | Out-File (Join-Path $Work "escopo_wizard.txt") -Encoding utf8

function Protect-WiseText([string]$c) {
  if ($null -eq $c) { return $c }
  $c = $c -replace '((?:[A-Za-z0-9_.-]*)(?:password|passwd|pwd|senha|secret|token|passphrase|pass_phrase|cipher[-_]?pass|credential|api_?key|access_?key|key_id|keyid|private_?key|key)["'']?\s*[=:]\s*)("[^"]*"|''[^'']*''|[^\s",;]+)', '$1***REMOVIDO***'
  $c = $c -replace '(--?(?:password|passwd|pwd|senha|token|secret)\s+)("[^"]*"|''[^'']*''|[^-\s]\S*)', '$1***REMOVIDO***'
  $c = $c -replace '(identified\s+by\s+)("[^"]*"|[^\s;]+)', '$1***REMOVIDO***'
  $c = $c -replace '(//[^/:@\s]+:)[^@\s]+(@)', '$1***REMOVIDO***$2'
  $c = $c -replace '([A-Za-z0-9_.$]+)/[^\s/@"''*]{2,}@', '$1/***REMOVIDO***@'
  $c = $c -replace '([A-Za-z0-9_.$]+)/[^\s/@"''*]{2,}(\s+as\s+sys)', '$1/***REMOVIDO***$2'
  $c = $c -replace '((?:connect|conn)\s+(?:(?:target|auxiliary|catalog)\s+)?["'']?[A-Za-z0-9_.$]+)/[^\s@"'']+', '$1/***REMOVIDO***'
  $c = $c -replace '((?:^|\s)(?:target|auxiliary|catalog)(?:\s+|\s*=\s*)["'']?[A-Za-z0-9_.$]+)/[^\s@"'']+', '$1/***REMOVIDO***'
  $c = $c -creplace '((?:sqlplus|sqlldr|expdp|impdp|exp|imp|dgmgrl)(?:\s+-[A-Za-z]+)*\s+["'']?[A-Za-z0-9_.$]+)/[^\s@"'']+', '$1/***REMOVIDO***'
  $c = $c -creplace '(sqlcmd[^|;\r\n]*\s-P\s*)("[^"]*"|''[^'']*''|[^\s-]\S*)', '$1***REMOVIDO***'
  $c = $c -creplace '(\s-P\s+)("[^"]*"|''[^'']*''|[^\s-]\S*)', '$1***REMOVIDO***'
  $c = $c -creplace '((?:mysql|mysqldump|mysqladmin|mysqlpump|mysqlcheck|mysqlbinlog|mariadb|mariadb-dump|mariadb-admin|mariabackup|xtrabackup|innobackupex|mydumper|myloader)(?:\.exe)?[^|;\r\n]*\s-p)("[^"]*"|''[^'']*''|[^\s"''-]\S*)', '$1***REMOVIDO***'
  $c = $c -replace '(Bearer\s+)[A-Za-z0-9._~+/=-]{8,}', '$1***REMOVIDO***'
  $c = $c -creplace '(AKIA|ASIA)[0-9A-Z]{16}', '$1***REMOVIDO***'
  return $c
}
Get-ChildItem $Work -Recurse -Include *.txt,*.log,*.json,*.tsv,*.csv,*.ora,*.bat,*.cmd,*.ps1,*.sql | ForEach-Object {
  $c = [IO.File]::ReadAllText($_.FullName)
  $n = Protect-WiseText $c
  if ($n -ne $c) { [IO.File]::WriteAllText($_.FullName, $n, (New-Object Text.UTF8Encoding($false))) }
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
$Pendencias += "RPO e RTO A DEFINIR com o cliente"
$Alertas | ForEach-Object { $Pendencias += $_ }
if (-not $EhAdmin) { $Pendencias += "Coleta sem privilegio administrativo: agendamentos e msdb podem estar parciais" }
if ($ModulosFalharam.Count -gt 0) { $Pendencias += "Modulos com falha: $($ModulosFalharam -join ', ')" }
[ordered]@{
  schema = "wisedb.coleta.backup/v2"; cliente = $Cliente
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
# Valida que o interpretador roda de fato: o atalho da Microsoft Store (WindowsApps)
# existe no PATH mas nao executa nada.
foreach ($cand in @('py','python','python3')) {
  if (Test-Cmd $cand) {
    try { $v = (& $cand --version 2>&1 | Out-String); if ($LASTEXITCODE -eq 0 -and $v -match 'Python 3') { $Py = $cand; break } } catch { }
  }
}
if (-not $Py) { Write-Host " AVISO: Python 3 indisponivel: RESUMO nao sera gerado aqui. Gere-o no bastion: python3 wisedb_digest.py <pasta> <cliente> HOST_DO_CLIENTE" -ForegroundColor Yellow }
if ($Py) {
  $dg = DL "wisedb_digest.py"
  if ($dg) {
    Diga "Gerando RESUMO com $Py"
    try { & $Py $dg $Work $Cliente "HOST_DO_CLIENTE" $Resumo } catch { Write-Host "  Digest nao gerado: $($_.Exception.Message)" -ForegroundColor Yellow }
    if ((Test-Path $Resumo) -and -not (Select-String -Path $Resumo -Pattern '^== (SERVIDOR|ORACLE|SQL SERVER|VEEAM|OCI|HYPERVISOR|NUVEM)' -Quiet)) {
      Write-Host "  AVISO: RESUMO sem secoes de evidencia. Use o resultado_final.txt" -ForegroundColor Yellow
    }
  }
}

Remove-Item $Tmp -Recurse -Force -ErrorAction SilentlyContinue

#=========================== 6. RESUMO + OK =====================================
Write-Host "`n=============================== RESUMO ================================"
Write-Host " Cliente: $Cliente | Host: $Hostn"
Write-Host " Pasta de trabalho: $Work"
Write-Host " Arquivos de evidencia: $((Get-ChildItem $Work -Recurse -Filter *.txt).Count)"
Write-Host " Fora do escopo: $($Excluidos.Count) item(ns) | RPO: $RPO | RTO: $RTO"
Write-Host (" Tempo total: {0} min" -f [int]((Get-Date) - $Inicio).TotalMinutes)
if ($ModulosFalharam.Count -gt 0) { Write-Host " Modulos com falha: $($ModulosFalharam -join ', ')" -ForegroundColor Yellow }
$rest = @(Get-ChildItem $Work -Recurse -Include *.txt,*.log,*.json -ErrorAction SilentlyContinue |
  Select-String -Pattern '(password|passwd|senha|secret|token|api_?key|access_?key)["'']?\s*[=:]\s*["'']?[^*\s"'']' -ErrorAction SilentlyContinue |
  Where-Object { $_.Line -notmatch 'REMOVIDO' } | Select-Object -First 10)
Write-Host "========================================================================"
if ($rest.Count -gt 0) {
  Write-Host " POSSIVEL SEGREDO NAO MASCARADO ($($rest.Count) linha(s)):" -ForegroundColor Red
  $rest | ForEach-Object { Write-Host "   $($_.Path.Replace($Work,'')):$($_.LineNumber)" }
  $ok = Read-Host "Gerar o pacote MESMO ASSIM? (s/N)"
  if ($ok -ne 's' -and $ok -ne 'S') { $ok = 'n' }
} else {
  Write-Host " Verificacao de segredos: nenhum remanescente"
  $ok = Read-Host "Gerar pacote final? (S/n)"
}
if ($ok -ne 'n' -and $ok -ne 'N') {
  $zip = Join-Path $BaseDir ("wisedb_coleta_{0}_{1}_{2}.zip" -f $ClienteSan, $Hostn, $Carimbo)
  $gerado = New-WiseZip -SourceDir $Work -ZipPath $zip
  Write-Host "`nPRONTO."
  if ($gerado) { Write-Host "  1) Pacote completo : $zip" }
  else { Write-Host "  1) Pacote NAO gerado - compacte manualmente a pasta $Work" -ForegroundColor Yellow }
  if (Test-Path $Resumo) { Write-Host "  2) COLE ISTO NA IA : $Resumo" -ForegroundColor Green }
  else { Write-Host "  2) RESUMO nao gerado: anexe o resultado_final.txt ou gere o RESUMO no bastion" -ForegroundColor Yellow }
  Write-Host "  3) Bruto completo  : $FinalTxt (+ resultado.json)"
  Write-Host "  Anexe o RESUMO no Projeto 'Confeccao de politicas de backups' do Claude,"
  Write-Host "  junto com o Painel e a politica anterior (ver Manual M-001 v2.0)."
} else { Write-Host "Pacote nao gerado. Arquivos em $Work para revisao." }
