<#
.SYNOPSIS
  WiseDB coleta (Windows) v1.0.0. Descobre SQL Server e Oracle, coleta metadados
  SOMENTE LEITURA, monta um JSON (contrato wisedb.coleta/1) e envia por HTTPS PUT
  para um link PAR da OCI.

.DESCRIPTION
  Requisitos: PowerShell 5.1, sem modulos externos. Nada e instalado alem de
  C:\ProgramData\WiseDB\coleta.conf e, se pedido (-Agendar), uma Tarefa Agendada.
  Este arquivo e propositalmente ASCII (sem acentos) para nao depender de codificacao.

  Modos:
    (padrao)               coleta e envia          (exige -Cliente e -Link, ou coleta.conf)
    -Descobrir             so lista o que existe e o acesso de cada instancia
    -Coletar -Saida <arq>  coleta e grava <arq>.json.gz, sem enviar
    -Agendar Diario|Semanal  grava coleta.conf e cria a Tarefa Agendada (Administrador)
    -RemoverAgendamento    remove a tarefa e o coleta.conf (Administrador)

  Codigos de saida:
    0 sucesso (coleta parcial com avisos tambem e 0)
    1 uso/parametros invalidos
    2 exige Administrador (-Agendar / -RemoverAgendamento)
    3 configuracao ausente ou invalida (cliente, link, coleta.conf)
    4 nada coletado (nenhuma instancia acessivel e nenhum dado)
    5 falha no envio (HTTP diferente de 200 ou rede, apos 3 tentativas)
    6 erro interno ou fixtures de -Simular invalidas
#>
[CmdletBinding()]
param(
    [switch]$Descobrir,
    [switch]$Coletar,
    [string]$Saida,
    [ValidateSet('Diario', 'Semanal')][string]$Agendar,
    [switch]$RemoverAgendamento,
    [string]$Cliente,
    [string]$Link,
    [string]$UrlScript,
    [string]$Sha256,
    [System.Management.Automation.PSCredential]$SqlCredencial,
    [string]$Simular,
    [int]$TimeoutConsulta = 120,
    [int]$JanelaDias = 35
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

$script:AgenteVersao = '1.0.0'
$script:Schema = 'wisedb.coleta/1'
$script:TaskName = 'WiseDB Coleta'
$script:ExitCode = 0
$script:LinkAtual = $null
$script:Avisos = New-Object 'System.Collections.Generic.List[string]'
$script:Cresc = New-Object 'System.Collections.Generic.List[object]'
$script:Back = New-Object 'System.Collections.Generic.List[object]'
$script:SimDir = $null
$script:SqlCred = $null

# ---------------------------------------------------------------- utilitarios

function Get-ConfDir {
    if ($env:WISEDB_CONF_DIR) { return $env:WISEDB_CONF_DIR }
    return (Join-Path $env:ProgramData 'WiseDB')
}

function Limpa([string]$s, [int]$max = 200) {
    if ($null -eq $s) { return $null }
    $s = ($s -replace '[\r\n\t]+', ' ').Trim()
    if ($s.Length -gt $max) { $s = $s.Substring(0, $max) }
    return $s
}

function Get-LinkMascarado([string]$l) {
    if ([string]::IsNullOrEmpty($l)) { return '(vazio)' }
    $n = [Math]::Min(30, $l.Length)
    return ($l.Substring(0, $n) + '...')
}

# Remove o link (e a URL de envio) de qualquer mensagem antes de imprimir ou gravar.
function Protege([string]$m) {
    if ([string]::IsNullOrEmpty($m)) { return $m }
    if ($script:LinkAtual) {
        $m = $m.Replace($script:LinkAtual, (Get-LinkMascarado $script:LinkAtual))
        $m = $m.Replace($script:LinkAtual.TrimEnd('/'), (Get-LinkMascarado $script:LinkAtual))
    }
    $m = [regex]::Replace($m, 'https://[^\s"''<>]*/p/[^\s"''<>]+', 'https://(link PAR omitido)')
    return $m
}

function Add-Aviso([string]$m) { $script:Avisos.Add((Limpa (Protege $m) 300)) }

function Write-Msg([string]$m) { Write-Host (Protege $m) }

function Get-IsoAgora { return [datetime]::UtcNow.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", [Globalization.CultureInfo]::InvariantCulture) }

# Data/hora LOCAL do servidor (string ISO sem fuso, ou DateTime) -> ISO 8601 UTC com Z.
function ConvertTo-IsoUtc($v) {
    if ($null -eq $v) { return $null }
    if ($v -is [DBNull]) { return $null }
    if (("$v").Trim() -eq '') { return $null }
    $ci = [Globalization.CultureInfo]::InvariantCulture
    if ($v -is [datetime]) { $d = $v }
    else {
        $d = [datetime]::MinValue
        $ok = [datetime]::TryParse(("$v").Trim(), $ci, [Globalization.DateTimeStyles]::None, [ref]$d)
        if (-not $ok) { return $null }
    }
    $d = [datetime]::SpecifyKind($d, [DateTimeKind]::Unspecified)
    try { $u = [TimeZoneInfo]::ConvertTimeToUtc($d, [TimeZoneInfo]::Local) }
    catch { $u = $d.Subtract([TimeZoneInfo]::Local.BaseUtcOffset) }
    return $u.ToString("yyyy-MM-dd'T'HH:mm:ss'Z'", $ci)
}

function Test-Admin {
    $p = New-Object Security.Principal.WindowsPrincipal([Security.Principal.WindowsIdentity]::GetCurrent())
    return $p.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

function New-InvItem([string]$motor, [string]$instancia) {
    return [pscustomobject]@{ motor = $motor; instancia = $instancia; versao = $null; acesso = 'erro'; detalhe = $null }
}

function Read-Conf {
    $f = Join-Path (Get-ConfDir) 'coleta.conf'
    $h = @{}
    if (Test-Path -LiteralPath $f) {
        foreach ($l in (Get-Content -LiteralPath $f)) {
            if ($l -match '^\s*([A-Z0-9_]+)\s*=\s*(.*)$') { $h[$matches[1]] = $matches[2].Trim() }
        }
    }
    return $h
}

# Diretorio de trabalho com ACL so do usuario atual, SYSTEM e Administradores
# (evita que outro usuario troque o .sql antes do sqlplus executar como sysdba).
function New-DirTrabalho {
    $base = [IO.Path]::GetTempPath()
    $d = Join-Path $base ('wisedb-coleta-' + [guid]::NewGuid().ToString('N'))
    [void](New-Item -ItemType Directory -Path $d)
    $sid = [Security.Principal.WindowsIdentity]::GetCurrent().User.Value
    & icacls.exe $d /inheritance:r /grant:r "*${sid}:(OI)(CI)F" '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
    return $d
}

function Get-Simulacao([string]$nome) {
    $p = Join-Path $script:SimDir $nome
    if (Test-Path -LiteralPath $p) { return $p }
    return $null
}

# ---------------------------------------------------------------- descoberta de servicos

function Get-Servicos {
    if ($script:SimDir) {
        $p = Get-Simulacao 'servicos.csv'
        if ($p) { return @(Import-Csv -LiteralPath $p) }
        return @()
    }
    return @(Get-Service | Select-Object Name, Status, DisplayName)
}

function Get-RegistroSql {
    $res = @()
    if ($script:SimDir) {
        $p = Get-Simulacao 'registro_sql.csv'
        if ($p) { foreach ($r in (Import-Csv -LiteralPath $p)) { $res += [string]$r.Instance } }
        return $res
    }
    foreach ($k in @('HKLM:\SOFTWARE\Microsoft\Microsoft SQL Server\Instance Names\SQL',
            'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Microsoft SQL Server\Instance Names\SQL')) {
        if (Test-Path -LiteralPath $k) {
            $p = Get-ItemProperty -LiteralPath $k
            foreach ($pp in $p.PSObject.Properties) {
                if ($pp.Name -notlike 'PS*') { $res += $pp.Name }
            }
        }
    }
    return $res
}

function Get-SqlCandidatas {
    $res = @{}
    foreach ($s in @(Get-Servicos)) {
        $n = [string]$s.Name
        $nome = $null
        if ($n -eq 'MSSQLSERVER') { $nome = 'MSSQLSERVER' }
        elseif ($n -match '^MSSQL\$(.+)$') { $nome = $matches[1] }
        if (-not $nome) { continue }
        if ($nome -like '*##*') { continue }   # Windows Internal Database (WID) nao e instancia de usuario
        $res[$nome.ToUpper()] = [pscustomobject]@{ Nome = $nome; Estado = [string]$s.Status }
    }
    foreach ($r in @(Get-RegistroSql)) {
        if (-not $res.ContainsKey($r.ToUpper())) {
            $res[$r.ToUpper()] = [pscustomobject]@{ Nome = $r; Estado = 'Ausente' }
        }
    }
    return @($res.Values | Sort-Object Nome)
}

function Get-OracleCandidatas {
    $res = @()
    foreach ($s in @(Get-Servicos)) {
        if ([string]$s.Name -match '^OracleService(.+)$') {
            $res += [pscustomobject]@{ Sid = $matches[1]; Estado = [string]$s.Status; Home = $null }
        }
    }
    return $res
}

function Test-ClienteCli([string[]]$nomes) {
    if ($script:SimDir) {
        $hj = Get-Simulacao 'host.json'
        if ($hj) {
            $j = Get-Content -LiteralPath $hj -Raw | ConvertFrom-Json
            foreach ($c in @($j.clientes)) { if ($nomes -contains $c) { return $true } }
        }
        return $false
    }
    foreach ($n in $nomes) { if (Get-Command $n -ErrorAction SilentlyContinue) { return $true } }
    return $false
}

function Get-OutrosMotores {
    $defs = @(
        @{ motor = 'mysql'; rx = '^(MySQL|MariaDB)'; cli = @('mysql.exe'); cliNome = 'mysql.exe' },
        @{ motor = 'postgresql'; rx = '^postgresql'; cli = @('psql.exe'); cliNome = 'psql.exe' },
        @{ motor = 'mongodb'; rx = '^MongoDB'; cli = @('mongosh.exe', 'mongo.exe'); cliNome = 'mongosh.exe' }
    )
    $res = @()
    foreach ($s in @(Get-Servicos)) {
        foreach ($d in $defs) {
            if ([string]$s.Name -match $d.rx) {
                $i = New-InvItem $d.motor ([string]$s.Name)
                if ([string]$s.Status -ne 'Running') {
                    $i.acesso = 'erro'; $i.detalhe = 'servico detectado, mas parado'
                }
                elseif (Test-ClienteCli $d.cli) {
                    $i.acesso = 'sem_credencial'; $i.detalhe = 'detectado por servico; coleta nao implementada nesta versao'
                }
                else {
                    $i.acesso = 'sem_cliente'; $i.detalhe = ($d.cliNome + ' nao encontrado no PATH')
                }
                if ($i.acesso -ne 'ok') { Add-Aviso ("$($d.motor) $($i.instancia): $($i.acesso -replace '_',' ')") }
                $res += $i
            }
        }
    }
    return $res
}

# ---------------------------------------------------------------- SQL Server

$script:Q_SQL_VERSAO = "SELECT CAST(SERVERPROPERTY('ProductVersion') AS nvarchar(50)) AS versao"

$script:Q_SQL_BASES = @'
SELECT d.database_id AS database_id, d.name AS nome, d.state_desc AS estado,
       CAST(ISNULL(HAS_DBACCESS(d.name), 0) AS int) AS acessivel,
       CAST(ISNULL(SUM(CASE WHEN mf.type = 0 THEN CAST(mf.size AS bigint) END), 0) * 8192 AS bigint) AS dados_bytes,
       CAST(ISNULL(SUM(CASE WHEN mf.type = 1 THEN CAST(mf.size AS bigint) END), 0) * 8192 AS bigint) AS log_bytes
FROM sys.databases d
LEFT JOIN sys.master_files mf ON mf.database_id = d.database_id
WHERE d.database_id <> 2
GROUP BY d.database_id, d.name, d.state_desc
ORDER BY d.name
'@

# __DBID__ = database_id (inteiro); __DBQ__ = nome entre colchetes (] duplicado)
$script:Q_SQL_FILEGROUPS = @'
SELECT fg.name AS filegroup,
       CAST(SUM(CAST(mf.size AS bigint)) * 8192 AS bigint) AS bytes
FROM sys.master_files mf
JOIN __DBQ__.sys.filegroups fg ON fg.data_space_id = mf.data_space_id
WHERE mf.database_id = __DBID__ AND mf.type = 0
GROUP BY fg.name
ORDER BY fg.name
'@

# Backups fisicos. Exclui backups gravados em NUL (nao sao backups). Horarios locais do servidor.
$script:Q_SQL_BACKUPS = @'
SELECT bs.database_name AS base, bs.type AS tipo,
       CONVERT(varchar(19), bs.backup_start_date, 126) AS inicio,
       CONVERT(varchar(19), bs.backup_finish_date, 126) AS fim,
       CAST(bs.backup_size AS bigint) AS bytes,
       CAST(ISNULL(bs.is_damaged, 0) AS int) AS danificado,
       CAST(ISNULL(bs.has_incomplete_metadata, 0) AS int) AS incompleto,
       (SELECT MIN(m.device_type) FROM msdb.dbo.backupmediafamily m WHERE m.media_set_id = bs.media_set_id) AS device_type
FROM msdb.dbo.backupset bs
WHERE bs.backup_start_date >= DATEADD(day, -__DIAS__, GETDATE())
  AND bs.type IN ('D', 'I', 'L')
  AND NOT EXISTS (SELECT 1 FROM msdb.dbo.backupmediafamily m
                  WHERE m.media_set_id = bs.media_set_id AND m.physical_device_name IN ('NUL', 'NUL:'))
ORDER BY bs.backup_start_date
'@

# Falhas de job de backup (resultado do JOB, step 0). Nao identifica a base: vai para avisos.
$script:Q_SQL_JOBFALHAS = @'
SELECT j.name AS job, COUNT(*) AS falhas, MAX(h.run_date) AS ultima
FROM msdb.dbo.sysjobs j
JOIN msdb.dbo.sysjobhistory h ON h.job_id = j.job_id
WHERE h.step_id = 0 AND h.run_status = 0
  AND h.run_date >= CONVERT(int, CONVERT(char(8), DATEADD(day, -__DIAS__, GETDATE()), 112))
  AND (j.name LIKE '%backup%'
       OR EXISTS (SELECT 1 FROM msdb.dbo.sysjobsteps s
                  WHERE s.job_id = j.job_id
                    AND (s.command LIKE '%BACKUP DATABASE%' OR s.command LIKE '%BACKUP LOG%' OR s.command LIKE '%DatabaseBackup%')))
GROUP BY j.name
'@

function Open-Sql([string]$inst) {
    if ($script:SimDir) { return $null }
    $srv = 'localhost'
    if ($inst -ne 'MSSQLSERVER') { $srv = "localhost\$inst" }
    $cs = "Server=$srv;Database=master;Connect Timeout=15;Application Name=wisedb-coleta;"
    $cn = New-Object System.Data.SqlClient.SqlConnection
    if ($script:SqlCred) {
        $cs += 'Integrated Security=False;'
        $sec = $script:SqlCred.Password.Copy()
        $sec.MakeReadOnly()
        $cn.Credential = New-Object System.Data.SqlClient.SqlCredential($script:SqlCred.UserName, $sec)
    }
    else { $cs += 'Integrated Security=SSPI;' }
    $cn.ConnectionString = $cs
    $cn.Open()
    return $cn
}

# Retorna array de PSCustomObject. Em -Simular le sqlserver_<inst>_<nome>.csv.
function Invoke-SqlQuery($cn, [string]$inst, [string]$nome, [string]$sql) {
    if ($script:SimDir) {
        $e = Get-Simulacao "sqlserver_${inst}_erro.txt"
        if ($e) { throw (Get-Content -LiteralPath $e -Raw) }
        $p = Get-Simulacao "sqlserver_${inst}_${nome}.csv"
        if (-not $p) { throw "fixture ausente: sqlserver_${inst}_${nome}.csv" }
        return @(Import-Csv -LiteralPath $p)
    }
    $cmd = $cn.CreateCommand()
    $cmd.CommandText = $sql
    $cmd.CommandTimeout = $TimeoutConsulta
    $da = New-Object System.Data.SqlClient.SqlDataAdapter($cmd)
    $dt = New-Object System.Data.DataTable
    [void]$da.Fill($dt)
    $out = New-Object 'System.Collections.Generic.List[object]'
    foreach ($r in $dt.Rows) {
        $o = [ordered]@{}
        foreach ($c in $dt.Columns) {
            $v = $r[$c.ColumnName]
            if ($v -is [DBNull]) { $v = $null }
            $o[$c.ColumnName] = $v
        }
        $out.Add([pscustomobject]$o)
    }
    return $out.ToArray()
}

function ConvertTo-DispositivoSql($d) {
    if ($null -eq $d -or ("$d").Trim() -eq '') { return $null }
    switch ([int]$d) {
        { $_ -in 2, 102 } { return 'DISK' }
        { $_ -in 5, 105 } { return 'SBT_TAPE' }
        { $_ -in 9, 109 } { return 'URL' }
        default { return $null }   # 7/107 = virtual device (ferramenta de terceiros): sem equivalente no contrato
    }
}

function Coletar-SqlDados($cn, [string]$inst) {
    $agora = Get-IsoAgora
    $bases = @(Invoke-SqlQuery $cn $inst 'bases' $script:Q_SQL_BASES)
    foreach ($b in $bases) {
        $nome = [string]$b.nome
        $dados = [long]$b.dados_bytes
        if ($dados -le 0) {
            Add-Aviso "sqlserver ${inst}: base $nome sem arquivos de dados visiveis (permissao VIEW ANY DEFINITION?)"
            continue
        }
        $script:Cresc.Add([ordered]@{
                motor = 'sqlserver'; instancia = $inst; base = $nome; subbase = $null
                componente_tipo = 'total'; componente = $nome; bytes = $dados; medido_em = $agora
                bytes_log = [long]$b.log_bytes
            })
        if (([string]$b.estado -eq 'ONLINE') -and ([int]$b.acessivel -eq 1)) {
            $q = $script:Q_SQL_FILEGROUPS.Replace('__DBID__', [string][int]$b.database_id).Replace('__DBQ__', ('[' + $nome.Replace(']', ']]') + ']'))
            try {
                foreach ($f in @(Invoke-SqlQuery $cn $inst ("filegroups_" + [int]$b.database_id) $q)) {
                    $script:Cresc.Add([ordered]@{
                            motor = 'sqlserver'; instancia = $inst; base = $nome; subbase = $null
                            componente_tipo = 'filegroup'; componente = [string]$f.filegroup; bytes = [long]$f.bytes; medido_em = $agora
                        })
                }
            }
            catch { Add-Aviso "sqlserver ${inst}: filegroups de $nome nao coletados ($(Limpa $_.Exception.Message 120))" }
        }
        else {
            Add-Aviso "sqlserver ${inst}: base $nome em estado $($b.estado) ou sem acesso; so total coletado"
        }
    }

    # Backups (msdb)
    try {
        $q = $script:Q_SQL_BACKUPS.Replace('__DIAS__', [string][int]$JanelaDias)
        foreach ($r in @(Invoke-SqlQuery $cn $inst 'backups' $q)) {
            $tipo = switch ([string]$r.tipo) { 'D' { 'FULL' } 'I' { 'DIFERENCIAL' } 'L' { 'LOG' } default { $null } }
            if (-not $tipo) { continue }
            $status = 'SUCESSO'
            if (([int]$r.danificado -eq 1) -or ([int]$r.incompleto -eq 1)) { $status = 'WARNING' }
            $bytes = $null
            if ($null -ne $r.bytes -and ("$($r.bytes)").Trim() -ne '') { $bytes = [long]$r.bytes }
            $ini = ConvertTo-IsoUtc $r.inicio
            if (-not $ini) { continue }
            $script:Back.Add([ordered]@{
                    motor = 'sqlserver'; instancia = $inst; base = [string]$r.base; origem = 'msdb'; tipo = $tipo
                    dispositivo = (ConvertTo-DispositivoSql $r.device_type)
                    inicio = $ini; fim = (ConvertTo-IsoUtc $r.fim); status = $status; bytes = $bytes; objetos = $null
                })
        }
    }
    catch { Add-Aviso "sqlserver ${inst}: backups (msdb) nao coletados ($(Limpa $_.Exception.Message 120))" }

    # Falhas de job de backup: so aviso (o msdb.backupset nao registra backup que falhou)
    try {
        $q = $script:Q_SQL_JOBFALHAS.Replace('__DIAS__', [string][int]$JanelaDias)
        foreach ($r in @(Invoke-SqlQuery $cn $inst 'jobfalhas' $q)) {
            Add-Aviso ("sqlserver ${inst}: job de backup '$($r.job)' falhou $($r.falhas) vez(es) nos ultimos $JanelaDias dias (ultima: $($r.ultima))")
        }
    }
    catch { Add-Aviso "sqlserver ${inst}: historico de jobs nao lido (sem permissao em msdb.sysjobhistory?)" }
}

function Invoke-SqlInstancia($cand, [bool]$coletar) {
    $inst = $cand.Nome
    $inv = New-InvItem 'sqlserver' $inst
    if ($cand.Estado -ne 'Running') {
        $inv.acesso = 'erro'; $inv.detalhe = "servico SQL Server nao esta em execucao ($($cand.Estado))"
        Add-Aviso "sqlserver ${inst}: servico $($cand.Estado)"
        return $inv
    }
    $cn = $null
    try {
        $cn = Open-Sql $inst
        $v = @(Invoke-SqlQuery $cn $inst 'versao' $script:Q_SQL_VERSAO)
        $inv.versao = Limpa ([string]$v[0].versao) 50
        $inv.acesso = 'ok'
        if ($coletar) { Coletar-SqlDados $cn $inst }
    }
    catch {
        $msg = Limpa $_.Exception.Message 200
        if ($msg -match 'Login failed|login failed|18456|permission was denied|denied') {
            $inv.acesso = 'sem_credencial'
        }
        else { $inv.acesso = 'erro' }
        $inv.detalhe = $msg
        Add-Aviso "sqlserver ${inst}: $($inv.acesso -replace '_',' ') ($msg)"
    }
    finally { if ($cn) { $cn.Dispose() } }
    return $inv
}

# ---------------------------------------------------------------- Oracle

$script:SQL_ORA_CAB = @'
set echo off feedback off heading off verify off pagesize 0 linesize 500
set trimspool on trimout on tab off termout on serveroutput off sqlblanklines off
set define '&'
whenever sqlerror exit 3
whenever oserror exit 3
'@

$script:SQL_ORA_INFO = @'
select 'INFO;VERSAO;' || version from v$instance;
select 'INFO;ESTADO;' || status from v$instance;
exit 0
'@

# Adaptado de coleta_crescimento.sql: mesma logica; bytes inteiros (soma de dba/cdb_data_files, sem tempfiles).
$script:SQL_ORA_CRESC = @'
column v_modo new_value V_MODO noprint
select case when count(*) > 0 then 'cdb' else 'nocdb' end as v_modo
  from v$parameter
 where name = 'enable_pluggable_database' and upper(value) = 'TRUE';
column v_df new_value V_DF noprint
column v_ct new_value V_CT noprint
column v_pd new_value V_PD noprint
select case when '&&V_MODO' = 'cdb'
            then 'select con_id, tablespace_name, bytes from cdb_data_files'
            else 'select 0 as con_id, tablespace_name, bytes from dba_data_files' end as v_df,
       case when '&&V_MODO' = 'cdb'
            then 'select con_id, name from v$containers where con_id > 2'
            else 'select 0 as con_id, to_char(null) as name from dual' end as v_ct,
       case when '&&V_MODO' = 'cdb'
            then 'select name, open_mode from v$pdbs where con_id > 2'
            else 'select to_char(null) as name, to_char(null) as open_mode from dual where 1 = 0' end as v_pd
  from dual;
select 'INFO;MODO;&&V_MODO' from dual;
select 'AVISO;PDB_FECHADO;' || name || ';' || open_mode
  from (&&V_PD)
 where open_mode not in ('READ WRITE', 'READ ONLY');
select 'TOT;' || d.name || ';' || c.name || ';;' || to_char(sum(f.bytes), 'FM99999999999999999990')
  from (&&V_DF) f, (&&V_CT) c, (select name from v$database) d
 where f.con_id = c.con_id
 group by d.name, c.name
 order by c.name;
select 'TBS;' || d.name || ';' || c.name || ';' || f.tablespace_name || ';' || to_char(sum(f.bytes), 'FM99999999999999999990')
  from (&&V_DF) f, (&&V_CT) c, (select name from v$database) d
 where f.con_id = c.con_id
 group by d.name, c.name, f.tablespace_name
 order by c.name, f.tablespace_name;
exit 0
'@

# Adaptado de coleta_rman.sql. Saida: TIPO;DBNAME;INICIO;FIM;BYTES;STATUS;DEVICE (datas ISO locais do servidor).
$script:SQL_ORA_RMAN = @'
select case
         when j.input_type like '%FULL' then 'FULL'
         when j.input_type like '%INCR' and d.nivel_min = 0 then 'FULL'
         else 'INCREMENTAL'
       end
       || ';' || db.name
       || ';' || to_char(j.start_time, 'YYYY-MM-DD"T"HH24:MI:SS')
       || ';' || to_char(nvl(j.end_time, j.start_time), 'YYYY-MM-DD"T"HH24:MI:SS')
       || ';' || to_char(nvl(j.output_bytes, 0), 'FM99999999999999999990')
       || ';' || case j.status
                   when 'COMPLETED'               then 'SUCESSO'
                   when 'COMPLETED WITH WARNINGS' then 'WARNING'
                   else 'FALHA'
                 end
       || ';' || x.dev
from   v$rman_backup_job_details j
       cross join v$database db
       cross join (select 'DISK' dev from dual union all select 'SBT_TAPE' from dual) x
       left join (select session_key, session_stamp, min(incremental_level) nivel_min
                  from   v$backup_set_details
                  group  by session_key, session_stamp) d
              on d.session_key = j.session_key and d.session_stamp = j.session_stamp
where  j.start_time >= trunc(sysdate) - __DIAS__
and    j.input_type in ('DB FULL', 'DB INCR', 'DATAFILE FULL', 'DATAFILE INCR')
and    j.status not like 'RUNNING%'
and    instr(nvl(j.output_device_type, 'DISK'), x.dev) > 0
order  by j.start_time, x.dev;
exit 0
'@

# Sem v$backup_set_details: todo INCR vira INCREMENTAL (Level 0 aparece como incremental).
$script:SQL_ORA_RMAN_SEM_NIVEL = @'
select case when j.input_type like '%FULL' then 'FULL' else 'INCREMENTAL' end
       || ';' || db.name
       || ';' || to_char(j.start_time, 'YYYY-MM-DD"T"HH24:MI:SS')
       || ';' || to_char(nvl(j.end_time, j.start_time), 'YYYY-MM-DD"T"HH24:MI:SS')
       || ';' || to_char(nvl(j.output_bytes, 0), 'FM99999999999999999990')
       || ';' || case j.status
                   when 'COMPLETED'               then 'SUCESSO'
                   when 'COMPLETED WITH WARNINGS' then 'WARNING'
                   else 'FALHA'
                 end
       || ';' || x.dev
from   v$rman_backup_job_details j
       cross join v$database db
       cross join (select 'DISK' dev from dual union all select 'SBT_TAPE' from dual) x
where  j.start_time >= trunc(sysdate) - __DIAS__
and    j.input_type in ('DB FULL', 'DB INCR', 'DATAFILE FULL', 'DATAFILE INCR')
and    j.status not like 'RUNNING%'
and    instr(nvl(j.output_device_type, 'DISK'), x.dev) > 0
order  by j.start_time, x.dev;
exit 0
'@

function Get-OracleHomes {
    if ($script:SimDir) { return @('SIM') }
    $h = New-Object 'System.Collections.Generic.List[string]'
    $add = {
        param($home_)
        if ($home_ -and (Test-Path -LiteralPath (Join-Path $home_ 'bin\sqlplus.exe'))) {
            if (-not ($h | Where-Object { $_ -ieq $home_ })) { $h.Add($home_) }
        }
    }
    if ($env:ORACLE_HOME) { & $add $env:ORACLE_HOME }
    foreach ($k in @('HKLM:\SOFTWARE\ORACLE', 'HKLM:\SOFTWARE\WOW6432Node\ORACLE')) {
        if (Test-Path -LiteralPath $k) {
            foreach ($c in (Get-ChildItem -LiteralPath $k -ErrorAction SilentlyContinue)) {
                if ($c.PSChildName -like 'KEY_*') {
                    $p = Get-ItemProperty -LiteralPath $c.PSPath -ErrorAction SilentlyContinue
                    if ($p -and $p.ORACLE_HOME) { & $add ([string]$p.ORACLE_HOME) }
                }
            }
        }
    }
    $cmd = Get-Command sqlplus.exe -ErrorAction SilentlyContinue
    if ($cmd) { & $add (Split-Path (Split-Path $cmd.Source)) }
    return $h.ToArray()
}

# Executa um script SQL*Plus como sysdba por autenticacao do SO. Tenta cada home ate um funcionar.
# Retorna @{ ok; texto; home; erro }.
function Invoke-OracleScript([string]$sid, [string[]]$homes, [string]$nome, [string]$corpo) {
    if ($script:SimDir) {
        $p = Get-Simulacao "oracle_${sid}_${nome}.txt"
        if (-not $p) { return @{ ok = $false; texto = ''; home = 'SIM'; erro = "fixture ausente: oracle_${sid}_${nome}.txt" } }
        $t = Get-Content -LiteralPath $p -Raw
        $ok = ($t -notmatch '(?m)^(ORA|SP2)-\d+')
        return @{ ok = $ok; texto = $t; home = 'SIM'; erro = $(if ($ok) { $null } else { Limpa (($t -split "`n" | Where-Object { $_ -match '^(ORA|SP2)-' } | Select-Object -First 1)) 200 }) }
    }
    $ultimo = @{ ok = $false; texto = ''; home = $null; erro = 'sqlplus nao executado' }
    $dir = New-DirTrabalho
    $salvo = @{}
    foreach ($v in 'ORACLE_SID', 'ORACLE_HOME', 'TWO_TASK', 'LOCAL', 'PATH') { $salvo[$v] = [Environment]::GetEnvironmentVariable($v) }
    try {
        $sqlf = Join-Path $dir 'q.sql'
        $outf = Join-Path $dir 'q.out'
        $errf = Join-Path $dir 'q.err'
        $enc = New-Object System.Text.UTF8Encoding($false)
        [IO.File]::WriteAllText($sqlf, ($script:SQL_ORA_CAB + "`r`n" + $corpo + "`r`n"), $enc)
        foreach ($home_ in $homes) {
            $env:ORACLE_SID = $sid
            $env:ORACLE_HOME = $home_
            $env:TWO_TASK = $null
            $env:LOCAL = $null
            $env:PATH = (Join-Path $home_ 'bin') + ';' + $salvo['PATH']
            $exe = Join-Path $home_ 'bin\sqlplus.exe'
            $args_ = '-s -L "/ as sysdba" @"' + $sqlf + '"'
            $pr = Start-Process -FilePath $exe -ArgumentList $args_ -NoNewWindow -PassThru `
                -RedirectStandardOutput $outf -RedirectStandardError $errf
            $null = $pr.Handle
            if (-not $pr.WaitForExit($TimeoutConsulta * 1000)) {
                try { $pr.Kill() } catch { }
                $ultimo = @{ ok = $false; texto = ''; home = $home_; erro = "timeout de $TimeoutConsulta s no sqlplus" }
                continue
            }
            $txt = ''
            if (Test-Path -LiteralPath $outf) { $txt = [IO.File]::ReadAllText($outf) }
            $ok = ($pr.ExitCode -eq 0) -and ($txt -notmatch '(?m)^(ORA|SP2)-\d+')
            $err = $null
            if (-not $ok) {
                $l = ($txt -split "`n" | Where-Object { $_ -match '^(ORA|SP2)-' } | Select-Object -First 1)
                if (-not $l) { $l = "sqlplus terminou com codigo $($pr.ExitCode)" }
                $err = Limpa $l 200
            }
            $ultimo = @{ ok = $ok; texto = $txt; home = $home_; erro = $err }
            if ($ok) { break }
            if ($txt -match 'ORA-01031') { break }   # privilegio: outro home nao muda o resultado
        }
    }
    finally {
        foreach ($v in $salvo.Keys) { [Environment]::SetEnvironmentVariable($v, $salvo[$v]) }
        Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue
    }
    return $ultimo
}

function Get-LinhasOracle([string]$texto) {
    return @(($texto -split "`n") | ForEach-Object { $_.Trim("`r", ' ') } | Where-Object { $_ -ne '' })
}

function Coletar-OracleDados([string]$sid, [string[]]$homes) {
    $agora = Get-IsoAgora
    # crescimento
    $r = Invoke-OracleScript $sid $homes 'cresc' $script:SQL_ORA_CRESC
    if (-not $r.ok) { Add-Aviso "oracle ${sid}: crescimento nao coletado ($($r.erro))" }
    else {
        $tot = @{}; $comp = @{}; $linhas = New-Object 'System.Collections.Generic.List[object]'
        foreach ($l in (Get-LinhasOracle $r.texto)) {
            $f = $l -split ';'
            if ($f[0] -eq 'AVISO' -and $f.Count -ge 4 -and $f[1] -eq 'PDB_FECHADO') { Add-Aviso "oracle ${sid}: PDB $($f[2]) em $($f[3]); sem dados nesta coleta"; continue }
            if (($f[0] -eq 'TOT' -or $f[0] -eq 'TBS') -and $f.Count -ge 5 -and $f[4] -match '^\d+$') {
                $sub = $null; if ($f[2] -ne '') { $sub = $f[2] }
                $key = $f[1] + '|' + $f[2]
                if ($f[0] -eq 'TOT') {
                    $tot[$key] = $true
                    $linhas.Add([ordered]@{ motor = 'oracle'; instancia = $sid; base = $f[1]; subbase = $sub; componente_tipo = 'total'; componente = $f[1]; bytes = [long]$f[4]; medido_em = $agora })
                }
                else {
                    if (-not $comp.ContainsKey($key)) { $comp[$key] = 0L }
                    $comp[$key] += [long]$f[4]
                    $linhas.Add([ordered]@{ motor = 'oracle'; instancia = $sid; base = $f[1]; subbase = $sub; componente_tipo = 'tablespace'; componente = $f[3]; bytes = [long]$f[4]; medido_em = $agora })
                }
            }
        }
        foreach ($l in $linhas) { $script:Cresc.Add($l) }
        foreach ($k in $comp.Keys) {
            if (-not $tot.ContainsKey($k)) {   # garante 1 total por base/subbase (soma dos componentes)
                $p = $k -split '\|'
                $sub = $null; if ($p[1] -ne '') { $sub = $p[1] }
                $script:Cresc.Add([ordered]@{ motor = 'oracle'; instancia = $sid; base = $p[0]; subbase = $sub; componente_tipo = 'total'; componente = $p[0]; bytes = [long]$comp[$k]; medido_em = $agora })
            }
        }
    }
    # RMAN
    $q = $script:SQL_ORA_RMAN.Replace('__DIAS__', [string][int]$JanelaDias)
    $r = Invoke-OracleScript $sid $homes 'rman' $q
    if (-not $r.ok -and ($r.texto -match 'ORA-00942|ORA-00904' -or $r.erro -match 'ORA-00942|ORA-00904')) {
        Add-Aviso "oracle ${sid}: v`$backup_set_details indisponivel; Level 0 aparece como INCREMENTAL"
        $q = $script:SQL_ORA_RMAN_SEM_NIVEL.Replace('__DIAS__', [string][int]$JanelaDias)
        $r = Invoke-OracleScript $sid $homes 'rman_sem_nivel' $q
    }
    if (-not $r.ok) { Add-Aviso "oracle ${sid}: backups RMAN nao coletados ($($r.erro))"; return }
    foreach ($l in (Get-LinhasOracle $r.texto)) {
        $f = $l -split ';'
        if ($f.Count -ne 7) { continue }
        if ($f[0] -notin 'FULL', 'INCREMENTAL') { continue }
        if ($f[5] -notin 'SUCESSO', 'WARNING', 'FALHA') { continue }
        $ini = ConvertTo-IsoUtc $f[2]
        if (-not $ini) { continue }
        $b = $null; if ($f[4] -match '^\d+$') { $b = [long]$f[4] }
        $script:Back.Add([ordered]@{
                motor = 'oracle'; instancia = $sid; base = $f[1]; origem = 'rman'; tipo = $f[0]
                dispositivo = $f[6]; inicio = $ini; fim = (ConvertTo-IsoUtc $f[3]); status = $f[5]; bytes = $b; objetos = $null
            })
    }
}

function Invoke-OracleInstancia($cand, [bool]$coletar) {
    $sid = $cand.Sid
    $inv = New-InvItem 'oracle' $sid
    if ($cand.Estado -ne 'Running') {
        $inv.detalhe = "servico OracleService$sid nao esta em execucao ($($cand.Estado))"
        Add-Aviso "oracle ${sid}: servico $($cand.Estado)"
        return $inv
    }
    $homes = @(Get-OracleHomes)
    if ($homes.Count -eq 0) {
        $inv.acesso = 'sem_cliente'; $inv.detalhe = 'sqlplus.exe nao encontrado (PATH, ORACLE_HOME ou registro)'
        Add-Aviso "oracle ${sid}: sem cliente (sqlplus.exe nao encontrado)"
        return $inv
    }
    $r = Invoke-OracleScript $sid $homes 'info' $script:SQL_ORA_INFO
    if (-not $r.ok) {
        if (("$($r.erro) $($r.texto)") -match 'ORA-01031') { $inv.acesso = 'sem_credencial'; $inv.detalhe = 'ORA-01031: usuario fora do grupo ORA_DBA (ou sem SYSDBA por autenticacao do SO)' }
        else { $inv.acesso = 'erro'; $inv.detalhe = Limpa $r.erro 200 }
        Add-Aviso "oracle ${sid}: $($inv.acesso -replace '_',' ') ($($inv.detalhe))"
        return $inv
    }
    $estado = $null
    foreach ($l in (Get-LinhasOracle $r.texto)) {
        $f = $l -split ';'
        if ($f.Count -ge 3 -and $f[0] -eq 'INFO' -and $f[1] -eq 'VERSAO') { $inv.versao = Limpa $f[2] 50 }
        if ($f.Count -ge 3 -and $f[0] -eq 'INFO' -and $f[1] -eq 'ESTADO') { $estado = $f[2] }
    }
    if ($estado -and $estado -ne 'OPEN') {
        $inv.acesso = 'erro'; $inv.detalhe = "instancia em estado $estado (esperado OPEN)"
        Add-Aviso "oracle ${sid}: $($inv.detalhe)"
        return $inv
    }
    $inv.acesso = 'ok'
    if ($coletar) { Coletar-OracleDados $sid @($r.home) }
    return $inv
}

# ---------------------------------------------------------------- host, nuvem

function Invoke-Meta([string]$url, [string]$metodo, [hashtable]$headers) {
    $req = [Net.HttpWebRequest]::Create($url)
    $req.Method = $metodo
    $req.Timeout = 2000
    $req.ReadWriteTimeout = 2000
    $req.Proxy = $null
    if ($metodo -eq 'PUT') { $req.ContentLength = 0 }
    foreach ($k in $headers.Keys) { $req.Headers.Add($k, [string]$headers[$k]) }
    $resp = $req.GetResponse()
    try {
        $sr = New-Object IO.StreamReader($resp.GetResponseStream())
        return $sr.ReadToEnd()
    }
    finally { $resp.Close() }
}

# Retorna @{ provedor = 'oci'|'aws'|'azure'|'gcp'|$null; instancia_id }
function Get-NuvemMeta {
    if ($script:SimDir) {
        $hj = Get-Simulacao 'host.json'
        if ($hj) {
            $j = Get-Content -LiteralPath $hj -Raw | ConvertFrom-Json
            return @{ provedor = $j.nuvem; instancia_id = $j.instancia_id }
        }
        return @{ provedor = $null; instancia_id = $null }
    }
    try {
        $t = Invoke-Meta 'http://169.254.169.254/opc/v2/instance/' 'GET' @{ Authorization = 'Bearer Oracle' }
        $j = $t | ConvertFrom-Json
        if ($j.id) { return @{ provedor = 'oci'; instancia_id = [string]$j.id } }
    }
    catch { }
    try {
        $tok = Invoke-Meta 'http://169.254.169.254/latest/api/token' 'PUT' @{ 'X-aws-ec2-metadata-token-ttl-seconds' = '60' }
        $id = Invoke-Meta 'http://169.254.169.254/latest/meta-data/instance-id' 'GET' @{ 'X-aws-ec2-metadata-token' = $tok }
        if ($id) { return @{ provedor = 'aws'; instancia_id = (Limpa $id 50) } }
    }
    catch { }
    try {
        $t = Invoke-Meta 'http://169.254.169.254/metadata/instance?api-version=2021-02-01' 'GET' @{ Metadata = 'true' }
        $j = $t | ConvertFrom-Json
        if ($j.compute.vmId) { return @{ provedor = 'azure'; instancia_id = [string]$j.compute.vmId } }
    }
    catch { }
    try {
        $id = Invoke-Meta 'http://169.254.169.254/computeMetadata/v1/instance/id' 'GET' @{ 'Metadata-Flavor' = 'Google' }
        if ($id) { return @{ provedor = 'gcp'; instancia_id = (Limpa $id 50) } }
    }
    catch { }
    return @{ provedor = $null; instancia_id = $null }
}

function Get-ClisNuvem {
    if ($script:SimDir) {
        $hj = Get-Simulacao 'host.json'
        if ($hj) { $j = Get-Content -LiteralPath $hj -Raw | ConvertFrom-Json; return @($j.cli_detectadas | Where-Object { $_ }) }
        return @()
    }
    $r = @()
    foreach ($n in 'oci', 'aws', 'az', 'gcloud') { if (Get-Command $n -ErrorAction SilentlyContinue) { $r += $n } }
    return $r
}

function Get-HostInfo {
    if ($script:SimDir) {
        $hj = Get-Simulacao 'host.json'
        if ($hj) { $j = Get-Content -LiteralPath $hj -Raw | ConvertFrom-Json; return @{ nome = [string]$j.nome; so = [string]$j.so } }
    }
    $nome = [Environment]::MachineName.ToLower()
    $so = 'Windows'
    try {
        $os = Get-CimInstance -ClassName Win32_OperatingSystem
        $so = (([string]$os.Caption) -replace '^Microsoft\s+', '') + ' ' + $os.Version
    }
    catch { $so = [Environment]::OSVersion.VersionString }
    return @{ nome = $nome; so = (Limpa $so 100) }
}

# ---------------------------------------------------------------- montagem, saida, envio

function Invoke-Descoberta([bool]$coletar) {
    $inv = New-Object 'System.Collections.Generic.List[object]'
    foreach ($c in @(Get-SqlCandidatas)) { $inv.Add((Invoke-SqlInstancia $c $coletar)) }
    foreach ($c in @(Get-OracleCandidatas)) { $inv.Add((Invoke-OracleInstancia $c $coletar)) }
    foreach ($o in @(Get-OutrosMotores)) { $inv.Add($o) }
    return $inv.ToArray()
}

function New-Envelope([string]$cliente, $inv, $hostInfo, $nuvem, $clis) {
    $invOut = @($inv | ForEach-Object { [ordered]@{ motor = $_.motor; instancia = $_.instancia; versao = $_.versao; acesso = $_.acesso; detalhe = $_.detalhe } })
    return [ordered]@{
        schema      = $script:Schema
        cliente_id  = $cliente
        coletado_em = (Get-IsoAgora)
        agente      = [ordered]@{ nome = 'wisedb-coleta'; versao = $script:AgenteVersao; plataforma = 'windows' }
        host        = [ordered]@{ nome = $hostInfo.nome; so = $hostInfo.so; nuvem = $nuvem.provedor; instancia_id = $nuvem.instancia_id }
        inventario  = $invOut
        crescimento = $script:Cresc.ToArray()
        backups     = $script:Back.ToArray()
        nuvem       = [ordered]@{ cli_detectadas = @($clis); itens = @() }
        avisos      = $script:Avisos.ToArray()
    }
}

# JSON UTF-8 sem BOM + gzip (GZipStream).
function Write-GzJson($obj, [string]$path) {
    $json = ConvertTo-Json -InputObject $obj -Depth 8 -Compress
    $bytes = (New-Object System.Text.UTF8Encoding($false)).GetBytes($json)
    $fs = [IO.File]::Create($path)
    try {
        $gz = New-Object IO.Compression.GZipStream($fs, [IO.Compression.CompressionMode]::Compress)
        try { $gz.Write($bytes, 0, $bytes.Length) } finally { $gz.Dispose() }
    }
    finally { $fs.Dispose() }
}

function Get-UrlEnvio([string]$link, [string]$cliente, [string]$hostNome, [string]$ts) {
    $b = $link.TrimEnd('/') + '/'
    return ($b + [uri]::EscapeDataString($cliente) + '/coleta/' + [uri]::EscapeDataString($hostNome) + '/' + $ts + '.json.gz')
}

# Retorna $true se HTTP 200. 3 tentativas; 4xx nao e repetido (link expirado/sem permissao).
function Send-Coleta([string]$arquivo, [string]$link, [string]$cliente, [string]$hostNome, [string]$ts) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    $url = Get-UrlEnvio $link $cliente $hostNome $ts
    $script:LinkAtual = $link
    for ($t = 1; $t -le 3; $t++) {
        $status = 0; $msg = $null
        try {
            $r = Invoke-WebRequest -UseBasicParsing -Method Put -Uri $url -InFile $arquivo -ContentType 'application/octet-stream' -TimeoutSec 300
            $status = [int]$r.StatusCode
        }
        catch {
            $msg = $_.Exception.Message
            if ($_.Exception.Response) { $status = [int]$_.Exception.Response.StatusCode }
        }
        if ($status -eq 200) { Write-Msg "Envio concluido (HTTP 200): $cliente/coleta/$hostNome/$ts.json.gz"; return $true }
        $d = "tentativa $t/3 falhou"
        if ($status -ne 0) { $d += ": HTTP $status (esperado 200)" } else { $d += ": " + (Limpa (Protege $msg) 200) }
        Write-Msg $d
        if ($status -ge 400 -and $status -lt 500) {
            Write-Msg 'Erro de autorizacao ou link invalido/expirado: peca um novo link PAR a WiseDB.'
            return $false
        }
        if ($t -lt 3) { Start-Sleep -Seconds (5 * $t) }
    }
    return $false
}

# ---------------------------------------------------------------- agendamento

function Get-LauncherAgendado {
    return @'
$ErrorActionPreference='Stop'
[Net.ServicePointManager]::SecurityProtocol=[Net.SecurityProtocolType]::Tls12
$d=Join-Path $env:ProgramData 'WiseDB'
$c=@{}
Get-Content (Join-Path $d 'coleta.conf') | ForEach-Object { if($_ -match '^\s*([A-Z0-9_]+)\s*=\s*(.*)$'){ $c[$matches[1]]=$matches[2].Trim() } }
$f=Join-Path $d ('run-'+[guid]::NewGuid().ToString('N')+'.ps1')
try {
  Invoke-WebRequest -UseBasicParsing -Uri $c.URL_SCRIPT -OutFile $f -TimeoutSec 120
  $h=(Get-FileHash -Algorithm SHA256 -Path $f).Hash
  if($h -ne $c.SHA256){ Write-Error 'SHA-256 diferente do publicado: coleta cancelada'; exit 6 }
  & $f
  exit $LASTEXITCODE
} finally { Remove-Item $f -Force -ErrorAction SilentlyContinue }
'@
}

function ConvertTo-EncodedCommand([string]$s) {
    return [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($s))
}

function Invoke-Agendar {
    if (-not (Test-Admin)) { Write-Msg 'Agendar exige PowerShell como Administrador.'; return 2 }
    $conf = Read-Conf
    $cli = $Cliente; if (-not $cli) { $cli = $conf['CLIENTE'] }
    $lnk = $Link; if (-not $lnk) { $lnk = $conf['LINK'] }
    $url = $UrlScript; if (-not $url) { $url = $conf['URL_SCRIPT'] }
    $sha = $Sha256; if (-not $sha) { $sha = $conf['SHA256'] }
    $script:LinkAtual = $lnk
    if (-not $cli -or $cli -notmatch '^[A-Za-z0-9._-]+$') { Write-Msg 'Informe -Cliente (apenas letras, numeros, ponto, hifen, sublinhado).'; return 3 }
    if (-not $lnk -or $lnk -notmatch '^https://') { Write-Msg 'Informe -Link (URL https do PAR).'; return 3 }
    if (-not $url -or $url -notmatch '^https://') { Write-Msg 'Informe -UrlScript (https) da versao publicada do wizard.'; return 3 }
    if (-not $sha -or $sha -notmatch '^[0-9A-Fa-f]{64}$') { Write-Msg 'Informe -Sha256 (64 hex) da versao publicada.'; return 3 }
    $dir = Get-ConfDir
    if (-not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Path $dir) }
    & icacls.exe $dir /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' | Out-Null
    $arq = Join-Path $dir 'coleta.conf'
    $txt = "# WiseDB coleta. Gerado por wisedb-coleta.ps1 $script:AgenteVersao`r`nCLIENTE=$cli`r`nLINK=$lnk`r`nURL_SCRIPT=$url`r`nSHA256=$($sha.ToUpper())`r`n"
    [IO.File]::WriteAllText($arq, $txt, (New-Object System.Text.UTF8Encoding($false)))
    & icacls.exe $dir /inheritance:r /grant:r '*S-1-5-18:(OI)(CI)F' '*S-1-5-32-544:(OI)(CI)F' /T | Out-Null

    $enc = ConvertTo-EncodedCommand (Get-LauncherAgendado)
    $ps = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $acao = New-ScheduledTaskAction -Execute $ps -Argument "-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand $enc"
    if ($Agendar -eq 'Diario') { $gat = New-ScheduledTaskTrigger -Daily -At '02:30' -RandomDelay (New-TimeSpan -Minutes 20) }
    else { $gat = New-ScheduledTaskTrigger -Weekly -DaysOfWeek Monday -At '02:30' -RandomDelay (New-TimeSpan -Minutes 20) }
    $pri = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $cfg = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Hours 1) -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries
    [void](Register-ScheduledTask -TaskName $script:TaskName -Action $acao -Trigger $gat -Principal $pri -Settings $cfg `
            -Description 'WiseDB: baixa a versao publicada do wizard, confere o SHA-256 e coleta metadados (somente leitura).' -Force)
    Write-Msg "Agendado ($Agendar) como SYSTEM: tarefa '$script:TaskName'. Config: $arq (link: $(Get-LinkMascarado $lnk))"
    Write-Msg 'Lembrete: a conta SYSTEM precisa de login no SQL Server (ver LEIAME.md, secao Permissoes).'
    return 0
}

function Invoke-RemoverAgendamento {
    if (-not (Test-Admin)) { Write-Msg 'Remover agendamento exige PowerShell como Administrador.'; return 2 }
    $t = Get-ScheduledTask -TaskName $script:TaskName -ErrorAction SilentlyContinue
    if ($t) { Unregister-ScheduledTask -TaskName $script:TaskName -Confirm:$false; Write-Msg "Tarefa '$script:TaskName' removida." }
    else { Write-Msg "Tarefa '$script:TaskName' nao existe." }
    $dir = Get-ConfDir
    if (Test-Path -LiteralPath $dir) { Remove-Item -LiteralPath $dir -Recurse -Force; Write-Msg "Removido: $dir" }
    return 0
}

# ---------------------------------------------------------------- principal

function Invoke-Main {
    if ($Simular) {
        if (-not (Test-Path -LiteralPath $Simular -PathType Container)) { Write-Msg "Pasta de fixtures nao existe: $Simular"; return 6 }
        $script:SimDir = (Resolve-Path -LiteralPath $Simular).Path
    }
    if ($SqlCredencial) { $script:SqlCred = $SqlCredencial }
    elseif ($env:WISEDB_SQL_USER -and $env:WISEDB_SQL_PASSWORD) {
        $sec = ConvertTo-SecureString -String $env:WISEDB_SQL_PASSWORD -AsPlainText -Force
        $script:SqlCred = New-Object System.Management.Automation.PSCredential($env:WISEDB_SQL_USER, $sec)
    }
    if ($Agendar) { return (Invoke-Agendar) }
    if ($RemoverAgendamento) { return (Invoke-RemoverAgendamento) }

    $hostInfo = Get-HostInfo

    if ($Descobrir) {
        $inv = Invoke-Descoberta $false
        $n = Get-NuvemMeta
        Write-Msg ("Host: $($hostInfo.nome) | SO: $($hostInfo.so) | Nuvem: $(if ($n.provedor) { $n.provedor } else { 'nenhuma detectada' })")
        Write-Msg ("CLIs de nuvem: " + $(if ((Get-ClisNuvem).Count) { (Get-ClisNuvem) -join ', ' } else { '(nenhuma)' }))
        if ($inv.Count -eq 0) { Write-Msg 'Nenhum banco encontrado (SQL Server, Oracle, MySQL, PostgreSQL, MongoDB).' }
        else { $inv | Format-Table motor, instancia, versao, acesso, detalhe -AutoSize | Out-String -Width 200 | Write-Host }
        return 0
    }

    $conf = Read-Conf
    $cli = $Cliente; if (-not $cli) { $cli = $conf['CLIENTE'] }
    $lnk = $Link; if (-not $lnk) { $lnk = $conf['LINK'] }
    $script:LinkAtual = $lnk
    $enviar = -not $Coletar
    if ($Coletar -and -not $Saida) { Write-Msg '-Coletar exige -Saida <arquivo.json.gz>.'; return 1 }
    if (-not $cli -or $cli -notmatch '^[A-Za-z0-9._-]+$') { Write-Msg 'Informe -Cliente (ou coleta.conf).'; return 3 }
    if ($enviar -and (-not $lnk -or $lnk -notmatch '^https://')) { Write-Msg 'Informe -Link (URL https do PAR) ou use -Coletar -Saida.'; return 3 }
    if ($enviar) { Write-Msg "Destino: $(Get-LinkMascarado $lnk)" }

    $inv = Invoke-Descoberta $true
    $n = Get-NuvemMeta
    $clis = Get-ClisNuvem
    $env_ = New-Envelope $cli $inv $hostInfo $n $clis
    $okInst = @($inv | Where-Object { $_.acesso -eq 'ok' }).Count
    Write-Msg "Instancias: $($inv.Count) (acesso ok: $okInst). Crescimento: $($script:Cresc.Count) linhas. Backups: $($script:Back.Count) linhas. Avisos: $($script:Avisos.Count)."
    if ($inv.Count -eq 0 -or ($script:Cresc.Count -eq 0 -and $script:Back.Count -eq 0)) {
        Write-Msg 'Nada coletado (nenhuma instancia acessivel ou sem dados). Nada sera enviado.'
        foreach ($a in $script:Avisos) { Write-Msg "  aviso: $a" }
        return 4
    }

    $ts = [datetime]::UtcNow.ToString("yyyyMMdd'T'HHmmss'Z'", [Globalization.CultureInfo]::InvariantCulture)
    if ($Coletar) {
        Write-GzJson $env_ $Saida
        Write-Msg "Gravado: $Saida"
        return 0
    }
    $dir = New-DirTrabalho
    try {
        $tmp = Join-Path $dir "$ts.json.gz"
        Write-GzJson $env_ $tmp
        $ok = Send-Coleta $tmp $lnk $cli $hostInfo.nome $ts
    }
    finally { Remove-Item -LiteralPath $dir -Recurse -Force -ErrorAction SilentlyContinue }
    if (-not $ok) { Write-Msg 'ERRO: envio nao concluido (codigo 5).'; return 5 }
    return 0
}

if ($env:WISEDB_COLETA_NOMAIN -ne '1') {
    try { $script:ExitCode = [int](Invoke-Main | Select-Object -Last 1) }
    catch {
        Write-Host ('ERRO interno: ' + (Limpa (Protege $_.Exception.Message) 300))
        $script:ExitCode = 6
    }
    exit $script:ExitCode
}
