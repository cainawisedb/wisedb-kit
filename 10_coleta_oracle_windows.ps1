<#
===============================================================================
 10_coleta_oracle_windows.ps1 - WiseDB | Kit de Coleta para Politica de Backup
 v1.0 (outubro/2026)

 OBJETIVO : Equivalente Windows do 02_coleta_oracle.sh. Para cada servico
            OracleService<SID> em execucao: RMAN SHOW ALL / REPORT / LIST,
            historico de 35 dias, archivelog, FRA, Data Guard, directories,
            jobs de Data Pump e evidencias de dump recentes.
 RISCO    : Zero. Somente SELECT, SHOW, LIST e REPORT.
 EXECUCAO : PowerShell como administrador (membro do grupo ORA_DBA para
            "/ as sysdba"):
              powershell -ExecutionPolicy Bypass -File .\10_coleta_oracle_windows.ps1
              ... -Sids ORCL,ERP   (padrao: todos os OracleService* ativos)
 SAIDA    : .\coleta_<hostname>_<data>\02_oracle\  (mesmo layout do Linux, o
            wisedb_digest.py le sem distincao)
===============================================================================
#>
param([string[]]$Sids = @())

$Hostn = $env:COMPUTERNAME
$Out = Join-Path "." ("coleta_{0}_{1}" -f $Hostn, (Get-Date -Format yyyyMMdd))
$Out = Join-Path $Out "02_oracle"
New-Item -ItemType Directory -Force -Path $Out | Out-Null
function Diga($t){ Write-Host ("  [{0}] {1}" -f (Get-Date -Format 'HH:mm:ss'), $t) }

if ($Sids.Count -eq 0) {
  $Sids = @(Get-Service -Name 'OracleService*' -ErrorAction SilentlyContinue |
            Where-Object { $_.Status -eq 'Running' } |
            ForEach-Object { $_.Name -replace '^OracleService','' })
}
if ($Sids.Count -eq 0) { Diga "Nenhum servico OracleService* em execucao"; exit 1 }
Diga ("SIDs a coletar: {0}" -f ($Sids -join ', '))

# ORACLE_HOME por SID: registro (HKLM\SOFTWARE\ORACLE\KEY_*), senao PATH.
function Get-OraHome($sid) {
  try {
    $ks = @(Get-ChildItem 'HKLM:\SOFTWARE\ORACLE' -ErrorAction Stop | Where-Object { $_.PSChildName -like 'KEY_*' } |
            ForEach-Object { Get-ItemProperty $_.PSPath } | Where-Object { $_.ORACLE_HOME })
    $k = @($ks | Where-Object { $_.ORACLE_SID -eq $sid }) + @($ks) | Select-Object -First 1
    if ($k) { return $k.ORACLE_HOME }
  } catch { }
  return $null
}
function Get-OraBin($oh, $exe) {
  if ($oh) { foreach ($e in @("$exe.exe", $exe)) { $p = Join-Path (Join-Path $oh 'bin') $e; if (Test-Path $p) { return $p } } }
  $c = Get-Command $exe -ErrorAction SilentlyContinue | Select-Object -First 1
  if ($c) { return $c.Source }
  return $null
}

$Sql = @'
set pages 200 lines 200 trimspool on feedback off
col name for a15
col value for a55
prompt ### IDENTIFICACAO
select name, dbid, database_role role, log_mode, open_mode, created from v$database;
select banner from v$version where rownum=1;
select instance_name, host_name, status, to_char(startup_time,'DD/MM/YYYY HH24:MI') startup from v$instance;
prompt ### PDBs (multitenant)
col pdb for a25
select name pdb, open_mode, restricted from v$pdbs order by name;
prompt ### TAMANHO REAL (CDB + PDBs, GB)
select round(sum(bytes)/1024/1024/1024,2) total_gb from cdb_data_files;
select con_id, round(sum(bytes)/1024/1024/1024,2) gb from cdb_data_files group by con_id order by 1;
prompt ### DESTINOS DE ARCHIVE / FRA
show parameter db_recovery_file_dest
col destino for a45
col alvo for a10
select dest_id, destination destino, status, target alvo, binding
from v$archive_dest where destination is not null order by dest_id;
select round(space_used/1024/1024/1024,2) fra_usado_gb,
       round(space_limit/1024/1024/1024,2) fra_limite_gb,
       round(space_used/decode(space_limit,0,null,space_limit)*100,1) pct
from v$recovery_file_dest;
prompt ### STANDBY / DATA GUARD (prova explicita de ausencia ou presenca)
prompt ### Sem esta consulta a ausencia de DR e apenas suposicao do analista.
select count(*) destinos_standby from v$archive_dest
where target = 'STANDBY' and destination is not null;
col db_unique_name for a30
col value for a40
select db_unique_name, database_role, protection_mode, protection_level,
       switchover_status, force_logging
from v$database;
col parent_dbun for a30
col dest_role for a20
select db_unique_name, parent_dbun, dest_role from v$dataguard_config where rownum <= 20;
prompt ### RMAN 35 DIAS - RESUMO AGREGADO POR TIPO
col input_type for a12
col primeiro for a16
col ultimo for a16
select input_type,
       count(*) execucoes,
       sum(case when status like 'COMPLETED%' then 1 else 0 end) ok,
       sum(case when status like '%FAILED%' then 1 else 0 end) falhas,
       to_char(min(start_time),'DD/MM HH24:MI') primeiro,
       to_char(max(start_time),'DD/MM HH24:MI') ultimo,
       round(avg(output_bytes)/1024/1024/1024,2) media_gb,
       round(max(elapsed_seconds)/60,1) max_min
from v$rman_backup_job_details where start_time > sysdate-35
group by input_type order by 1;
prompt ### RMAN 35 DIAS - HORARIO TIPICO POR TIPO
select input_type, to_char(start_time,'HH24') hora, count(*) qtd
from v$rman_backup_job_details where start_time > sysdate-35
group by input_type, to_char(start_time,'HH24') having count(*) > 2 order by 1,2;
prompt ### RMAN - NIVEL 0 x NIVEL 1 (por dia, via v$backup_datafile)
col dia for a12
select to_char(trunc(completion_time),'DD/MM DY') dia,
       incremental_level nivel,
       count(*) datafiles,
       round(sum(blocks*block_size)/1024/1024/1024,2) gb
from v$backup_datafile
where completion_time > sysdate-35 and incremental_level is not null
group by trunc(completion_time), incremental_level
order by trunc(completion_time) desc, incremental_level;
prompt ### RMAN - ULTIMO NIVEL 0 SEM JANELA DE 35 DIAS (evita concluir "sem full")
prompt ### Em destino gerenciado (Recovery Service/ZDLRA) o nivel 0 pode ser antigo
prompt ### por design, com consolidacao no proprio servico. Ausencia na janela de
prompt ### 35 dias NAO significa ausencia de backup full.
select incremental_level nivel,
       to_char(max(completion_time),'DD/MM/YYYY HH24:MI') ultimo,
       round(sysdate - max(completion_time)) dias_atras,
       count(*) datafiles_total
from v$backup_datafile
where incremental_level is not null
group by incremental_level order by 1;
prompt ### RMAN - FALHAS (v$rman_backup_job_details, ultimos 35 dias)
select * from (select to_char(start_time,'DD/MM/YYYY HH24:MI') inicio, input_type, status
from v$rman_backup_job_details
where start_time > sysdate-35 and status not like 'COMPLETED%' order by start_time desc) where rownum <= 15;
prompt ### RMAN - FALHAS AGRUPADAS POR TIPO (identifica falha sistemica x pontual)
select input_type,
       count(*) falhas,
       to_char(min(start_time),'DD/MM HH24:MI') primeira,
       to_char(max(start_time),'DD/MM HH24:MI') ultima,
       count(distinct to_char(start_time,'HH24:MI')) horarios_distintos
from v$rman_backup_job_details
where start_time > sysdate-35 and status not like 'COMPLETED%'
group by input_type order by falhas desc;
prompt ### RMAN - FALHAS (v$rman_status, detalhe operacional)
col operacao for a28
col objeto for a14
col device for a10
select * from (select to_char(start_time,'DD/MM HH24:MI') inicio, operation operacao,
       object_type objeto, status, output_device_type device
from v$rman_status
where start_time > sysdate-35 and status like '%FAILED%'
order by start_time desc) where rownum <= 20;
prompt ### RMAN - OUTPUT DA FALHA MAIS RECENTE (causa raiz)
col output for a110
select output from (select output from v$rman_output
where session_key = (select max(session_key) from v$rman_status
                     where status like '%FAILED%' and start_time > sysdate-35)
order by recid) where rownum <= 40;
prompt ### RMAN - CAUSA RAIZ POR TIPO DE OBJETO QUE FALHA (uma falha por tipo)
prompt ### A consulta acima traz apenas a falha mais recente do banco inteiro.
prompt ### Quando um tipo falha todos os dias, ele pode ficar mascarado por outro.
col objeto for a14
select objeto, output from (select s.object_type objeto, o.output
from v$rman_output o
join (select object_type, max(session_key) sk
      from v$rman_status
      where status like '%FAILED%' and start_time > sysdate-35
        and object_type is not null
      group by object_type) f on f.sk = o.session_key
join v$rman_status s on s.session_key = f.sk and s.object_type = f.object_type
where o.output is not null
order by s.object_type, o.recid) where rownum <= 120;
prompt ### ARCHIVELOG - VOLUME REAL POR DIA (7 DIAS)
select to_char(completion_time,'DD/MM') dia, count(*) qtd_archives,
       round(sum(blocks*block_size)/1024/1024/1024,1) gb
from v$archived_log where completion_time > sysdate-7
group by to_char(completion_time,'DD/MM') order by 1;
prompt ### ARCHIVELOG - MAIOR INTERVALO SEM ARCHIVE (7 DIAS, indica RPO real)
select round(max(gap)*24*60) maior_gap_min from (
  select completion_time - lag(completion_time) over (order by completion_time) gap
  from v$archived_log where completion_time > sysdate-7);
prompt ### BACKUPSETS EM DISCO x SBT (onde as copias realmente estao)
select device_type, count(*) pecas, round(sum(bytes)/1024/1024/1024,2) gb,
       to_char(max(completion_time),'DD/MM HH24:MI') mais_recente
from v$backup_piece_details where completion_time > sysdate-35
group by device_type order by 1;
prompt ### CONTROLFILE AUTOBACKUP (evidencia do catalogo de metadados)
select count(*) autobackups_35d, to_char(max(completion_time),'DD/MM/YYYY HH24:MI') ultimo
from v$backup_piece
where autobackup_date is not null and completion_time > sysdate-35 and status='A';
prompt ### DIRECTORIES nao padrao (destinos de expdp)
col directory_path for a70
select directory_name, directory_path from dba_directories
where directory_path not like '%/dbhome%' and directory_path not like '/u01/app/oracle' order by 1;
prompt ### DATAPUMP - JOBS REGISTRADOS NO BANCO
col owner_name for a18
col job_name for a30
col operation for a10
col job_mode for a10
select owner_name, job_name, operation, job_mode, state
from dba_datapump_jobs order by 1,2;
prompt ### JOBS DBMS_SCHEDULER de backup
col job_name for a40
col repeat_interval for a45
select owner||'.'||job_name job_name, enabled, state, repeat_interval
from dba_scheduler_jobs
where upper(job_name) like '%BKP%' or upper(job_name) like '%BACKUP%' or upper(job_name) like '%EXP%';
exit
'@

$Rman = @'
SHOW ALL;
SHOW ENCRYPTION ALGORITHM;
REPORT NEED BACKUP;
REPORT UNRECOVERABLE;
LIST BACKUP OF CONTROLFILE COMPLETED AFTER 'SYSDATE-8';
exit
'@

$Falhas = 0
foreach ($sid in $Sids) {
  Diga "Coletando $sid"
  $env:ORACLE_SID = $sid
  $oh = Get-OraHome $sid
  if ($oh) { $env:ORACLE_HOME = $oh }
  $sqlplus = Get-OraBin $oh 'sqlplus'; $rman = Get-OraBin $oh 'rman'
  $F = Join-Path $Out $sid
  if (-not $sqlplus) {
    "[ERRO] sqlplus nao encontrado para $sid (ORACLE_HOME='$oh')." | Out-File "${F}_sql.txt" -Encoding utf8
    Diga "  sqlplus nao encontrado para $sid"; $Falhas++; continue
  }
  $Sql | & $sqlplus -S '/ as sysdba' 2>&1 | Out-File "${F}_sql.txt" -Encoding utf8
  if ((Get-Content "${F}_sql.txt" -Raw) -notmatch '### IDENTIFICACAO') {
    Diga "  $sid sem conexao '/ as sysdba' (usuario fora do ORA_DBA?)"; $Falhas++
  }
  if ($rman) { $Rman | & $rman target / 2>&1 | Out-File "${F}_rman.txt" -Encoding utf8 }
  else { "[AVISO] rman nao encontrado" | Out-File "${F}_rman.txt" -Encoding utf8 }

  # Destino SBT (mesmo formato do Linux, lido pelo digest)
  $r = Get-Content "${F}_rman.txt" -Raw -ErrorAction SilentlyContinue
  $sb = @("################################################################", "## DESTINO REAL DO SBT ($sid)",
          "## Coletado em: $(Get-Date -Format 'dd/MM/yyyy HH:mm:ss') | Host: $Hostn",
          "################################################################")
  if ($r -match "SBT_LIBRARY=([^,' ]+)") {
    $lib = $Matches[1]; $sb += "SBT_LIBRARY: $lib"
    if ($lib -match 'opc') { $sb += "Tipo de destino (inferido): OCI Object Storage via Database Cloud Backup Module" }
    elseif ($lib -match 'ra') { $sb += "Tipo de destino (inferido): OCI Recovery Service / Recovery Appliance (DBRS)" }
    else { $sb += "Tipo de destino (inferido): appliance de terceiro ou nao reconhecido" }
  } else { $sb += "Nenhum SBT_LIBRARY declarado no SHOW ALL: backup fisico provavelmente so em DISK" }
  $sb | Out-File "${F}_destino_sbt.txt" -Encoding utf8
}

# Evidencia de backup logico: diretorios do DBA_DIRECTORIES coletados acima
$Exp = Join-Path $Out "expdp_logs_recentes.txt"
$dirs = @(Get-ChildItem $Out -Filter '*_sql.txt' | ForEach-Object { Get-Content $_.FullName } |
          Select-String -Pattern '([A-Za-z]:\\[^\s|]+)' -AllMatches | ForEach-Object { $_.Matches } |
          ForEach-Object { $_.Groups[1].Value.TrimEnd('\') } | Sort-Object -Unique | Where-Object { Test-Path $_ })
$linhas = @("################ EVIDENCIA DE BACKUP LOGICO (Data Pump) ################", "## Diretorios varridos:")
$linhas += ($dirs | ForEach-Object { "##   $_" })
$achou = $false
foreach ($d in $dirs) {
  $arqs = Get-ChildItem $d -Recurse -Include *.dmp,*.log -ErrorAction SilentlyContinue |
          Where-Object { $_.LastWriteTime -gt (Get-Date).AddDays(-8) } | Sort-Object LastWriteTime -Descending | Select-Object -First 30
  foreach ($a in $arqs) { $achou = $true; $linhas += ("{0:yyyy-MM-dd HH:mm} {1,12}  {2}" -f $a.LastWriteTime, $a.Length, $a.FullName) }
}
if (-not $achou) { $linhas += "[SEM EVIDENCIA] Nenhum dump/log com menos de 8 dias nos diretorios do DBA_DIRECTORIES. Isto NAO prova ausencia de backup logico." }
$linhas | Out-File $Exp -Encoding utf8

Diga "Modulo 10 (Oracle Windows) concluido em $Out"
if ($Falhas -ge $Sids.Count) { exit 2 } elseif ($Falhas -gt 0) { exit 3 }
