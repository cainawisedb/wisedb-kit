<#
===============================================================================
 13_coleta_seguranca_windows.ps1 - WiseDB | Varredura de seguranca e
 conformidade do backup em Windows (vulnerabilidades e inconformidades)

 OBJETIVO : Mesmo formato do modulo 13 Linux. Verifica, com evidencia:
            - repositorio de backup exposto (unidade de rede mapeada, share de
              backup com escrita para Todos/Usuarios, pasta de backup com
              escrita ampla)
            - SMBv1, firewall desligado, RDP sem NLA, antivirus/EDR ausente
            - Windows fora de suporte e sem atualizacao
 SAIDA    : .\coleta_<host>_<data>\13_seguranca\achados.tsv e evidencias.txt
 RISCO    : Zero. Somente leitura (WMI, registro, ACL).
 COMPAT.  : PowerShell 3.0+. Grupos avaliados por SID (independe do idioma).
 EXECUCAO : powershell -ExecutionPolicy Bypass -File .\13_coleta_seguranca_windows.ps1

 Versao 1.0 (outubro/2026)
===============================================================================
#>
param([string]$Saida = "")
$ErrorActionPreference = 'SilentlyContinue'
$Hostn = $env:COMPUTERNAME
if (-not $Saida) { $Saida = Join-Path (Get-Location).Path ("coleta_{0}_{1}\13_seguranca" -f $Hostn, (Get-Date -Format yyyyMMdd)) }
New-Item -ItemType Directory -Force -Path $Saida | Out-Null
$Ach = Join-Path $Saida 'achados.tsv'; $Ev = Join-Path $Saida 'evidencias.txt'
$script:N = 0; $script:Linhas = New-Object System.Collections.ArrayList
[void]$script:Linhas.Add("ID`tSEVERIDADE`tCATEGORIA`tPILAR_32110`tCHAVE`tTITULO`tEVIDENCIA`tIMPACTO`tRECOMENDACAO`tOPORTUNIDADE`tHOST")
"" | Set-Content -Path $Ev -Encoding UTF8
$BkpRx = 'backup|bkp|bck|rman|dump|veeam|repositor|bkup'
# SIDs amplos: Todos, Usuarios autenticados, Usuarios, Convidados
$SidAmplo = @('S-1-1-0','S-1-5-11','S-1-5-32-545','S-1-5-32-546')

function Limpa([string]$t) { $x = ($t -replace "[`t`r`n]+", ' ').Trim(); if ($x.Length -gt 400) { $x = $x.Substring(0,400) }; $x }
function Achado($sev, $cat, $pilar, $chave, $opp, $tit, $evid, $imp, $rec) {
  $script:N++
  $l = "SEG-{0:D3}`t{1}`t{2}`t{3}`t{4}`t{5}`t{6}`t{7}`t{8}`t{9}`t{10}" -f $script:N, $sev, $cat, $pilar, $chave, (Limpa $tit), (Limpa $evid), (Limpa $imp), (Limpa $rec), $opp, $Hostn
  [void]$script:Linhas.Add($l)
  Write-Host ("  [{0,-7}] {1}" -f $sev, $tit)
}
function Evid($titulo, $texto) { Add-Content -Path $Ev -Value ("################ " + $titulo) -Encoding UTF8; Add-Content -Path $Ev -Value (($texto | Out-String).TrimEnd()) -Encoding UTF8; Add-Content -Path $Ev -Value "" -Encoding UTF8 }
function Reg($path, $name) { try { (Get-ItemProperty -Path $path -Name $name -ErrorAction Stop).$name } catch { $null } }

Write-Host ("[{0}] Varredura de seguranca e conformidade em {1} (saida em {2})" -f (Get-Date -Format HH:mm:ss), $Hostn, $Saida)

#--- 1. Papel do host -----------------------------------------------------------
$svc = @(Get-WmiObject Win32_Service | Where-Object { $_.State -eq 'Running' })
$EDb = [bool]($svc | Where-Object { $_.Name -match '^(MSSQL|OracleService|postgresql|MySQL)' })
$EVeeam = [bool]($svc | Where-Object { $_.Name -match '^Veeam' })
$Papel = 'servidor'; if ($EDb) { $Papel = 'servidor de banco (producao)' }; if ($EVeeam) { $Papel += ' + servidor de backup (Veeam)' }
Evid 'PAPEL DO HOST' ("Papel inferido: $Papel")

#--- 2. Sistema operacional e atualizacoes -------------------------------------
$os = Get-WmiObject Win32_OperatingSystem
$build = [int]$os.BuildNumber; $cap = [string]$os.Caption
Evid 'SISTEMA OPERACIONAL' ("{0} | build {1} | {2}" -f $cap, $build, $os.Version)
if ($build -lt 9200) {
  Achado 'ALTO' 'CICLO_VIDA' '-' 'SO_EOL' 'CICLO_VIDA' 'Windows Server fora de suporte' "$cap (build $build): suporte encerrado em 2020" 'Sem correcoes de seguranca: vulnerabilidades conhecidas permanecem exploraveis' 'Planejar migracao para versao suportada'
} elseif ($build -lt 14393) {
  Achado 'ALTO' 'CICLO_VIDA' '-' 'SO_EOL' 'CICLO_VIDA' 'Windows Server fora de suporte' "$cap (build $build): suporte estendido encerrado em 10/2023 (salvo ESU contratado)" 'Sem correcoes de seguranca regulares' 'Planejar migracao para versao suportada'
} elseif ($build -eq 14393 -and $cap -match 'Server') {
  Achado 'MEDIO' 'CICLO_VIDA' '-' 'SO_EOL' 'CICLO_VIDA' 'Windows Server 2016 proximo do fim do suporte estendido (01/2027)' "$cap (build $build)" 'A partir de 2027 deixa de receber correcoes de seguranca' 'Incluir a migracao no planejamento'
}
try {
  $hf = Get-HotFix | Where-Object { $_.InstalledOn } | Sort-Object InstalledOn -Descending | Select-Object -First 1
  if ($hf) {
    $dias = [int]((Get-Date) - [datetime]$hf.InstalledOn).TotalDays
    Evid 'ATUALIZACOES' ("Ultimo hotfix: {0} em {1:dd/MM/yyyy} ({2} dias)" -f $hf.HotFixID, [datetime]$hf.InstalledOn, $dias)
    if ($dias -gt 180) { Achado 'ALTO' 'HARDENING' '-' 'SO_SEM_PATCH' 'CICLO_VIDA' "Windows sem atualizacao ha $dias dias" ("Ultimo hotfix {0}" -f $hf.HotFixID) 'Vulnerabilidades corrigidas pelo fabricante continuam abertas' 'Estabelecer ciclo mensal de atualizacao com janela e rollback' }
    elseif ($dias -gt 90) { Achado 'MEDIO' 'HARDENING' '-' 'SO_SEM_PATCH' 'CICLO_VIDA' "Windows sem atualizacao ha $dias dias" ("Ultimo hotfix {0}" -f $hf.HotFixID) 'Vulnerabilidades corrigidas pelo fabricante continuam abertas' 'Estabelecer ciclo mensal de atualizacao' }
  }
} catch {}

#--- 3. SMBv1, firewall, RDP ----------------------------------------------------
$smb1 = $null
try { $smb1 = (Get-SmbServerConfiguration -ErrorAction Stop).EnableSMB1Protocol } catch {
  $v = Reg 'HKLM:\SYSTEM\CurrentControlSet\Services\LanmanServer\Parameters' 'SMB1'
  if ($v -eq $null) { $smb1 = ($build -lt 9200) } else { $smb1 = ($v -ne 0) }
}
Evid 'SMBv1' ("SMBv1 habilitado no servidor: {0}" -f $smb1)
if ($smb1) { Achado 'ALTO' 'RANSOMWARE' '-' 'SMB1_ATIVO' 'SEGMENTACAO' 'SMBv1 habilitado' 'Servidor SMB aceita SMBv1' 'Protocolo explorado por ransomware com propagacao em rede (ex.: WannaCry)' 'Desabilitar SMBv1 (Set-SmbServerConfiguration -EnableSMB1Protocol $false) apos validar dependencias' }
$fwOff = @()
foreach ($p in @('DomainProfile','StandardProfile','PublicProfile')) {
  $pol = Reg ("HKLM:\SOFTWARE\Policies\Microsoft\WindowsFirewall\" + $p) 'EnableFirewall'
  $loc = Reg ("HKLM:\SYSTEM\CurrentControlSet\Services\SharedAccess\Parameters\FirewallPolicy\" + $p) 'EnableFirewall'
  $ef = if ($pol -ne $null) { $pol } else { $loc }
  if ($ef -eq 0) { $fwOff += $p }
}
Evid 'FIREWALL' ("Perfis desligados: {0}" -f ($(if ($fwOff) { $fwOff -join ', ' } else { 'nenhum' })))
if ($fwOff.Count -gt 0) {
  $sv = if ($EVeeam) { 'ALTO' } else { 'MEDIO' }
  Achado $sv 'HARDENING' '-' 'FW_INATIVO' 'SEGMENTACAO' 'Firewall do Windows desligado' ("Perfis desligados: " + ($fwOff -join ', ')) 'Servicos expostos a toda a rede, inclusive acesso ao repositorio de backup' 'Ativar o firewall e segmentar a rede de backup'
}
$rdpOff = Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server' 'fDenyTSConnections'
$nla = Reg 'HKLM:\SYSTEM\CurrentControlSet\Control\Terminal Server\WinStations\RDP-Tcp' 'UserAuthentication'
if ($rdpOff -eq 0 -and $nla -eq 0) { Achado 'MEDIO' 'HARDENING' '-' 'RDP_SEM_NLA' 'SEGMENTACAO' 'RDP habilitado sem NLA' 'fDenyTSConnections=0, UserAuthentication=0' 'Tela de logon exposta antes da autenticacao (forca bruta e exploracao)' 'Exigir NLA e restringir RDP a rede de administracao' }

#--- 4. Antivirus / EDR ---------------------------------------------------------
$av = $false
try { $mp = Get-MpComputerStatus -ErrorAction Stop; if ($mp.RealTimeProtectionEnabled) { $av = $true } } catch {}
if (-not $av) { if ($svc | Where-Object { $_.Name -match 'WinDefend|CSFalcon|SentinelAgent|CbDefense|carbonblack|Sophos|McAfee|mfe|ekrn|Symantec|SepMaster|TmListen|ds_agent|kavfs|bdservicehost|CylanceSvc|xagt|Tanium' }) { $av = $true } }
Evid 'ANTIVIRUS/EDR' ("Protecao detectada: {0}" -f $av)
if (-not $av) { Achado $(if ($EVeeam) { 'MEDIO' } else { 'BAIXO' }) 'HARDENING' '-' 'SEM_EDR' 'SEGMENTACAO' 'Nenhum antivirus/EDR ativo detectado' 'Defender sem protecao em tempo real e nenhum servico de EDR conhecido' 'Menor chance de conter ransomware antes de atingir os backups' 'Avaliar EDR nos servidores de banco e de backup' }

#--- 5. Unidades de rede e shares -------------------------------------------------
$map = @()
try { $map += @(Get-WmiObject Win32_NetworkConnection | ForEach-Object { "{0} -> {1} (persistente: {2})" -f $_.LocalName, $_.RemoteName, $_.Persistent }) } catch {}
try { $map += @(Get-WmiObject Win32_MappedLogicalDisk | ForEach-Object { "{0} -> {1}" -f $_.Name, $_.ProviderName }) } catch {}
$map = @($map | Sort-Object -Unique)
Evid 'UNIDADES DE REDE' ($(if ($map) { $map } else { 'nenhuma no contexto deste usuario' }))
$mapBkp = @($map | Where-Object { $_ -match $BkpRx })
if ($mapBkp.Count -gt 0) {
  $sv = if ($EDb) { 'CRITICO' } else { 'ALTO' }
  Achado $sv 'RANSOMWARE' '1-IMUT' 'REPO_MONTADO_RW_PRODUCAO' 'IMUTAVEL' "Repositorio de backup mapeado como unidade de rede neste servidor ($Papel)" ($mapBkp -join '; ') 'Ransomware neste servidor criptografa tambem os backups acessiveis pela unidade mapeada' 'Remover o mapeamento permanente, gravar com credencial dedicada so durante a janela e manter copia imutavel/air-gapped'
}
$shAmplo = @(); $shBkpAmplo = @(); $shTxt = @()
$shares = @(Get-WmiObject Win32_Share | Where-Object { $_.Type -eq 0 -and $_.Name -notmatch '\$$' })
foreach ($s in $shares) {
  $amplo = @()
  try {
    $sec = Get-WmiObject Win32_LogicalShareSecuritySetting -Filter ("Name='{0}'" -f $s.Name.Replace("'", "''"))
    $sd = $sec.GetSecurityDescriptor().Descriptor
    foreach ($ace in $sd.DACL) { if ($ace.AceType -eq 0 -and ($SidAmplo -contains $ace.Trustee.SIDString) -and (($ace.AccessMask -band 0x2) -ne 0)) { $amplo += $ace.Trustee.Name } }
  } catch {}
  $shTxt += ("{0} -> {1} | escrita ampla no share: {2}" -f $s.Name, $s.Path, $(if ($amplo) { $amplo -join ',' } else { 'nao' }))
  if ($amplo.Count -gt 0) { if (($s.Name + ' ' + $s.Path) -match $BkpRx) { $shBkpAmplo += ("{0} ({1})" -f $s.Name, $s.Path) } else { $shAmplo += ("{0} ({1})" -f $s.Name, $s.Path) } }
}
Evid 'COMPARTILHAMENTOS' ($(if ($shTxt) { $shTxt } else { 'nenhum' }))
if ($shBkpAmplo.Count -gt 0) { Achado 'ALTO' 'RANSOMWARE' '1-IMUT' 'SHARE_BKP_ESCRITA_AMPLA' 'IMUTAVEL' 'Compartilhamento de backup com escrita para Todos/Usuarios' ($shBkpAmplo -join '; ') 'Qualquer conta da rede pode apagar ou criptografar os backups' 'Restringir o share a conta de servico do backup e manter copia imutavel' }
if ($shAmplo.Count -gt 0) { Achado 'MEDIO' 'SEGURANCA' '-' 'SHARE_ESCRITA_AMPLA' 'SEGMENTACAO' 'Compartilhamento com escrita para Todos/Usuarios' ($shAmplo -join '; ') 'Superficie para propagacao de ransomware' 'Revisar permissoes de compartilhamento' }

#--- 6. Pastas de backup locais com escrita ampla -------------------------------
$dirs = @()
foreach ($d in @(Get-WmiObject Win32_LogicalDisk | Where-Object { $_.DriveType -eq 3 })) {
  $dirs += @(Get-ChildItem -Path ($d.DeviceID + '\') -Directory -ErrorAction SilentlyContinue | Where-Object { $_.Name -match $BkpRx } | Select-Object -ExpandProperty FullName)
}
$dirAmplo = @()
foreach ($p in ($dirs | Select-Object -First 15)) {
  try {
    $acl = Get-Acl -Path $p
    foreach ($a in $acl.Access) {
      $sid = $null; try { $sid = $a.IdentityReference.Translate([Security.Principal.SecurityIdentifier]).Value } catch {}
      if ($a.AccessControlType -eq 'Allow' -and ($SidAmplo -contains $sid) -and ($a.FileSystemRights.ToString() -match 'FullControl|Modify|Write')) { $dirAmplo += ("{0} ({1}: {2})" -f $p, $a.IdentityReference, $a.FileSystemRights); break }
    }
  } catch {}
}
Evid 'PASTAS DE BACKUP LOCAIS' ($(if ($dirs) { $dirs } else { 'nenhuma pasta com nome de backup na raiz dos discos' }))
if ($dirAmplo.Count -gt 0) { Achado 'ALTO' 'SEGURANCA' '-' 'PERM_DIR_ESCRITA_GERAL' 'SEGMENTACAO' 'Pasta de backup com escrita para Todos/Usuarios' ($dirAmplo -join '; ') 'Qualquer conta local pode apagar ou substituir backups' 'Restringir a conta de servico do backup e administradores' }

#--- 7. Gravacao ----------------------------------------------------------------
$script:Linhas | Set-Content -Path $Ach -Encoding UTF8
$nc = @($script:Linhas | Where-Object { $_ -match "`tCRITICO`t" }).Count
$na = @($script:Linhas | Where-Object { $_ -match "`tALTO`t" }).Count
Write-Host ("[{0}] Seguranca e conformidade: {1} achado(s) | CRITICO {2} | ALTO {3}. Saida: {4}" -f (Get-Date -Format HH:mm:ss), $script:N, $nc, $na, $Saida)
exit 0
