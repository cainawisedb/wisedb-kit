#!/bin/bash
#===============================================================================
# 01_coleta_linux_geral.sh - WiseDB | Kit de Coleta para Politica de Backup
#
# OBJETIVO : Inventariar o servidor Linux e descobrir TODOS os agendamentos
#            e scripts relacionados a backup (cron, systemd timers, mounts,
#            diretorios de backup), sem alterar nada no ambiente.
# RISCO    : Zero. Somente leitura (cat, ls, grep, df, du, stat, find).
# EXECUCAO : Rodar como o usuario dono das rotinas (ex.: oracle, mssql) e,
#            se possivel, repetir como root para enxergar crons de sistema.
#              bash 01_coleta_linux_geral.sh [dir_backup_1] [dir_backup_2] ...
# SAIDA    : ./coleta_<hostname>_<data>/01_linux/
#
# Versao 1.2 (outubro/2026)
#   [CORRIGIDO] "df -hT" sem timeout travava a coleta inteira quando havia
#               montagem NFS/CIFS morta (destino de backup fora do ar). Agora
#               tem teto de 30s e o travamento vira aviso no arquivo.
#
# Versao 1.1 (setembro/2026)
#   [CORRIGIDO] "du -sh --max-depth=2" tem flags mutuamente exclusivas e falhava
#               sempre. Passa a usar "du -h --max-depth=2" com timeout, para nao
#               travar em NFS grande.
#   [CORRIGIDO] Captura de scripts agora e recursiva (3 niveis): wrappers que
#               chamam outros scripts, .rman e .sql tambem sao capturados. Antes
#               so o script citado diretamente no cron era coletado, e o script
#               que de fato executa o backup ficava de fora.
#   [NOVO]      scripts_nao_encontrados.txt lista caminhos referenciados que nao
#               existem no filesystem (rotina potencialmente quebrada).
#   [CORRIGIDO] Mascaramento cobre string de conexao "usuario/senha@servico"
#               (sqlplus, rman, expdp), que antes passava em texto claro.
#   [NOVO]      Registra .snapshot dos mounts (indicio de snapshot de FSS/NAS) e
#               avisa quando o cron de sistema esta inacessivel.
#   [CORRIGIDO] Arquivos de saida truncados no inicio; reexecutar no mesmo dia
#               nao concatena mais o conteudo anterior.
#
# Versao 1.4 (outubro/2026)
#   [CRITICO]   Com sudo, os scripts chamados pelo crontab de root/oracle/etc.
#               nao eram capturados: a lista vinha so do crontab do usuario
#               atual e de /etc. Agora entram todos os crontabs (inclusive os
#               de /var/spool/cron), e scripts sem permissao de leitura sao
#               lidos via sudo.
#   [NOVO]      Scripts disparados por systemd timers e /etc/anacrontab tambem
#               sao capturados.
#   [NOVO]      monitoramento_backup.txt: notificacao nos scripts (mail, webhook,
#               zabbix_sender), agente Zabbix, container de relatorio de backup,
#               remotes do rclone (nome e tipo, sem segredo) e discos cifrados
#               (LUKS), para os campos "Monitoramento" e "Criptografia" da politica.
#   [CRITICO]   Mascara igual a do orquestrador v3.8.
#
# Versao 1.3 (outubro/2026)
#   [CRITICO]   Mascara igual a do orquestrador v3.7 (valores entre aspas, SENHA,
#               KEY, --password, -P, Bearer, chave AWS).
#
# Versao 1.2 (setembro/2026)
#   [CORRIGIDO] Profundidade da listagem dos diretorios de backup era fixa em 2
#               niveis. Layouts comuns como /u02/Backup/<SID>/Bkp_Logico/<PDB>
#               ficavam fora do alcance e o coletor reportava "nenhum dump",
#               falso negativo. Agora o default e 4 niveis, ajustavel por
#               WISEDB_LIST_DEPTH.
#   [NOVO]      Se sudo -n estiver disponivel, o cron de sistema e relido com
#               privilegio, eliminando o ponto cego de job de backup sob root.
#               Controlado por WISEDB_SUDO=1 (o wizard exporta automaticamente).
#   [NOVO]      Registra /etc/oratab e a arvore de configuracao de SBT do DCS
#               (oss/, dbrs/, wallets/) apenas por nome de arquivo, para
#               identificar o destino real do RMAN sem expor wallet.
#===============================================================================
set -uo pipefail

HOSTN=$(hostname -s 2>/dev/null || hostname)
OUT="./coleta_${HOSTN}_$(date +%Y%m%d)/01_linux"
mkdir -p "$OUT"
INV="$OUT/inventario_geral.txt"
: > "$INV"

# Profundidade da listagem dos diretorios de backup (default 4 niveis).
LIST_DEPTH="${WISEDB_LIST_DEPTH:-4}"

# sudo nao interativo: usado apenas para releitura do cron de sistema.
SUDO=""
if [ "${WISEDB_SUDO:-0}" = "1" ] && command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
  SUDO="sudo -n"
fi

log(){ echo "[$(date +%H:%M:%S)] $*"; }
run(){ # run "titulo" comando...
  local titulo="$1"; shift
  {
    echo "################################################################"
    echo "## $titulo"
    echo "## Comando: $*"
    echo "## Coletado em: $(date '+%d/%m/%Y %H:%M:%S %Z') | Host: $HOSTN | Usuario: $(whoami)"
    echo "################################################################"
    "$@" 2>&1 || echo "[AVISO] comando retornou erro ou nao disponivel"
    echo
  } >> "$INV"
}

# Regras de mascaramento de segredos, em arquivo para evitar inferno de quoting.
SEDF="$OUT/.mascara.sed"
cat > "$SEDF" <<'SEDEOF'
s/(([A-Za-z0-9_.-]*(password|passwd|pwd|senha|secret|token|passphrase|pass_phrase|cipher[-_]?pass|credential|api_?key|access_?key|key_id|keyid|private_?key|key))["']?[[:space:]]*[=:][[:space:]]*)("[^"]*"|'[^']*'|[^[:space:]",;]+)/\1***REMOVIDO***/Ig
s/(--?(password|passwd|pwd|senha|token|secret)[[:space:]]+)("[^"]*"|'[^']*'|[^-[:space:]][^[:space:]]*)/\1***REMOVIDO***/Ig
s/(identified[[:space:]]+by[[:space:]]+)("[^"]*"|[^[:space:];]+)/\1***REMOVIDO***/Ig
s#(//[^/:@[:space:]]+:)[^@[:space:]]+(@)#\1***REMOVIDO***\2#g
s#([A-Za-z0-9_.$]+)/[^[:space:]/@"'*]{2,}@#\1/***REMOVIDO***@#g
s#([A-Za-z0-9_.$]+)/[^[:space:]/@"'*]{2,}([[:space:]]+as[[:space:]]+sys)#\1/***REMOVIDO***\2#Ig
s#((connect|conn)[[:space:]]+((target|auxiliary|catalog)[[:space:]]+)?["']?[A-Za-z0-9_.$]+)/[^[:space:]@"']+#\1/***REMOVIDO***#Ig
s#((^|[[:space:]])(target|auxiliary|catalog)([[:space:]]+|[[:space:]]*=[[:space:]]*)["']?[A-Za-z0-9_.$]+)/[^[:space:]@"']+#\1/***REMOVIDO***#Ig
s#((sqlplus|sqlldr|expdp|impdp|exp|imp|dgmgrl)([[:space:]]+-[A-Za-z]+)*[[:space:]]+["']?[A-Za-z0-9_.$]+)/[^[:space:]@"']+#\1/***REMOVIDO***#g
s/(sqlcmd[^|;]*[[:space:]]-P[[:space:]]*)("[^"]*"|'[^']*'|[^[:space:]-][^[:space:]]*)/\1***REMOVIDO***/g
s/([[:space:]]-P[[:space:]]+)("[^"]*"|'[^']*'|[^[:space:]-][^[:space:]]*)/\1***REMOVIDO***/g
s/((mysql|mysqldump|mysqladmin|mysqlpump|mysqlcheck|mysqlbinlog|mariadb|mariadb-dump|mariadb-admin|mariabackup|xtrabackup|innobackupex|mydumper|myloader)[^|;]*[[:space:]]-p)("[^"]*"|'[^']*'|[^[:space:]"'-][^[:space:]]*)/\1***REMOVIDO***/g
s/(Bearer[[:space:]]+)[A-Za-z0-9._~+\/=-]{8,}/\1***REMOVIDO***/Ig
s/(AKIA|ASIA)[0-9A-Z]{16}/\1***REMOVIDO***/g
SEDEOF

log "Iniciando coleta geral em $HOSTN (saida em $OUT)"

# --- Identificacao do servidor ------------------------------------------------
run "Sistema operacional"        cat /etc/os-release
run "Kernel / arquitetura"       uname -a
run "Hostname / IPs"             hostname -I
run "Uptime"                     uptime
run "Data/hora e timezone"       timedatectl

# --- Armazenamento e pontos de montagem (destinos de backup) ------------------
if command -v timeout >/dev/null 2>&1; then
  run "Filesystems e uso de disco" sh -c "timeout -k 5 30 df -hT || { echo '[AVISO] df interrompido (timeout de 30s): possivel montagem NFS/CIFS sem resposta. Somente filesystems locais abaixo:'; timeout -k 5 30 df -hTl; }"
else
  run "Filesystems e uso de disco" df -hT
fi
run "Pontos de montagem NFS/CIFS" sh -c "mount | grep -Ei 'nfs|cifs|smb' || echo 'Nenhum mount NFS/CIFS ativo'"
run "fstab (mounts persistentes)" cat /etc/fstab

# --- Agendamentos: cron do usuario atual e do sistema --------------------------
run "Crontab do usuario $(whoami)" crontab -l
run "Crontab de sistema (/etc/crontab)" cat /etc/crontab
run "Jobs em /etc/cron.d"        sh -c "ls -lah /etc/cron.d/ && grep -rH '' /etc/cron.d/ 2>/dev/null"
run "Listagem cron.daily/weekly/monthly" sh -c "ls -lah /etc/cron.daily/ /etc/cron.weekly/ /etc/cron.monthly/ /etc/cron.hourly/ 2>/dev/null"
run "Systemd timers (todos)"     systemctl list-timers --all --no-pager

# Usuarios com crontab em /var/spool (RHEL: /var/spool/cron, Debian:
# /var/spool/cron/crontabs). A lista fixa deixava de fora usuarios como
# orabkp, wisedb ou relatorio.
USERS_CRON="oracle mssql root postgres mysql veeam backup grid opc relatorio wisedb"
for sp in /var/spool/cron /var/spool/cron/crontabs; do
  for u in $( { ls -1 "$sp" 2>/dev/null || { [ -n "$SUDO" ] && $SUDO ls -1 "$sp" 2>/dev/null; }; } | grep -vE '^(crontabs|lastrun|\.)' ); do
    USERS_CRON="$USERS_CRON $u"
  done
done
USERS_CRON=$(printf '%s\n' $USERS_CRON | awk '!v[$0]++' | tr '\n' ' ')

# Crontabs de outros usuarios relevantes (requer root; falha silenciosa se nao for)
for u in oracle mssql root postgres mysql veeam backup; do
  run "Crontab do usuario $u (se root)" sh -c "crontab -l -u $u 2>/dev/null || echo 'Sem acesso ou usuario inexistente'"
done

# Releitura privilegiada do cron de sistema quando sudo -n esta disponivel.
# Sem isso o ponto cego permanece: job de backup sob root nao aparece na coleta.
if [ -n "$SUDO" ]; then
  run "Crontab de sistema (/etc/crontab) via sudo" sh -c "$SUDO cat /etc/crontab"
  run "Jobs em /etc/cron.d via sudo" sh -c "$SUDO ls -lah /etc/cron.d/ && $SUDO grep -rH '' /etc/cron.d/ 2>/dev/null"
  run "Listagem cron.hourly/daily/weekly/monthly via sudo" \
    sh -c "$SUDO ls -lah /etc/cron.hourly/ /etc/cron.daily/ /etc/cron.weekly/ /etc/cron.monthly/ 2>/dev/null"
  for u in $USERS_CRON; do
    run "Crontab do usuario $u via sudo" \
      sh -c "$SUDO crontab -l -u $u 2>/dev/null || echo 'Sem crontab para $u'"
  done
  log "Cron de sistema relido com sudo"
fi

# Aviso explicito quando o cron de sistema nao pode ser lido por este usuario
if [ -z "$SUDO" ] && grep -qE '/etc/cron[^\n]*(Permission denied)|cannot open directory .?/etc/cron' "$INV" 2>/dev/null; then
  {
    echo "################################################################"
    echo "## [ATENCAO] Cron de sistema inacessivel para o usuario $(whoami)"
    echo "## /etc/crontab e/ou /etc/cron.d nao puderam ser lidos. Pode existir"
    echo "## job de backup sob root invisivel nesta coleta. Reexecutar com:"
    echo "##   WISEDB_SUDO=1 bash 01_coleta_linux_geral.sh"
    echo "## ou responder S na pergunta de sudo do wizard."
    echo "################################################################"
    echo
  } >> "$INV"
  log "[ATENCAO] cron de sistema inacessivel; reexecute com WISEDB_SUDO=1"
fi

# --- Indicios do destino real do backup do banco (SBT / DCS) -------------------
# Somente nomes de arquivo e diretorio. Nenhum conteudo de wallet e lido.
run "Oratab (instancias registradas)" sh -c "cat /etc/oratab 2>/dev/null || echo 'Sem /etc/oratab'"
run "Configuracao de SBT do DCS (Object Storage, Recovery Service e wallets)" sh -c "
  for p in /opt/oracle/dcs/commonstore/oss /opt/oracle/dcs/commonstore/dbrs /opt/oracle/dcs/commonstore/wallets; do
    if [ -d \"\$p\" ]; then
      echo \"-- \$p\"
      find \"\$p\" -maxdepth 3 \\( -type f -o -type d \\) -printf '%y %TY-%Tm-%Td %10s  %p\n' 2>/dev/null | sort
    fi
  done
  [ -d /opt/oracle/dcs/commonstore ] || echo 'Host sem /opt/oracle/dcs/commonstore (nao e DB System/ODA)'"

# --- Descoberta e copia (mascarada) dos scripts de backup ---------------------
# Extrai caminhos de scripts citados nos crontabs, copia o conteudo com
# mascaramento de segredos e repete o processo para os scripts chamados dentro
# deles (wrappers), ate 3 niveis de profundidade.
# Destino de saida (> arquivo.sql, -f dump.sql, --result-file=) nao e script:
# sem este filtro o dump gerado virava "script referenciado e nao encontrado".
sem_saida(){ sed -E 's#(>>?|[[:space:]]-f|--file=|--result-file=|--output=|-o)[[:space:]]*/[^[:space:];|&]+##g'; }
# Le arquivo com fallback para sudo (scripts de root costumam ser 700).
rd(){ if [ -r "$1" ]; then cat "$1" 2>/dev/null; elif [ -n "$SUDO" ]; then $SUDO cat "$1" 2>/dev/null; fi; }
existe(){ [ -f "$1" ] || { [ -n "$SUDO" ] && $SUDO test -f "$1" 2>/dev/null; }; }

run "Anacrontab" sh -c "cat /etc/anacrontab 2>/dev/null || echo 'Sem /etc/anacrontab'"

# systemd timers: o servico disparado pode ser a rotina de backup.
TIMERS_TXT="$OUT/.timers.txt"; : > "$TIMERS_TXT"
for tm in $(systemctl list-timers --all --no-legend --no-pager 2>/dev/null | grep -oE '[A-Za-z0-9@_.-]+\.timer' | sort -u); do
  svc=$(systemctl show -p Unit --value "$tm" 2>/dev/null); svc="${svc:-${tm%.timer}.service}"
  conteudo=$(systemctl cat "$tm" "$svc" 2>/dev/null)
  if printf '%s\n%s\n' "$tm" "$conteudo" | grep -qiE 'backup|bkp|rman|dump|rsync|rclone|pgbackrest|barman|xtrabackup|mariabackup|snapshot|restic|borg'; then
    { echo "## timer $tm -> $svc"; printf '%s\n' "$conteudo"; echo; } >> "$TIMERS_TXT"
  fi
done
if [ -s "$TIMERS_TXT" ]; then
  run "Systemd timers relacionados a backup (unidades completas)" cat "$TIMERS_TXT"
fi

SCRIPTS_DIR="$OUT/scripts_de_backup"
mkdir -p "$SCRIPTS_DIR"
LISTA="$OUT/lista_scripts_agendados.txt"
FALTA="$OUT/scripts_nao_encontrados.txt"
PEND="$OUT/.pendentes.txt"
VISTOS="$OUT/.vistos.txt"
NOVOS="$OUT/.novos.txt"
: > "$FALTA"; : > "$VISTOS"

{
  crontab -l 2>/dev/null
  rd /etc/crontab
  for f in /etc/cron.d/*; do [ -e "$f" ] && rd "$f"; done
  rd /etc/anacrontab
  for u in $USERS_CRON; do
    [ "$u" = "$(whoami)" ] && continue
    if [ "$(id -u)" = "0" ]; then crontab -l -u "$u" 2>/dev/null
    elif [ -n "$SUDO" ]; then $SUDO crontab -l -u "$u" 2>/dev/null; fi
  done
  cat "$TIMERS_TXT" 2>/dev/null
} 2>/dev/null | sem_saida | grep -Eo '(/[A-Za-z0-9._/-]+\.(sh|bash|ksh|py|pl|rman|sql))' | sort -u > "$LISTA"
# /etc/cron.daily|weekly|...: o proprio arquivo e o script (sem extensao, em
# geral). Entra na captura somente se tiver conteudo de backup.
for d in /etc/cron.daily /etc/cron.hourly /etc/cron.weekly /etc/cron.monthly; do
  for f in "$d"/*; do
    [ -f "$f" ] || continue
    # utilitarios do proprio SO que citam "backup" (dpkg, logrotate...) nao sao rotina do cliente
    case "$(basename "$f")" in dpkg|logrotate|man-db|apt-compat|mlocate|plocate|sysstat|0anacron|bsdmainutils|passwd|apport|popularity-contest|rpm|tmpwatch|raid-check|0yum*|dnf-*|google-chrome*|exim4-base|locate|updatedb) continue;; esac
    rd "$f" | grep -qiE 'backup|bkp|rman|expdp|dump|rsync|rclone|pgbackrest|barman|xtrabackup|mariabackup' && echo "$f"
  done
done >> "$LISTA"
sort -u -o "$LISTA" "$LISTA"
cp "$LISTA" "$PEND"

NIVEL=0
while [ -s "$PEND" ] && [ "$NIVEL" -lt 3 ]; do
  NIVEL=$((NIVEL+1))
  : > "$NOVOS"
  while IFS= read -r scr; do
    [ -n "$scr" ] || continue
    grep -qxF "$scr" "$VISTOS" 2>/dev/null && continue
    echo "$scr" >> "$VISTOS"
    if ! existe "$scr"; then
      echo "$scr  (referenciado, nao existe ou sem permissao de leitura)" >> "$FALTA"
      continue
    fi
    base=$(echo "$scr" | tr '/' '_')
    {
      echo "## Origem: $scr"
      echo "## stat: $( { stat -c '%A %U %G %y' "$scr" 2>/dev/null || { [ -n "$SUDO" ] && $SUDO stat -c '%A %U %G %y' "$scr" 2>/dev/null; }; } )"
      echo "## nivel de referencia: $NIVEL"
      echo "## (conteudo com segredos mascarados)"
      rd "$scr" | sed -E -f "$SEDF" 2>/dev/null
      echo
    } > "$SCRIPTS_DIR/${base}.txt" 2>/dev/null
    # scripts, .rman e .sql chamados dentro deste script
    rd "$scr" | grep -v '^[[:space:]]*#' | sem_saida | grep -Eo '(/[A-Za-z0-9._/-]+\.(sh|bash|ksh|py|pl|rman|sql))' 2>/dev/null >> "$NOVOS"
  done < "$PEND"
  sort -u "$NOVOS" > "$PEND"
done
rm -f "$NOVOS" "$PEND" "$TIMERS_TXT"
# Lista final consolidada (agendados + chamados por wrappers)
sort -u "$VISTOS" > "$LISTA"
rm -f "$VISTOS"
[ -s "$FALTA" ] || rm -f "$FALTA"

# --- Diretorios de backup: listagem com datas e tamanhos -----------------------
# Usa os diretorios passados como argumento; se nenhum for passado, tenta os mais comuns.
DIRS=("$@")
if [ ${#DIRS[@]} -eq 0 ]; then
  DIRS=(/backup /Backup /u01/Dumps /u01/expdp /u02 /u02/Backup /u02/Backup_Fisico /u02/Backup_Logico \
        /u03/app/oracle/backup /bkp_externo /bkp_remoto01 /bkp_remoto02 /var/backup /var/backups)
fi
for d in "${DIRS[@]}"; do
  [ -d "$d" ] || continue
  run "Listagem recursiva ($LIST_DEPTH niveis) de $d" sh -c "timeout 240 find '$d' -maxdepth $LIST_DEPTH -printf '%TY-%Tm-%Td %TH:%TM %10s  %p\n' 2>/dev/null | sort | tail -400"
  # Recorte dedicado aos artefatos de backup: com muitos arquivos, o tail -400 da
  # listagem geral pode empurrar os dumps para fora da amostra.
  run "Artefatos de backup em $d (dump, backupset, tar.gz)" sh -c "timeout 240 find '$d' -maxdepth $LIST_DEPTH -type f \\( -name '*.dmp' -o -name '*.dmp.gz' -o -name '*.dmp.tar.gz' -o -name '*.bkp' -o -name '*.bak' -o -name '*.trn' -o -name '*.tar.gz' \\) -printf '%TY-%Tm-%Td %TH:%TM %10s  %p\n' 2>/dev/null | sort | tail -80 || echo 'Nenhum artefato de backup encontrado'"
  run "Uso de espaco por subpasta de $d" sh -c "timeout 180 du -h --max-depth=2 '$d' 2>/dev/null | sort -k2 | tail -40 || echo '[AVISO] du interrompido por timeout ou sem permissao'"
  run "Snapshots visiveis em $d (indicio de snapshot de FSS/NAS)" sh -c "if [ -d '$d/.snapshot' ]; then ls -1 '$d/.snapshot' | head -20; else echo 'Sem diretorio .snapshot visivel'; fi"
done

# --- Processos/servicos de backup em execucao ----------------------------------
run "Processos relacionados a backup" sh -c "ps -eo user,pid,lstart,cmd | grep -Ei 'rman|expdp|veeam|rsync|bacula|netbackup|commvault|restic|borg' | grep -v grep || echo 'Nenhum processo de backup em execucao agora'"

# --- Monitoramento, notificacao, off-site e criptografia -------------------------
# Campos "Monitoramento e alertas" e "Criptografia" da politica. Somente nomes,
# tipos e destinos; nenhum segredo e lido (rclone listremotes nao mostra chave).
MON="$OUT/monitoramento_backup.txt"
{
  echo "################ MONITORAMENTO, NOTIFICACAO, OFF-SITE E CRIPTOGRAFIA ################"
  echo "## Coletado em: $(date '+%d/%m/%Y %H:%M:%S %Z') | Host: $HOSTN | Usuario: $(whoami)"
  echo
  echo "### NOTIFICACAO DENTRO DOS SCRIPTS DE BACKUP CAPTURADOS"
  n=0
  for f in "$SCRIPTS_DIR"/*.txt; do
    [ -f "$f" ] || continue
    h=$(grep -nE '(^|[^A-Za-z_])(mailx?|sendmail|mutt|msmtp|zabbix_sender|logger)([[:space:]]|$)|curl[^|;]*(hook|webhook|telegram|teams|slack|chat|api/)|wget[^|;]*(hook|telegram)' "$f" | grep -v '^[0-9]*:[[:space:]]*#' | head -5)
    [ -n "$h" ] && { echo "-- $(basename "$f")"; echo "$h"; n=$((n+1)); }
  done
  [ "$n" = "0" ] && echo "(nenhum comando de notificacao nos scripts capturados)"
  echo
  echo "### AGENTE DE MONITORAMENTO"
  ps -eo user,args 2>/dev/null | grep -E 'zabbix_agent|zabbix_agentd|zabbix_agent2|site24x7|datadog-agent|node_exporter|telegraf|oracle-cloud-agent' | grep -v grep | head -8
  for c in /etc/zabbix/zabbix_agentd.conf /etc/zabbix/zabbix_agent2.conf /etc/zabbix_agentd.conf; do
    [ -f "$c" ] && { echo "-- $c (Server/ServerActive/Hostname)"; grep -E '^(Server|ServerActive|Hostname)=' "$c" 2>/dev/null; }
  done
  echo
  echo "### CONTAINERS DE RELATORIO/MONITORAMENTO DE BACKUP"
  for c in docker podman; do
    command -v "$c" >/dev/null 2>&1 || continue
    { $c ps -a --format '{{.Names}} | {{.Image}} | {{.Status}}' 2>/dev/null || { [ -n "$SUDO" ] && $SUDO $c ps -a --format '{{.Names}} | {{.Image}} | {{.Status}}' 2>/dev/null; }; } |
      grep -iE 'backup|report|relatorio|monitor|zabbix' | head -10
  done
  echo
  echo "### OFF-SITE: REMOTES DO RCLONE (nome e tipo, sem credencial)"
  if command -v rclone >/dev/null 2>&1; then
    rclone version 2>/dev/null | head -1
    echo "-- usuario $(whoami):"; rclone listremotes --long 2>/dev/null || echo "(sem rclone.conf para este usuario)"
    if [ -n "$SUDO" ]; then echo "-- root (via sudo):"; $SUDO rclone listremotes --long 2>/dev/null || echo "(sem rclone.conf para root)"; fi
  else
    echo "rclone nao instalado"
  fi
  for t in aws azcopy gsutil rsync restic borg; do command -v "$t" >/dev/null 2>&1 && echo "ferramenta de copia presente: $t ($(command -v "$t"))"; done
  echo
  echo "### CRIPTOGRAFIA EM REPOUSO (volumes LUKS / dm-crypt)"
  lsblk -o NAME,TYPE,FSTYPE,SIZE,MOUNTPOINT 2>/dev/null | grep -iE 'crypt|luks' || echo "(nenhum volume LUKS/dm-crypt visivel no lsblk)"
} 2>&1 | sed -E -f "$SEDF" > "$MON"

rm -f "$SEDF"
log "Coleta geral concluida. Revise $OUT antes de enviar."
