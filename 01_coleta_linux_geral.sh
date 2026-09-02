#!/bin/bash
#===============================================================================
# 01_coleta_linux_geral.sh - WiseDB | Kit de Coleta para Politica de Backup
#
# OBJETIVO : Inventariar o servidor Linux e descobrir TODOS os agendamentos
#            e scripts relacionados a backup (cron, systemd timers, mounts,
#            diretorios de backup), sem alterar nada no ambiente.
# RISCO    : Zero. Somente leitura (cat, ls, grep, df, stat).
# EXECUCAO : Rodar como o usuario dono das rotinas (ex.: oracle, mssql) e,
#            se possivel, repetir como root para enxergar crons de sistema.
#              bash 01_coleta_linux_geral.sh [dir_backup_1] [dir_backup_2] ...
# SAIDA    : ./coleta_<hostname>_<data>/01_linux/
#===============================================================================
set -uo pipefail

HOSTN=$(hostname -s 2>/dev/null || hostname)
DATA=$(date +%Y%m%d_%H%M%S)
OUT="./coleta_${HOSTN}_$(date +%Y%m%d)/01_linux"
mkdir -p "$OUT"

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
  } >> "$OUT/inventario_geral.txt"
}

log "Iniciando coleta geral em $HOSTN (saida em $OUT)"

# --- Identificacao do servidor ------------------------------------------------
run "Sistema operacional"        cat /etc/os-release
run "Kernel / arquitetura"       uname -a
run "Hostname / IPs"             hostname -I
run "Uptime"                     uptime
run "Data/hora e timezone"       timedatectl

# --- Armazenamento e pontos de montagem (destinos de backup) ------------------
run "Filesystems e uso de disco" df -hT
run "Pontos de montagem NFS/CIFS" sh -c "mount | grep -Ei 'nfs|cifs|smb' || echo 'Nenhum mount NFS/CIFS ativo'"
run "fstab (mounts persistentes)" cat /etc/fstab

# --- Agendamentos: cron do usuario atual e do sistema --------------------------
run "Crontab do usuario $(whoami)" crontab -l
run "Crontab de sistema (/etc/crontab)" cat /etc/crontab
run "Jobs em /etc/cron.d"        sh -c "ls -lah /etc/cron.d/ && grep -rH '' /etc/cron.d/ 2>/dev/null"
run "Listagem cron.daily/weekly/monthly" sh -c "ls -lah /etc/cron.daily/ /etc/cron.weekly/ /etc/cron.monthly/ /etc/cron.hourly/ 2>/dev/null"
run "Systemd timers (todos)"     systemctl list-timers --all --no-pager

# Crontabs de outros usuarios relevantes (requer root; falha silenciosa se nao for)
for u in oracle mssql root postgres mysql veeam backup; do
  run "Crontab do usuario $u (se root)" sh -c "crontab -l -u $u 2>/dev/null || echo 'Sem acesso ou usuario inexistente'"
done

# --- Descoberta e copia (mascarada) dos scripts de backup ---------------------
# Extrai caminhos de scripts citados nos crontabs e copia o conteudo com
# mascaramento de possiveis segredos (password/pwd/secret/token/identified by).
SCRIPTS_DIR="$OUT/scripts_de_backup"
mkdir -p "$SCRIPTS_DIR"
{
  crontab -l 2>/dev/null
  cat /etc/crontab 2>/dev/null
  grep -rh '' /etc/cron.d/ 2>/dev/null
} | grep -Eo '(/[A-Za-z0-9._/-]+\.(sh|bash|py|pl|rman|sql))' | sort -u > "$OUT/lista_scripts_agendados.txt"

while IFS= read -r scr; do
  [ -f "$scr" ] || continue
  base=$(echo "$scr" | tr '/' '_')
  {
    echo "## Origem: $scr"
    echo "## stat: $(stat -c '%A %U %G %y' "$scr" 2>/dev/null)"
    echo "## (conteudo com segredos mascarados)"
    sed -E 's/((password|passwd|pwd|secret|token|apikey)[[:space:]]*[=:][[:space:]]*)[^[:space:]"'\'']+/\1***REMOVIDO***/Ig; s/(identified[[:space:]]+by[[:space:]]+)[^[:space:];]+/\1***REMOVIDO***/Ig; s#(//[^/:@[:space:]]+:)[^@[:space:]]+(@)#\1***REMOVIDO***\2#g' "$scr"
    echo
  } >> "$SCRIPTS_DIR/${base}.txt" 2>/dev/null
done < "$OUT/lista_scripts_agendados.txt"

# --- Diretorios de backup: listagem com datas e tamanhos -----------------------
# Usa os diretorios passados como argumento; se nenhum for passado, tenta os mais comuns.
DIRS=("$@")
if [ ${#DIRS[@]} -eq 0 ]; then
  DIRS=(/backup /u02/Backup_Fisico /u02/Backup_Logico /u03/app/oracle/backup /bkp_externo /bkp_remoto01 /bkp_remoto02 /var/backup)
fi
for d in "${DIRS[@]}"; do
  [ -d "$d" ] || continue
  run "Listagem recursiva (2 niveis) de $d" sh -c "find '$d' -maxdepth 2 -printf '%TY-%Tm-%Td %TH:%TM %10s  %p\n' 2>/dev/null | sort | tail -400"
  run "Uso de espaco por subpasta de $d" du -sh --max-depth=2 "$d"
done

# --- Processos/servicos de backup em execucao ----------------------------------
run "Processos relacionados a backup" sh -c "ps -eo user,pid,lstart,cmd | grep -Ei 'rman|expdp|veeam|rsync|bacula|netbackup|commvault|restic|borg' | grep -v grep || echo 'Nenhum processo de backup em execucao agora'"

log "Coleta geral concluida. Revise $OUT antes de enviar."
