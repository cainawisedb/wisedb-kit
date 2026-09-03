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
#===============================================================================
set -uo pipefail

HOSTN=$(hostname -s 2>/dev/null || hostname)
OUT="./coleta_${HOSTN}_$(date +%Y%m%d)/01_linux"
mkdir -p "$OUT"
INV="$OUT/inventario_geral.txt"
: > "$INV"

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
s/((password|passwd|pwd|secret|token|apikey|api_key|client_secret)[[:space:]]*[=:][[:space:]]*)[^[:space:]",]+/\1***REMOVIDO***/Ig
s/(identified[[:space:]]+by[[:space:]]+)[^[:space:];]+/\1***REMOVIDO***/Ig
s#(//[^/:@[:space:]]+:)[^@[:space:]]+(@)#\1***REMOVIDO***\2#g
s#([A-Za-z0-9_.$]+)/[^[:space:]/@"']{3,}@#\1/***REMOVIDO***@#g
SEDEOF

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

# Aviso explicito quando o cron de sistema nao pode ser lido por este usuario
if grep -qE '/etc/cron[^\n]*(Permission denied)|cannot open directory .?/etc/cron' "$INV" 2>/dev/null; then
  {
    echo "################################################################"
    echo "## [ATENCAO] Cron de sistema inacessivel para o usuario $(whoami)"
    echo "## /etc/crontab e/ou /etc/cron.d nao pudaram ser lidos. Pode existir"
    echo "## job de backup sob root invisivel nesta coleta. Reexecutar com sudo."
    echo "################################################################"
    echo
  } >> "$INV"
  log "[ATENCAO] cron de sistema inacessivel; reexecute com sudo para cobertura total"
fi

# --- Descoberta e copia (mascarada) dos scripts de backup ---------------------
# Extrai caminhos de scripts citados nos crontabs, copia o conteudo com
# mascaramento de segredos e repete o processo para os scripts chamados dentro
# deles (wrappers), ate 3 niveis de profundidade.
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
  cat /etc/crontab 2>/dev/null
  grep -rh '' /etc/cron.d/ 2>/dev/null
  ls -1 /etc/cron.daily/ /etc/cron.hourly/ /etc/cron.weekly/ /etc/cron.monthly/ 2>/dev/null
} | grep -Eo '(/[A-Za-z0-9._/-]+\.(sh|bash|ksh|py|pl|rman|sql))' | sort -u > "$LISTA"
cp "$LISTA" "$PEND"

NIVEL=0
while [ -s "$PEND" ] && [ "$NIVEL" -lt 3 ]; do
  NIVEL=$((NIVEL+1))
  : > "$NOVOS"
  while IFS= read -r scr; do
    [ -n "$scr" ] || continue
    grep -qxF "$scr" "$VISTOS" 2>/dev/null && continue
    echo "$scr" >> "$VISTOS"
    if [ ! -f "$scr" ]; then
      echo "$scr  (referenciado, nao existe ou sem permissao de leitura)" >> "$FALTA"
      continue
    fi
    base=$(echo "$scr" | tr '/' '_')
    {
      echo "## Origem: $scr"
      echo "## stat: $(stat -c '%A %U %G %y' "$scr" 2>/dev/null)"
      echo "## nivel de referencia: $NIVEL"
      echo "## (conteudo com segredos mascarados)"
      sed -E -f "$SEDF" "$scr" 2>/dev/null
      echo
    } > "$SCRIPTS_DIR/${base}.txt" 2>/dev/null
    # scripts, .rman e .sql chamados dentro deste script
    grep -Eo '(/[A-Za-z0-9._/-]+\.(sh|bash|ksh|py|pl|rman|sql))' "$scr" 2>/dev/null >> "$NOVOS"
  done < "$PEND"
  sort -u "$NOVOS" > "$PEND"
done
rm -f "$NOVOS" "$PEND"
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
  run "Listagem recursiva (2 niveis) de $d" sh -c "find '$d' -maxdepth 2 -printf '%TY-%Tm-%Td %TH:%TM %10s  %p\n' 2>/dev/null | sort | tail -400"
  run "Uso de espaco por subpasta de $d" sh -c "timeout 180 du -h --max-depth=2 '$d' 2>/dev/null | sort -k2 | tail -40 || echo '[AVISO] du interrompido por timeout ou sem permissao'"
  run "Snapshots visiveis em $d (indicio de snapshot de FSS/NAS)" sh -c "if [ -d '$d/.snapshot' ]; then ls -1 '$d/.snapshot' | head -20; else echo 'Sem diretorio .snapshot visivel'; fi"
done

# --- Processos/servicos de backup em execucao ----------------------------------
run "Processos relacionados a backup" sh -c "ps -eo user,pid,lstart,cmd | grep -Ei 'rman|expdp|veeam|rsync|bacula|netbackup|commvault|restic|borg' | grep -v grep || echo 'Nenhum processo de backup em execucao agora'"

rm -f "$SEDF"
log "Coleta geral concluida. Revise $OUT antes de enviar."
