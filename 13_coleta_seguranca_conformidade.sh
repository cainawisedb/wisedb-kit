#!/bin/bash
#===============================================================================
# 13_coleta_seguranca_conformidade.sh - WiseDB | Varredura de seguranca e
# conformidade do backup (vulnerabilidades e inconformidades)
#
# OBJETIVO : Encontrar, com evidencia, o que deixa o backup vulneravel ou fora
#            das boas praticas, para registrar na politica e fundamentar o
#            plano de adequacao:
#              - repositorio de backup montado com escrita no servidor de
#                producao (ransomware alcanca banco e backup juntos)
#              - exports NFS permissivos (*, no_root_squash, insecure, sec=sys)
#              - servidor de backup sem imutabilidade/snapshot (so deduplicacao)
#              - retencao curta, full unico, full apagado antes do novo full
#              - janela de backup longa, falhas, ausencia de VALIDATE
#              - NOARCHIVELOG, archivelog atrasado, backup no mesmo disco dos
#                dados, backup sem criptografia, FRA cheia
#              - SO e banco fora de suporte, patches, firewall, SSH, SELinux,
#                auditoria, antivirus/EDR, credenciais de off-site expostas
# SAIDA    : ./coleta_<host>_<data>/13_seguranca/
#              achados.tsv     um achado por linha (severidade, categoria,
#                              pilar 3-2-1-1-0, chave, titulo, evidencia,
#                              impacto, recomendacao, oportunidade, host)
#              evidencias.txt  fatos brutos que sustentam os achados
# RISCO    : Zero. Somente leitura. Nenhum valor de senha e lido ou gravado:
#            scripts sao analisados em memoria e so numero de linha e caminho
#            vao para a evidencia.
# EXECUCAO : No servidor de banco E no servidor/repositorio de backup:
#              bash 13_coleta_seguranca_conformidade.sh
#            Opcional: WISEDB_ORA_SIDS="SID1 SID2", WISEDB_DIRS="/bkp /u03",
#            WISEDB_SUDO=1 (usa sudo -n quando liberado).
#
# Versao 1.0 (outubro/2026)
#===============================================================================
set -uo pipefail
export LC_ALL=C
HOSTN=$(hostname -s 2>/dev/null || hostname)
OUT="./coleta_${HOSTN}_$(date +%Y%m%d)/13_seguranca"
mkdir -p "$OUT" || { echo "[ERRO] nao foi possivel criar $OUT"; exit 1; }
EV="$OUT/evidencias.txt"; ACH="$OUT/achados.tsv"
: > "$EV"
printf 'ID\tSEVERIDADE\tCATEGORIA\tPILAR_32110\tCHAVE\tTITULO\tEVIDENCIA\tIMPACTO\tRECOMENDACAO\tOPORTUNIDADE\tHOST\n' > "$ACH"
# Arquivos alternativos existem so para teste automatizado do kit.
MOUNTS_FILE="${WISEDB_T13_MOUNTS:-/proc/mounts}"
FSTAB_FILE="${WISEDB_T13_FSTAB:-/etc/fstab}"
EXPORTS_GLOB="${WISEDB_T13_EXPORTS:-/etc/exports /etc/exports.d/*.exports}"

tem(){ command -v "$1" >/dev/null 2>&1; }
if tem timeout; then TO(){ local s="$1"; shift; timeout -k 5 "$s" "$@"; }; else TO(){ shift; "$@"; }; fi
SUDO=""
if [ "$(id -u)" != "0" ] && [ "${WISEDB_SUDO:-0}" = "1" ] && tem sudo && sudo -n true 2>/dev/null; then SUDO="sudo -n"; fi
log(){ echo "[$(date '+%H:%M:%S')] $*"; }
evid(){ { echo "################ $1"; shift; printf '%s\n' "$@"; echo; } >> "$EV"; }
limpa(){ printf '%s' "$*" | tr '\t\r\n' '   ' | cut -c1-400; }
N=0; NC=0; NA=0; NM=0
achado(){ # SEV CATEGORIA PILAR CHAVE OPORTUNIDADE "titulo" "evidencia" "impacto" "recomendacao"
  N=$((N+1))
  case "$1" in CRITICO) NC=$((NC+1));; ALTO) NA=$((NA+1));; MEDIO) NM=$((NM+1));; esac
  printf 'SEG-%03d\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$N" "$1" "$2" "$3" "$4" \
    "$(limpa "$6")" "$(limpa "$7")" "$(limpa "$8")" "$(limpa "$9")" "$5" "$HOSTN" >> "$ACH"
  printf '  [%-7s] %s\n' "$1" "$6"
}
# caminho $1 esta dentro do ponto de montagem $2?
dentro(){ case "$1/" in "$2"/*|"$2/") return 0;; esac; [ "$2" = "/" ]; }
BKP_RX='backup|bkp|bck|rman|dump|stage|fra|recovery|bkup'

log "Varredura de seguranca e conformidade em $HOSTN (saida em $OUT)"

#--- 1. Papel do host -----------------------------------------------------------
E_DB=0
pgrep -f 'ora_pmon_|postgres.* -D|postmaster|mysqld|mariadbd|sqlservr' >/dev/null 2>&1 && E_DB=1
EXP_TXT=$(cat $EXPORTS_GLOB 2>/dev/null | sed -e ':a' -e '/\\$/N; s/\\\n//; ta' | sed 's/#.*//' | grep -v '^[[:space:]]*$' || true)
E_NFSSRV=0; [ -n "$EXP_TXT" ] && E_NFSSRV=1
{ tem systemctl && systemctl is-active -q nfs-server 2>/dev/null; } && E_NFSSRV=1
E_VEEAM=0; pgrep -f 'veeamtransport|veeamimmureposvc|veeamagent|veeamservice' >/dev/null 2>&1 && E_VEEAM=1
E_REPO=0; { [ "$E_NFSSRV" = "1" ] || [ "$E_VEEAM" = "1" ]; } && E_REPO=1
PAPEL="servidor"
[ "$E_DB" = "1" ] && PAPEL="servidor de banco (producao)"
[ "$E_REPO" = "1" ] && PAPEL="${PAPEL} + servidor/repositorio de backup"
evid "PAPEL DO HOST" "Papel inferido: $PAPEL" "SGBD ativo: $E_DB | servidor NFS: $E_NFSSRV | Veeam: $E_VEEAM" "Usuario: $(whoami) | sudo: ${SUDO:-nao}"
log "Papel inferido: $PAPEL"

#--- 2. Scripts de backup (analise em memoria, nada e copiado) -----------------
declare -a SCRIPTS=()
LISTA=$( { crontab -l 2>/dev/null; cat /etc/crontab /etc/cron.d/* 2>/dev/null
           [ -n "$SUDO" ] && $SUDO sh -c 'cat /var/spool/cron/* /var/spool/cron/crontabs/* 2>/dev/null'; } |
         grep -v '^[[:space:]]*#' | grep -Eo '/[A-Za-z0-9._/-]+\.(sh|ksh|bash|rman|rcv|cmd|sql)' | sort -u )
for s in $LISTA; do
  [ -r "$s" ] && SCRIPTS+=("$s")
  # scripts chamados por estes (um nivel)
  for t in $(TO 5 grep -Eo '/[A-Za-z0-9._/-]+\.(sh|ksh|bash|rman|rcv|cmd)' "$s" 2>/dev/null | sort -u); do
    [ -r "$t" ] && SCRIPTS+=("$t")
  done
done
mapfile -t SCRIPTS < <(printf '%s\n' ${SCRIPTS[@]+"${SCRIPTS[@]}"} | grep -v '^$' | sort -u)
SCR_VALIDATE=0; SCR_RMAN=0; declare -a DEL_ANTES=() FMT_DIRS=()
for s in ${SCRIPTS[@]+"${SCRIPTS[@]}"}; do
  txt=$(TO 5 cat "$s" 2>/dev/null) || continue
  echo "$txt" | grep -qiE 'rman|backup[[:space:]]+(incremental|database|as[[:space:]]|full|archivelog)' && SCR_RMAN=1
  echo "$txt" | grep -qiE 'validate|crosscheck' && SCR_VALIDATE=1
  # exclusao de backup: comando RMAN ou rm de artefato de backup (nunca de log)
  ld=$( { echo "$txt" | grep -niE 'delete[[:space:]]+(noprompt[[:space:]]+)?(force[[:space:]]+)?(noprompt[[:space:]]+)?(obsolete|backup|backupset|copy)'
          echo "$txt" | grep -niE '(^|[;&|[:space:]])rm[[:space:]]+-[a-zA-Z]*f' | grep -iE '\.(bkp|bk|dmp|bak|rman)([^a-z]|$)|backupset|/(full|level0|l0|rman)[^[:space:]]*\*' | grep -viE '\.(log|lst|txt|out|trc)([^a-z]|$)'; } |
        cut -d: -f1 | sort -n | head -1)
  # backup full: nivel 0, FULL ou DATABASE, nunca nivel 1+ nem so archivelog
  lb=$(echo "$txt" | grep -niE 'backup[[:space:]].*(incremental[[:space:]]+level[[:space:]]*=?[[:space:]]*0|database|full)' | grep -viE 'level[[:space:]]*=?[[:space:]]*[1-9]|delete|crosscheck|list[[:space:]]|report[[:space:]]' | head -1 | cut -d: -f1)
  if [ -n "$ld" ] && [ -n "$lb" ] && [ "$ld" -lt "$lb" ]; then DEL_ANTES+=("$s (exclusao na linha $ld, backup full na linha $lb)"); fi
  while IFS= read -r f; do d=$(dirname "$f"); [ "${d#/}" != "$d" ] && FMT_DIRS+=("$d"); done < <(echo "$txt" | grep -oiE "format[[:space:]]+['\"][^'\"]+" | sed -E "s/^[Ff][Oo][Rr][Mm][Aa][Tt][[:space:]]+['\"]//")
done
evid "SCRIPTS DE BACKUP ANALISADOS (conteudo nao copiado)" "Total: ${#SCRIPTS[@]}" ${SCRIPTS[@]+"${SCRIPTS[@]}"} \
  "Usam RMAN: $SCR_RMAN | Contem VALIDATE/CROSSCHECK: $SCR_VALIDATE"
if [ ${#DEL_ANTES[@]} -gt 0 ]; then
  achado ALTO RETENCAO 3 BKP_DELETE_ANTES_FULL SUSTENTACAO_DB \
    "Backup anterior e excluido ANTES do novo full: durante a execucao o ambiente fica sem backup" \
    "${DEL_ANTES[*]}" \
    "Se o novo full falhar ou o servidor for perdido durante a janela, nao existe nenhum backup para restaurar" \
    "Excluir o backup antigo somente apos o novo full concluir e ser validado (DELETE OBSOLETE ao final), com retencao que mantenha ao menos 2 fulls"
fi

#--- 3. Oracle: postura de backup por instancia --------------------------------
declare -a PIECE_DIRS=() ORA_ACH_DIRS=()
SIDS="${WISEDB_ORA_SIDS:-}"
[ -z "$SIDS" ] && SIDS=$(ps -eo args 2>/dev/null | sed -n 's/^ora_pmon_\(.*\)$/\1/p' | grep -v '^+' | sort -u | tr '\n' ' ')
ora_env(){ local s="$1" h="" pid
  h=$(awk -F: -v s="$s" '$1==s{print $2; exit}' /etc/oratab 2>/dev/null)
  [ -z "$h" ] && h=$(awk -F: -v s="${s%[0-9]}" '$1==s{print $2; exit}' /etc/oratab 2>/dev/null)
  if [ -z "$h" ]; then pid=$(pgrep -f "^ora_pmon_${s}\$" 2>/dev/null | head -1)
    [ -n "$pid" ] && h=$(tr '\0' '\n' < "/proc/$pid/environ" 2>/dev/null | sed -n 's/^ORACLE_HOME=//p' | head -1); fi
  [ -n "$h" ] && export ORACLE_HOME="$h" PATH="$h/bin:$PATH"
  export ORACLE_SID="$s"
}
for SID in $SIDS; do
  F="$OUT/oracle_${SID}.txt"
  ( ora_env "$SID"
    if ! tem sqlplus; then echo "SEM_SQLPLUS"; exit 0; fi
    TO 180 sqlplus -S -L / as sysdba <<'SQL_EOF'
set pages 0 lines 500 feedback off heading off verify off trimspool on echo off tab off
whenever sqlerror continue
alter session set nls_numeric_characters='.,';
select 'LOG_MODE='||log_mode from v$database;
select 'ROLE='||database_role from v$database;
select 'VERSAO='||version from v$instance;
select 'EDICAO='||case when banner like '%Enterprise%' then 'EE' when banner like '%Standard%' then 'SE' when banner like '%Express%' then 'XE' else 'OUTRA' end from v$version where rownum=1;
select 'BCT='||status from v$block_change_tracking;
select 'CFG|'||name||'|'||value from v$rman_configuration;
select 'FULL='||count(distinct trunc(d.completion_time))||'|'||nvl(to_char(max(d.completion_time),'YYYY-MM-DD HH24:MI'),'-')||'|'||nvl(to_char(round(sysdate-max(d.completion_time),1)),'-') from v$backup_datafile d where d.file#=1 and nvl(d.incremental_level,0)=0 and exists (select 1 from v$backup_piece p where p.set_stamp=d.set_stamp and p.set_count=d.set_count and p.status='A');
select 'JANELA|'||input_type||'|'||count(*)||'|'||to_char(round(max(elapsed_seconds)/3600,1))||'|'||to_char(round(avg(elapsed_seconds)/3600,1))||'|'||sum(case when status like '%FAIL%' or status like '%ERROR%' then 1 else 0 end) from v$rman_backup_job_details where start_time > sysdate-35 group by input_type;
select 'VALIDATE_35D='||count(*) from v$rman_status where start_time > sysdate-35 and operation like '%VALIDATE%';
select 'CRIPTO='||nvl(sum(case when encrypted='YES' then 1 else 0 end),0)||'|'||count(*) from v$backup_piece where status='A' and completion_time > sysdate-35;
select * from (select distinct 'PDIR|'||device_type||'|'||substr(handle,1,instr(handle,'/',-1)-1) from v$backup_piece where status='A' and completion_time > sysdate-35) where rownum <= 30;
select * from (select distinct 'DFDIR|'||substr(name,1,instr(name,'/',-1)-1) from v$datafile) where rownum <= 30;
select 'FRA_PCT='||to_char(round(100*space_used/nullif(space_limit,0))) from v$recovery_file_dest;
select 'ARCH_ULT_H='||nvl(to_char(round((sysdate-max(completion_time))*24,1)),'-') from v$backup_set where backup_type='L';
select 'DG_DEST='||count(*) from v$archive_dest where target='STANDBY' and status='VALID';
select 'DNFS='||count(*) from v$dnfs_servers;
exit
SQL_EOF
  ) > "$F" 2>&1
  if grep -q '^SEM_SQLPLUS' "$F" || ! grep -q '^LOG_MODE=' "$F"; then
    evid "ORACLE $SID" "Consulta nao realizada (sqlplus ausente ou sem conexao / as sysdba). Trecho:" "$(head -5 "$F")"
    achado INFO GOVERNANCA - ORA_NAO_AVALIADO SUSTENTACAO_DB "Oracle $SID: postura de backup nao avaliada nesta coleta" \
      "sqlplus / as sysdba indisponivel para $SID neste usuario" "Achados de banco podem estar incompletos" \
      "Rodar a coleta como oracle (ou usuario com sysdba) no servidor do banco"
    continue
  fi
  v(){ sed -n "s/^$1=//p" "$F" | head -1; }
  LOGM=$(v LOG_MODE); ROLE=$(v ROLE); VER=$(v VERSAO); ED=$(v EDICAO); BCT=$(v BCT)
  FULLL=$(v FULL); NFULL=${FULLL%%|*}; ULTF=$(echo "$FULLL" | cut -d'|' -f2); IDADEF=$(echo "$FULLL" | cut -d'|' -f3)
  VAL=$(v VALIDATE_35D); CRI=$(v CRIPTO); ENC=${CRI%%|*}; TOTP=${CRI##*|}
  FRA=$(v FRA_PCT); ARCHH=$(v ARCH_ULT_H); DNFS=$(v DNFS)
  RET=$(sed -n 's/^CFG|RETENTION POLICY|//p' "$F" | head -1)
  CFA=$(sed -n 's/^CFG|CONTROLFILE AUTOBACKUP|//p' "$F" | head -1)
  ENCCFG=$(sed -n 's/^CFG|ENCRYPTION FOR DATABASE|//p' "$F" | head -1)
  evid "ORACLE $SID" "$(grep -E '^(LOG_MODE|ROLE|VERSAO|EDICAO|BCT|FULL|JANELA|VALIDATE_35D|CRIPTO|FRA_PCT|ARCH_ULT_H|DG_DEST|DNFS|CFG)' "$F")"
  while IFS='|' read -r _ dev dir; do [ "$dev" = "DISK" ] && [ -n "$dir" ] && PIECE_DIRS+=("$dir"); done < <(grep '^PDIR|' "$F")
  # 3.1 ARCHIVELOG
  if [ "$LOGM" = "NOARCHIVELOG" ] && [ "$ROLE" = "PRIMARY" ]; then
    achado CRITICO RECUPERABILIDADE - ORA_NOARCHIVELOG SUSTENTACAO_DB "Oracle $SID em NOARCHIVELOG" \
      "v\$database.log_mode=NOARCHIVELOG" \
      "Recuperacao so ate o ultimo full: toda transacao posterior e perdida (RPO = intervalo entre fulls)" \
      "Habilitar ARCHIVELOG com backup de archives recorrente, dimensionando a area de archive/FRA"
  fi
  # 3.2 Retencao
  if [ -z "$RET" ] || echo "$RET" | grep -qiE 'REDUNDANCY 1$'; then
    achado ALTO RETENCAO 3 ORA_RET_RED1 REPOSITORIO "Oracle $SID: retencao RMAN de uma unica copia (REDUNDANCY 1)" \
      "RETENTION POLICY: ${RET:-padrao (TO REDUNDANCY 1)}" \
      "Apenas um backup e mantido: corrupcao, falha ou exclusao desse backup deixa o banco sem recuperacao" \
      "Adotar RECOVERY WINDOW compativel com o RPO/historico exigido (ex.: 15 a 30 dias) e copias adicionais"
  elif echo "$RET" | grep -qiE 'TO NONE'; then
    achado ALTO RETENCAO 3 ORA_RET_NONE REPOSITORIO "Oracle $SID: sem politica de retencao no RMAN (TO NONE)" \
      "RETENTION POLICY TO NONE" "Retencao depende de exclusao manual ou por script, sem garantia de historico" \
      "Definir RECOVERY WINDOW no RMAN e remover exclusoes manuais dos scripts"
  else
    dias=$(echo "$RET" | grep -oE 'WINDOW OF [0-9]+' | grep -oE '[0-9]+')
    if [ -n "$dias" ] && [ "$dias" -le 7 ]; then
      achado ALTO RETENCAO - ORA_RET_CURTA REPOSITORIO "Oracle $SID: retencao de apenas $dias dias" "RETENTION POLICY $RET" \
        "Ataques e corrupcoes costumam ser descobertos depois de dias: com $dias dias o historico limpo pode ja ter sido descartado" \
        "Ampliar a retencao (ex.: 30 dias) e manter copias mensais de longo prazo no repositorio secundario/imutavel"
    elif [ -n "$dias" ] && [ "$dias" -lt 30 ]; then
      achado MEDIO RETENCAO - ORA_RET_CURTA REPOSITORIO "Oracle $SID: retencao de $dias dias (abaixo de 30)" "RETENTION POLICY $RET" \
        "Historico curto para investigacao de incidente e exigencias de auditoria" \
        "Avaliar retencao de 30 dias + copias mensais de longo prazo"
    fi
  fi
  # 3.3 Fulls disponiveis
  if [ -n "$NFULL" ] && [ "$NFULL" = "0" ]; then
    achado ALTO INTEGRIDADE 3 ORA_SEM_FULL SUSTENTACAO_DB "Oracle $SID: nenhum backup full/nivel 0 disponivel registrado no controlfile" \
      "v\$backup_datafile (file#1, nivel 0/full, peca disponivel): 0" \
      "Sem full disponivel nao ha ponto de partida para restauracao" \
      "Confirmar no catalogo RMAN; se confirmado, executar full imediatamente e revisar agendamento"
  elif [ "${NFULL:-0}" = "1" ] 2>/dev/null; then
    achado ALTO RETENCAO 3 ORA_FULL_UNICO REPOSITORIO "Oracle $SID: apenas 1 backup full/nivel 0 disponivel" \
      "Fulls disponiveis: 1 (ultimo em $ULTF)" \
      "Nao existe segunda opcao de restauracao se esse unico full estiver corrompido ou for apagado" \
      "Manter no minimo 2 fulls validados e uma copia em repositorio secundario"
  fi
  case "$IDADEF" in ''|-) ;; *) if awk -v d="$IDADEF" 'BEGIN{exit !(d>8)}'; then
    achado ALTO INTEGRIDADE 0 ORA_FULL_ANTIGO MONITORAMENTO "Oracle $SID: ultimo full ha $IDADEF dias" "Ultimo full/nivel 0: $ULTF" \
      "Restauracao exigiria aplicar dias de incrementais/archives (RTO maior) ou o agendamento falhou sem alerta" \
      "Verificar o agendamento e o monitoramento do backup full"; fi;; esac
  # 3.4 Janela e falhas
  while IFS='|' read -r _ tipo qtd hmax hmed nfal; do
    case "$tipo" in "DB FULL"|"DB INCR"|"DATAFILE FULL"|"DATAFILE INCR") ;; *) continue;; esac
    if awk -v h="$hmax" 'BEGIN{exit !(h>24)}'; then
      achado ALTO DESEMPENHO - ORA_JANELA_LONGA DESEMPENHO "Oracle $SID: janela de backup $tipo de ate ${hmax}h" \
        "v\$rman_backup_job_details 35 dias: $qtd execucoes, maxima ${hmax}h, media ${hmed}h" \
        "Backup que ultrapassa 24h sobrepoe a proxima execucao, impacta producao e indica RTO igualmente longo" \
        "Revisar estrategia (incremental/BCT, paralelismo, compressao, dNFS, rede dedicada ou appliance) e medir o tempo de restore"
    elif awk -v h="$hmax" 'BEGIN{exit !(h>8)}'; then
      achado MEDIO DESEMPENHO - ORA_JANELA_LONGA DESEMPENHO "Oracle $SID: janela de backup $tipo de ate ${hmax}h" \
        "v\$rman_backup_job_details 35 dias: $qtd execucoes, maxima ${hmax}h, media ${hmed}h" \
        "Janela longa aumenta impacto em producao e sugere RTO elevado" "Avaliar otimizacao da estrategia de backup"
    fi
    if [ "${nfal:-0}" -gt 0 ] 2>/dev/null; then
      achado ALTO INTEGRIDADE 0 ORA_FALHAS MONITORAMENTO "Oracle $SID: $nfal execucao(oes) $tipo com falha em 35 dias" \
        "v\$rman_backup_job_details: $nfal de $qtd com FAILED/ERRORS" "Backup com falha nao garante recuperacao no periodo afetado" \
        "Tratar a causa raiz e monitorar falhas com alerta ativo"
    fi
  done < <(grep '^JANELA|' "$F")
  # 3.5 Validacao
  if [ "${VAL:-0}" = "0" ] && [ "$SCR_VALIDATE" = "0" ]; then
    achado ALTO INTEGRIDADE 0 ORA_SEM_VALIDATE TESTES "Oracle $SID: backups nao sao validados (sem VALIDATE/RESTORE VALIDATE)" \
      "v\$rman_status 35 dias: 0 operacoes VALIDATE; scripts sem VALIDATE/CROSSCHECK" \
      "Falha fisica ou logica no backup so e descoberta no momento da restauracao" \
      "Agendar RESTORE DATABASE VALIDATE / BACKUP VALIDATE periodico e testes de restauracao documentados"
  fi
  # 3.6 Criptografia
  if [ "${TOTP:-0}" -gt 0 ] 2>/dev/null && [ "${ENC:-0}" = "0" ] && [ "$ENCCFG" != "ON" ]; then
    rec="Criptografar o backup (RMAN encryption exige Advanced Security em EE, exceto destino OCI) ou criptografar no repositorio/appliance"
    [ "$ED" = "SE" ] && rec="Em Standard Edition o RMAN nao criptografa backup em disco: criptografar no repositorio/appliance ou usar backup na OCI (criptografado)"
    achado MEDIO CRIPTOGRAFIA - ORA_SEM_CRIPTO CRIPTOGRAFIA "Oracle $SID: pecas de backup sem criptografia" \
      "v\$backup_piece 35 dias: 0 de $TOTP pecas criptografadas" \
      "Quem acessar o repositorio le os dados (dados pessoais e sensiveis: exposicao LGPD)" "$rec"
  fi
  # 3.7 Autobackup de controlfile
  if [ "$CFA" = "OFF" ] || { [ -z "$CFA" ] && echo "$VER" | grep -qE '^(10|11|12\.1)\.'; }; then
    achado MEDIO RECUPERABILIDADE - ORA_CF_AUTOBKP_OFF SUSTENTACAO_DB "Oracle $SID: autobackup de controlfile/spfile desligado" \
      "CONTROLFILE AUTOBACKUP: ${CFA:-OFF (padrao da versao $VER)}" \
      "Perda do controlfile dificulta ou impede a restauracao sem catalogo" "CONFIGURE CONTROLFILE AUTOBACKUP ON"
  fi
  # 3.8 BCT (recurso Enterprise Edition)
  if [ "$ED" = "EE" ] && [ "$BCT" = "DISABLED" ] && grep -q '^JANELA|DB INCR|' "$F"; then
    achado MEDIO DESEMPENHO - ORA_BCT_OFF DESEMPENHO "Oracle $SID: incremental sem Block Change Tracking" "v\$block_change_tracking: DISABLED" \
      "O incremental le o banco inteiro, alongando a janela" "Habilitar Block Change Tracking"
  fi
  # 3.9 FRA e archives
  if [ -n "$FRA" ] && [ "$FRA" -ge 85 ] 2>/dev/null; then
    achado MEDIO CAPACIDADE - ORA_FRA_CHEIA REPOSITORIO "Oracle $SID: FRA com ${FRA}% de uso" "v\$recovery_file_dest" \
      "FRA cheia para o banco (archiver stuck) e interrompe backups" "Ajustar limite, retencao ou capacidade da FRA"
  fi
  if [ "$LOGM" = "ARCHIVELOG" ] && [ "$ROLE" = "PRIMARY" ]; then
    if [ "$ARCHH" = "-" ]; then
      achado ALTO RECUPERABILIDADE - ORA_ARCH_SEM_BKP SUSTENTACAO_DB "Oracle $SID: nenhum backup de archivelog registrado" "v\$backup_set tipo L: nenhum" \
        "Sem archives no backup a recuperacao fica limitada ao ultimo full" "Agendar backup de archivelog (ex.: a cada 1 a 4 horas)"
    elif awk -v h="$ARCHH" 'BEGIN{exit !(h>24)}'; then
      achado ALTO RECUPERABILIDADE - ORA_ARCH_ATRASO MONITORAMENTO "Oracle $SID: ultimo backup de archivelog ha ${ARCHH}h" "v\$backup_set tipo L" \
        "RPO real superior a 24 horas" "Verificar agendamento e monitoramento do backup de archives"
    fi
  fi
  # 3.10 Versao fora de suporte
  case "$VER" in
    9.*|10.*) achado CRITICO CICLO_VIDA - ORA_EOL CICLO_VIDA "Oracle $SID: versao $VER sem suporte ha muitos anos" "v\$instance.version=$VER" \
                "Sem correcoes de seguranca e sem suporte do fabricante" "Planejar upgrade para versao suportada (ex.: 19c)";;
    11.*|12.*|18.*) achado ALTO CICLO_VIDA - ORA_EOL CICLO_VIDA "Oracle $SID: versao $VER fora do suporte padrao" "v\$instance.version=$VER" \
                "Sem patches de seguranca regulares; risco operacional e de conformidade" "Planejar upgrade para Oracle Database 19c";;
  esac
  # 3.11 Backup no mesmo filesystem dos dados
  for pd in $(grep '^PDIR|DISK|' "$F" | cut -d'|' -f3 | sort -u); do
    [ -d "$pd" ] || continue; dpd=$(TO 5 stat -c %d "$pd" 2>/dev/null) || continue
    for dd in $(grep '^DFDIR|/' "$F" | cut -d'|' -f2 | sort -u); do
      [ -d "$dd" ] || continue
      if [ "$(TO 5 stat -c %d "$dd" 2>/dev/null)" = "$dpd" ]; then ORA_ACH_DIRS+=("$SID: backup $pd no mesmo filesystem dos dados $dd"); break; fi
    done
  done
  if [ "$DNFS" = "0" ]; then ORA_SEM_DNFS="${ORA_SEM_DNFS:-}$SID "; fi
done
if [ ${#ORA_ACH_DIRS[@]} -gt 0 ]; then
  achado ALTO MIDIA 2 BKP_MESMO_DISCO REPOSITORIO "Backup gravado no mesmo filesystem/disco dos dados do banco" \
    "${ORA_ACH_DIRS[*]}" "Falha do disco, do storage ou do filesystem leva banco e backup juntos" \
    "Gravar o backup em armazenamento separado e manter copia em segunda midia"
fi

#--- 4. Exposicao do repositorio: montagens de rede -----------------------------
declare -a BKP_DIRS=()
for d in ${PIECE_DIRS[@]+"${PIECE_DIRS[@]}"} ${FMT_DIRS[@]+"${FMT_DIRS[@]}"} ${WISEDB_DIRS:-}; do BKP_DIRS+=("$d"); done
mapfile -t BKP_DIRS < <(printf '%s\n' ${BKP_DIRS[@]+"${BKP_DIRS[@]}"} | grep '^/' | sort -u)
declare -a EXPOSTOS=() SOFTS=() SECSYS=() RSIZE=() APPL=() NMOUNTS=()
NFS_BKP=0
while read -r src mnt fs opt _; do
  case "$fs" in nfs|nfs4|cifs|smb3|smbfs|glusterfs|fuse.sshfs|fuse.s3fs|fuse.rclone) ;; *) continue;; esac
  mnt=$(printf '%s' "$mnt" | sed 's/\\040/ /g')
  NMOUNTS+=("$src em $mnt ($fs, ${opt:0:90})")
  e_bkp=0; uso=""
  for b in ${BKP_DIRS[@]+"${BKP_DIRS[@]}"}; do dentro "$b" "$mnt" && { e_bkp=1; uso="destino em uso: $b"; break; }; done
  [ "$e_bkp" = "0" ] && echo "$mnt $src" | grep -qiE "$BKP_RX" && { e_bkp=1; uso="nome indica backup"; }
  [ "$e_bkp" = "1" ] || continue
  case "$fs" in nfs|nfs4) NFS_BKP=1;; esac
  persist="nao"; awk -v m="$mnt" '$1 !~ /^#/ && $2==m {f=1} END{exit !f}' "$FSTAB_FILE" 2>/dev/null && persist="sim (fstab)"
  case ",$opt," in *,rw,*) EXPOSTOS+=("$src em $mnt ($fs, rw, persistente: $persist, $uso)");; esac
  case ",$opt," in *,soft,*) SOFTS+=("$src em $mnt");; esac
  case "$fs" in nfs|nfs4) case ",$opt," in *,sec=krb5*) ;; *) SECSYS+=("$src em $mnt");; esac;; esac
  ws=$(echo "$opt" | grep -oE 'wsize=[0-9]+' | cut -d= -f2)
  [ -n "$ws" ] && [ "$ws" -lt 65536 ] && RSIZE+=("$src em $mnt (wsize=$ws)")
  echo "$src" | grep -qiE 'exagrid|datadomain|dd[0-9]|storeonce|quantum|dxi' && APPL+=("$src")
done < <(cat "$MOUNTS_FILE" 2>/dev/null)
evid "MONTAGENS DE REDE" "Total: ${#NMOUNTS[@]}" ${NMOUNTS[@]+"${NMOUNTS[@]}"} "Destinos de backup conhecidos: ${BKP_DIRS[*]:-nenhum}"
if [ ${#EXPOSTOS[@]} -gt 0 ]; then
  sev=ALTO; [ "$E_DB" = "1" ] && sev=CRITICO
  achado "$sev" RANSOMWARE 1-IMUT REPO_MONTADO_RW_PRODUCAO IMUTAVEL \
    "Repositorio de backup montado com escrita permanente neste servidor ($PAPEL)" \
    "${EXPOSTOS[*]}" \
    "Um ataque (ransomware) ou erro com privilegio neste servidor alcanca o banco e os backups ao mesmo tempo: perda total possivel" \
    "Desacoplar o repositorio do servidor de producao (montagem so durante a janela, credencial dedicada) e manter copia imutavel/air-gapped fora do alcance deste servidor"
fi
if [ ${#SOFTS[@]} -gt 0 ]; then
  achado ALTO INTEGRIDADE 0 NFS_SOFT SUSTENTACAO_DB "Destino de backup NFS montado como soft" "${SOFTS[*]}" \
    "Montagem soft pode devolver erro de I/O silencioso durante a escrita do backup e gerar pecas corrompidas" \
    "Montar como hard (opcoes recomendadas pela Oracle para RMAN em NFS)"
fi
if [ ${#SECSYS[@]} -gt 0 ]; then
  achado MEDIO SEGURANCA - NFS_SEC_SYS SEGMENTACAO "Destino de backup NFS sem autenticacao forte (sec=sys)" "${SECSYS[*]}" \
    "O servidor NFS confia no UID informado pelo cliente: qualquer host autorizado na rede pode se passar por outro usuario" \
    "Restringir o export a hosts especificos, isolar a rede de backup e avaliar Kerberos (sec=krb5p)"
fi
if [ ${#RSIZE[@]} -gt 0 ]; then
  achado MEDIO DESEMPENHO - NFS_WSIZE_BAIXO DESEMPENHO "Destino de backup NFS com wsize baixo" "${RSIZE[*]}" \
    "Blocos pequenos reduzem a vazao do backup e alongam a janela" "Usar rsize/wsize de 1 MB (1048576) quando suportado"
fi
if [ "$NFS_BKP" = "1" ] && [ -n "${ORA_SEM_DNFS:-}" ]; then
  achado MEDIO DESEMPENHO - ORA_SEM_DNFS DESEMPENHO "Backup Oracle em NFS sem Direct NFS (dNFS) ativo" "v\$dnfs_servers vazio em: ${ORA_SEM_DNFS}" \
    "O kernel NFS limita a vazao e influencia a janela de backup e o tempo de restauracao" "Avaliar habilitar dNFS e rede dedicada de backup"
fi
if [ ${#APPL[@]} -gt 0 ]; then
  achado INFO RANSOMWARE 1-IMUT APPLIANCE_CONFIRMAR_LOCK IMUTAVEL "Repositorio aparenta ser appliance de backup: confirmar bloqueio de retencao" \
    "${APPL[*]}" "Deduplicacao no appliance nao impede exclusao/criptografia se o bloqueio de retencao estiver desligado" \
    "Confirmar recurso de retencao bloqueada (ex.: ExaGrid Retention Time-Lock) e registrar a evidencia"
fi

#--- 5. Permissoes nos destinos de backup ---------------------------------------
declare -a DIR_O_W=() ; ARQ_O_R=0; ARQ_EX=""
declare -a VISTOS=()
for d in $(printf '%s\n' ${BKP_DIRS[@]+"${BKP_DIRS[@]}"} | head -12); do
  [ -d "$d" ] || continue
  # permissao do diretorio: todos os destinos, inclusive subpastas
  [ -n "$(TO 10 find "$d" -maxdepth 0 -perm -0002 2>/dev/null)" ] && DIR_O_W+=("$d")
  # contagem de arquivos: pula subpasta de destino ja varrido (evita contar duas vezes)
  dup=0; for v in ${VISTOS[@]+"${VISTOS[@]}"}; do dentro "$d" "$v" && { dup=1; break; }; done
  [ "$dup" = "1" ] && continue; VISTOS+=("$d")
  n=$(TO 60 find "$d" -maxdepth 4 -type f \( -iname '*.dmp' -o -iname '*.bkp' -o -iname '*.bak' -o -iname '*.bk' -o -iname '*.dump' -o -iname '*.gz' -o -iname '*.rman' \) -perm -0004 2>/dev/null | head -1000 | wc -l)
  [ "${n:-0}" -gt 0 ] && { ARQ_O_R=$((ARQ_O_R+n)); ARQ_EX="$ARQ_EX $d"; }
done
if [ ${#DIR_O_W[@]} -gt 0 ]; then
  achado ALTO SEGURANCA - PERM_DIR_ESCRITA_GERAL SEGMENTACAO "Diretorio de backup com escrita para qualquer usuario do sistema" "${DIR_O_W[*]}" \
    "Qualquer conta local (inclusive de aplicacao comprometida) pode apagar ou substituir backups" "Restringir permissao ao dono das rotinas (ex.: 750)"
fi
if [ "$ARQ_O_R" -gt 0 ]; then
  achado ALTO SEGURANCA - PERM_ARQ_LEITURA_GERAL CRIPTOGRAFIA "$ARQ_O_R arquivo(s) de backup/dump legiveis por qualquer usuario" "Diretorios:$ARQ_EX" \
    "Copia integral dos dados acessivel a qualquer conta do servidor (vazamento de dados pessoais e sensiveis, LGPD)" \
    "Remover leitura de outros (chmod o-r), ajustar umask das rotinas e criptografar dumps"
fi

#--- 6. Servidor NFS (quando este host e o servidor de backup) ------------------
if [ "$E_NFSSRV" = "1" ]; then
  declare -a EX_ABERTO=() EX_NRS=() EX_INSEC=() EX_SYS=() EX_RW=()
  while read -r path specs; do
    [ -z "$path" ] && continue
    for sp in $specs; do
      cli="${sp%%(*}"; op=""; case "$sp" in *"("*) op="${sp#*(}"; op="${op%)}";; esac
      [ -z "$cli" ] && cli="*"
      case "$cli" in '*'|'*.*'|0.0.0.0/0|0.0.0.0/0.0.0.0) EX_ABERTO+=("$path -> $cli");;
        */[0-9]*) m="${cli##*/}"; [ "${m%%.*}" = "$m" ] && [ "$m" -le 16 ] 2>/dev/null && EX_ABERTO+=("$path -> $cli");; esac
      case ",$op," in *,no_root_squash,*) EX_NRS+=("$path -> $cli");; esac
      case ",$op," in *,insecure,*) EX_INSEC+=("$path -> $cli");; esac
      case ",$op," in *,sec=krb5*) ;; *) EX_SYS+=("$path -> $cli");; esac
      case ",$op," in *,rw,*) EX_RW+=("$path -> $cli");; esac
    done
  done <<< "$EXP_TXT"
  evid "EXPORTS NFS" "$EXP_TXT"
  [ ${#EX_ABERTO[@]} -gt 0 ] && achado ALTO SEGURANCA - EXPORT_ABERTO SEGMENTACAO "Export NFS do repositorio aberto a qualquer host ou a rede ampla" "${EX_ABERTO[*]}" \
    "Qualquer maquina da rede alcanca o repositorio de backup" "Restringir cada export aos IPs dos servidores que fazem backup e isolar a rede de backup"
  [ ${#EX_NRS[@]} -gt 0 ] && achado ALTO RANSOMWARE 1-IMUT EXPORT_NO_ROOT_SQUASH IMUTAVEL "Export NFS com no_root_squash" "${EX_NRS[*]}" \
    "Root em qualquer cliente autorizado (ex.: servidor de producao comprometido) vira root no repositorio e pode apagar todos os backups" \
    "Usar root_squash e conta dedicada; manter copia imutavel fora do export"
  [ ${#EX_INSEC[@]} -gt 0 ] && achado MEDIO SEGURANCA - EXPORT_INSECURE SEGMENTACAO "Export NFS com opcao insecure" "${EX_INSEC[*]}" \
    "Aceita conexoes de portas nao privilegiadas (usuarios comuns do cliente)" "Remover insecure"
  [ ${#EX_SYS[@]} -gt 0 ] && achado MEDIO SEGURANCA - EXPORT_SEC_SYS SEGMENTACAO "Exports NFS sem autenticacao forte (sec=sys)" "${EX_SYS[*]}" \
    "Autorizacao baseada so em IP e UID informado pelo cliente" "Isolar a rede de backup e avaliar Kerberos (krb5p)"
fi

#--- 7. Imutabilidade, snapshots e deduplicacao no repositorio ------------------
declare -a REPO_DIRS=()
if [ "$E_REPO" = "1" ]; then
  while read -r p _; do [ -n "$p" ] && REPO_DIRS+=("$p"); done <<< "$EXP_TXT"
  for d in ${BKP_DIRS[@]+"${BKP_DIRS[@]}"}; do REPO_DIRS+=("$d"); done
fi
if [ ${#REPO_DIRS[@]} -gt 0 ]; then
  IMM=0
  for d in $(printf '%s\n' "${REPO_DIRS[@]}" | sort -u | head -8); do
    [ -d "$d" ] || continue
    c=$(TO 60 find "$d" -maxdepth 3 -type f 2>/dev/null | head -300 | TO 60 xargs -r $SUDO lsattr 2>/dev/null | awk '$1 ~ /i/' | wc -l)
    IMM=$((IMM + ${c:-0}))
  done
  VHR=0; pgrep -f veeamimmureposvc >/dev/null 2>&1 && VHR=1
  SNAP=0
  tem zfs && SNAP=$((SNAP + $(TO 20 zfs list -H -t snapshot 2>/dev/null | wc -l)))
  tem lvs && SNAP=$((SNAP + $(TO 20 $SUDO lvs --noheadings -o lv_attr 2>/dev/null | grep -c '^[[:space:]]*s')))
  DEDUP=""
  { tem lsblk && lsblk -no TYPE 2>/dev/null | grep -qx vdo; } && DEDUP="VDO"
  { tem zfs && TO 20 zfs get -H -o value dedup 2>/dev/null | grep -q '^on'; } && DEDUP="${DEDUP:+$DEDUP, }ZFS dedup"
  evid "IMUTABILIDADE / SNAPSHOTS / DEDUP" "Diretorios do repositorio: ${REPO_DIRS[*]}" "Arquivos com atributo imutavel (amostra): $IMM" \
    "Veeam Hardened Repository (veeamimmureposvc): $VHR" "Snapshots (ZFS/LVM): $SNAP" "Deduplicacao: ${DEDUP:-nao detectada}"
  if [ "$IMM" = "0" ] && [ "$VHR" = "0" ]; then
    if [ "$SNAP" = "0" ]; then
      achado CRITICO RANSOMWARE 1-IMUT REPO_SEM_IMUTABILIDADE IMUTAVEL "Repositorio de backup sem imutabilidade e sem snapshots" \
        "Nenhum arquivo imutavel na amostra, sem Veeam Hardened Repository, 0 snapshots${DEDUP:+, deduplicacao: $DEDUP}" \
        "Quem tiver escrita no repositorio (inclusive via export NFS a partir da producao) apaga ou criptografa todo o historico de backup" \
        "Implantar repositorio imutavel (retencao bloqueada/WORM) ou copia air-gapped, fora do alcance das credenciais de producao"
    else
      achado ALTO RANSOMWARE 1-IMUT REPO_SO_SNAPSHOT IMUTAVEL "Repositorio protegido apenas por snapshots (sem imutabilidade)" \
        "Snapshots: $SNAP; arquivos imutaveis: 0; Veeam Hardened: nao" "Snapshots podem ser apagados por quem tem root no repositorio" \
        "Adotar retencao bloqueada (WORM/time-lock) ou copia air-gapped"
    fi
    [ -n "$DEDUP" ] && achado INFO RANSOMWARE 1-IMUT REPO_SO_DEDUP IMUTAVEL "Repositorio com deduplicacao, que nao e protecao contra exclusao" \
      "Deduplicacao: $DEDUP" "Deduplicacao economiza espaco mas nao impede apagar ou criptografar os backups" \
      "Combinar a deduplicacao com retencao bloqueada/imutavel"
  fi
fi

#--- 8. Credenciais de off-site/nuvem neste servidor ----------------------------
declare -a CRED_ABERTA=() CRED_HOST=()
for f in "$HOME/.oci/config" "$HOME/.aws/credentials" "$HOME/.config/rclone/rclone.conf" "$HOME/.netrc" "$HOME/.s3cfg"; do
  [ -f "$f" ] || continue
  CRED_HOST+=("$f")
  [ -n "$(find "$f" -maxdepth 0 -perm /044 2>/dev/null)" ] && CRED_ABERTA+=("$f ($(stat -c %a "$f" 2>/dev/null))")
done
if [ -f "$HOME/.oci/config" ]; then
  for k in $(sed -n 's/^[[:space:]]*key_file[[:space:]]*=[[:space:]]*//p' "$HOME/.oci/config" 2>/dev/null | sed "s#^~#$HOME#" | sort -u); do
    [ -f "$k" ] && [ -n "$(find "$k" -maxdepth 0 -perm /044 2>/dev/null)" ] && CRED_ABERTA+=("$k ($(stat -c %a "$k" 2>/dev/null))")
  done
fi
evid "CREDENCIAIS DE NUVEM/OFF-SITE (somente caminho e permissao)" ${CRED_HOST[@]+"${CRED_HOST[@]}"} "Com leitura para grupo/outros: ${CRED_ABERTA[*]:-nenhum}"
[ ${#CRED_ABERTA[@]} -gt 0 ] && achado ALTO CREDENCIAIS - CRED_ARQ_PERM CREDENCIAIS "Credencial de nuvem/off-site legivel por outros usuarios" "${CRED_ABERTA[*]}" \
  "Quem ler a chave acessa (e pode apagar) a copia off-site" "Permissao 600 nas chaves e arquivos de configuracao; rotacionar se houve exposicao"
if [ ${#CRED_HOST[@]} -gt 0 ] && [ "$E_DB" = "1" ]; then
  achado MEDIO RANSOMWARE 1-OFF CRED_OFFSITE_NA_PRODUCAO IMUTAVEL "Credencial da copia off-site guardada no servidor de producao" "${CRED_HOST[*]}" \
    "Se a credencial puder excluir objetos, um invasor no servidor apaga tambem a copia off-site" \
    "Usar credencial so de escrita (sem delete) e retencao bloqueada no destino (retention rule/Object Lock)"
fi

#--- 9. Hardening e ciclo de vida do sistema ------------------------------------
REPO_SEV_UP(){ [ "$E_REPO" = "1" ] && echo "$2" || echo "$1"; }
OSID=""; OSVER=""; OSNOME=""
osr(){ sed -n "s/^$1=//p" /etc/os-release 2>/dev/null | head -1 | tr -d '"'; }
if [ -r /etc/os-release ]; then OSID=$(osr ID); OSVER=$(osr VERSION_ID); OSNOME=$(osr PRETTY_NAME)
elif [ -r /etc/redhat-release ]; then OSNOME=$(cat /etc/redhat-release); OSID="rhel"; OSVER=$(grep -oE '[0-9]+(\.[0-9]+)?' /etc/redhat-release | head -1); fi
MAJ="${OSVER%%.*}"; EOL=""; EOLSEV=ALTO
case "$OSID" in
  centos) case "$MAJ" in 5|6|7|8) EOL="CentOS $OSVER sem atualizacoes do projeto (CentOS 7 encerrou em 06/2024; CentOS 8 em 12/2021)";; esac;;
  rhel|ol|oracle) case "$MAJ" in 5|6) EOL="$OSNOME fora de suporte";; 7) EOL="$OSNOME fora do suporte padrao (somente suporte estendido pago)"; EOLSEV=MEDIO;; esac;;
  ubuntu) case "$OSVER" in 14.*|16.*|18.*|20.*) EOL="$OSNOME fora do suporte padrao (somente ESM)"; EOLSEV=MEDIO;; esac;;
  debian) case "$MAJ" in 7|8|9|10|11) EOL="$OSNOME fora do suporte";; esac;;
  sles) case "$MAJ" in 11|12) EOL="$OSNOME fora do suporte geral"; EOLSEV=MEDIO;; esac;;
esac
[ -n "$EOL" ] && achado "$EOLSEV" CICLO_VIDA - SO_EOL CICLO_VIDA "Sistema operacional fora de suporte" "$EOL" \
  "Sem correcoes de seguranca: vulnerabilidades conhecidas permanecem exploraveis" "Planejar migracao para versao suportada"
ULT=""
tem rpm && ULT=$(rpm -qa --qf '%{INSTALLTIME}\n' 2>/dev/null | sort -n | tail -1)
[ -z "$ULT" ] && [ -f /var/lib/dpkg/status ] && ULT=$(stat -c %Y /var/lib/dpkg/status 2>/dev/null)
if [ -n "$ULT" ]; then
  DIAS=$(( ( $(date +%s) - ULT ) / 86400 ))
  evid "ATUALIZACOES" "Ultimo pacote instalado/atualizado ha $DIAS dias"
  if [ "$DIAS" -gt 365 ]; then achado "$(REPO_SEV_UP ALTO ALTO)" HARDENING - SO_SEM_PATCH CICLO_VIDA "Sistema sem atualizacao ha $DIAS dias" "Ultima instalacao de pacote: $(date -d "@$ULT" '+%d/%m/%Y' 2>/dev/null)" \
      "Vulnerabilidades corrigidas pelo fabricante continuam abertas" "Estabelecer ciclo de patches com janela e rollback"
  elif [ "$DIAS" -gt 180 ]; then achado "$(REPO_SEV_UP MEDIO ALTO)" HARDENING - SO_SEM_PATCH CICLO_VIDA "Sistema sem atualizacao ha $DIAS dias" "Ultima instalacao de pacote: $(date -d "@$ULT" '+%d/%m/%Y' 2>/dev/null)" \
      "Vulnerabilidades corrigidas pelo fabricante continuam abertas" "Estabelecer ciclo de patches com janela e rollback"; fi
fi
FW=0
if tem systemctl; then for s in firewalld nftables iptables ufw; do systemctl is-active -q "$s" 2>/dev/null && FW=1; done; fi
[ "$FW" = "0" ] && [ "$(id -u)" = "0" ] && tem iptables && [ "$(iptables -S 2>/dev/null | grep -vc '^-P')" -gt 0 ] && FW=1
[ "$FW" = "0" ] && achado "$(REPO_SEV_UP MEDIO ALTO)" HARDENING - FW_INATIVO SEGMENTACAO "Firewall local inativo" "firewalld/nftables/iptables/ufw sem servico ativo" \
  "Servicos expostos a toda a rede, inclusive acesso ao repositorio de backup" "Ativar firewall local e segmentar a rede de backup"
SSHC=""
if [ "$(id -u)" = "0" ] && tem sshd; then SSHC=$(TO 10 sshd -T 2>/dev/null)
elif [ -n "$SUDO" ]; then SSHC=$(TO 10 $SUDO sshd -T 2>/dev/null)
elif [ -r /etc/ssh/sshd_config ]; then SSHC=$(grep -iE '^[[:space:]]*(permitrootlogin|passwordauthentication)' /etc/ssh/sshd_config | tr 'A-Z' 'a-z'); fi
if [ -n "$SSHC" ]; then
  echo "$SSHC" | grep -qiE '^[[:space:]]*permitrootlogin[[:space:]]+yes' && achado "$(REPO_SEV_UP MEDIO ALTO)" HARDENING - SSH_ROOT SEGMENTACAO "SSH permite login direto de root" "sshd: permitrootlogin yes" \
    "Senha de root vira alvo direto de forca bruta e nao ha rastreabilidade de quem acessou" "PermitRootLogin no (ou prohibit-password) e acesso nominal com sudo"
  echo "$SSHC" | grep -qiE '^[[:space:]]*passwordauthentication[[:space:]]+yes' && achado BAIXO HARDENING - SSH_SENHA SEGMENTACAO "SSH aceita autenticacao por senha" "sshd: passwordauthentication yes" \
    "Exposicao a forca bruta e reuso de senha" "Preferir chave/PAM com MFA"
else
  evid "SSH" "Configuracao do sshd nao legivel por este usuario (rodar com sudo para avaliar)"
fi
tem getenforce && [ "$(getenforce 2>/dev/null)" = "Disabled" ] && achado BAIXO HARDENING - SELINUX_OFF SEGMENTACAO "SELinux desabilitado" "getenforce: Disabled" \
  "Menos uma camada de contencao em caso de invasao" "Avaliar SELinux em enforcing (ou permissive monitorado)"
if tem systemctl; then
  systemctl is-active -q auditd 2>/dev/null || achado BAIXO HARDENING - AUDITD_OFF SEGMENTACAO "Auditoria do sistema (auditd) inativa" "systemctl is-active auditd: inativo" \
    "Sem trilha para investigar acesso e exclusao de backups" "Ativar auditd com regras para os diretorios de backup"
  NTP=0; for s in chronyd ntpd systemd-timesyncd; do systemctl is-active -q "$s" 2>/dev/null && NTP=1; done
  [ "$NTP" = "0" ] && achado BAIXO HARDENING - SEM_NTP MONITORAMENTO "Sincronismo de horario inativo" "chronyd/ntpd/timesyncd inativos" \
    "Horarios divergentes atrapalham PITR (UNTIL TIME) e correlacao de eventos" "Ativar chrony/NTP"
fi
pgrep -f 'falcon-sensor|cbagentd|cbdaemon|SentinelAgent|sentinelone|ds_agent|mdatp|wdavdaemon|clamd|xagt|cylance|sophos|kesl|esets|bdsec|taniumclient' >/dev/null 2>&1 || \
  achado "$(REPO_SEV_UP BAIXO MEDIO)" HARDENING - SEM_EDR SEGMENTACAO "Nenhum antivirus/EDR detectado em execucao" "Processos de EDR/antivirus conhecidos: nenhum" \
  "Menor chance de detectar e conter ransomware antes de atingir os backups" "Avaliar EDR nos servidores de banco e de backup"

#--- 10. Resumo -----------------------------------------------------------------
log "Seguranca e conformidade: $N achado(s) | CRITICO $NC | ALTO $NA | MEDIO $NM. Saida: $OUT"
[ "$E_DB" = "1" ] && [ "$NFS_BKP" = "1" ] && [ "$E_REPO" = "0" ] && \
  log "Recomendado: rodar o kit tambem no servidor de backup (destino NFS) para avaliar exports, imutabilidade e hardening dele"
exit 0
