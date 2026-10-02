#!/bin/bash
#===============================================================================
# 09_coleta_evidencias_restore.sh - WiseDB | Evidencias de teste de restauracao
#
# OBJETIVO : Descobrir automaticamente as rotinas de CLONAGEM/RESTAURACAO que de
#            fato existem no ambiente e transformar cada execucao em um registro
#            no formato do ANEXO I da Politica de Backup. Tambem mede o RPO e o
#            RTO observados no ambiente (sem valor default: o acordado fica
#            "A DEFINIR" e o observado vai para Observacoes).
#
#            Fontes da descoberta (todas somente leitura):
#              1. Cron de todos os usuarios acessiveis: cada script agendado e
#                 lido e, se contiver DUPLICATE/RESTORE/impdp, vira rotina de
#                 clone; scripts chamados por ele (1 nivel) e destinos de log
#                 citados entram na varredura.
#              2. Varredura por nome (Clone*, clonagem, duplicate, refresh).
#              3. Varredura por CONTEUDO em /wisedb, /home, /u0*, /backup*,
#                 /scripts, /dba, /opt e pontos de montagem de dados.
#              4. Controlfile de cada banco local: v$rman_status (sessoes de
#                 RESTORE/DUPLICATE) e v$rman_output (saida da sessao).
#            Classificacao de cada execucao:
#              BACKUP_RMAN      DUPLICATE/RESTORE a partir de backup (teste valido)
#              ACTIVE_DATABASE  DUPLICATE FROM ACTIVE DATABASE / FROM SERVICE:
#                               nao usa backup, NAO comprova restauracao
#              DATAPUMP         impdp a partir de dump (backup logico)
#              SQLSERVER        RESTORE DATABASE a partir de .bak
#              RESTORE_VALIDATE RESTORE ... VALIDATE: comprova leitura dos
#                               backups, mas nao e teste de restauracao
#              INDETERMINADO    sem marcador conclusivo
# RISCO    : Zero. find, grep, stat, crontab -l e SELECT em v$ (sem DML).
# EXECUCAO : bash 09_coleta_evidencias_restore.sh [dir_extra ...]
#              WISEDB_CLONE_DIRS="/a:/b"   diretorios extras (":")
#              WISEDB_ORA_SIDS="SID1 SID2" instancias a consultar (padrao: ativas)
#              WISEDB_CLONE_DAYS=365       janela de busca em dias
#              WISEDB_CLONE_MAX=40         maximo de logs de clone analisados
#              WISEDB_CLONE_DEPTH=7        profundidade da varredura por conteudo
#              WISEDB_SUDO=1               usa sudo -n para ler arquivos de outro dono
# SAIDA    : ./coleta_<hostname>_<data>/09_restore/
#              anexo_I_evidencias.txt   resumo + RPO/RTO observados + registros
#              execucoes_clone.tsv      uma linha por execucao
#              rpo_rto_observado.txt    calculo do RPO/RTO observado por banco
#              bancos_locais.txt        inventario v$database das instancias
#              rotinas_descobertas.txt  scripts de clone e de onde vieram
#              alertas.txt | varredura.txt | cron_clone.txt | descartados.txt
#              scripts_clone/ | extratos/
#
# Versao 1.2 (setembro/2026)
#   [CORRIGIDO] Em instancia 12c o sqlplus devolvia o proprio texto do SELECT
#               junto com o erro, e o texto era lido como sessao RMAN. Toda
#               linha de resultado agora sai com prefixo (I#, S#, J#, O#, T#) e
#               so linha com prefixo e aproveitada; erros vao para sql_erros.txt.
#               LISTAGG removido (ORA-01489 em sessoes com muitos comandos).
#   [CORRIGIDO] Varredura travava em servidores com muitos arquivos: o filtro por
#               conteudo passa a ser um unico grep via xargs por raiz, com
#               tempo limite (WISEDB_CLONE_TIMEOUT, padrao 180 s por raiz) e
#               progresso na tela.
#   [CORRIGIDO] Pastas WiseDB com qualquer grafia (/WiseDb, /wisedb, /WISEDB)
#               sao descobertas na raiz do sistema.
#
# Versao 1.1 (setembro/2026)
#   [NOVO]      Descoberta automatica: cron completo + scripts chamados + logs
#               citados, varredura por conteudo e controlfile (v$rman_status).
#   [NOVO]      RPO/RTO sem default: acordado = A DEFINIR; observado calculado
#               a partir dos backups (v$rman_backup_job_details, 35 dias) e das
#               restauracoes encontradas.
#   [NOVO]      Classe RESTORE_VALIDATE.
#   [CORRIGIDO] Falso positivo por nome (rclone.conf casava com *clon*): arquivo
#               so entra se o CONTEUDO tiver comando de clone/restore; pastas
#               ocultas (.config, .cache, .local) e rclone ficam fora.
#   [CORRIGIDO] Mascara passa a cobrir qualquer chave terminada em key/key_id/
#               secret/token/password (ex.: access_key_id).
#===============================================================================
set -uo pipefail

HOSTN=$(hostname -s 2>/dev/null || hostname)
OUT="./coleta_${HOSTN}_$(date +%Y%m%d)/09_restore"
rm -rf "$OUT" 2>/dev/null
mkdir -p "$OUT/extratos" "$OUT/scripts_clone"
TMPD=$(mktemp -d "${TMPDIR:-/tmp}/wisedb_rst.XXXXXX") || { echo "[ERRO] mktemp"; exit 1; }
trap 'rm -rf "$TMPD" 2>/dev/null' EXIT

DIAS="${WISEDB_CLONE_DAYS:-365}"
MAXF="${WISEDB_CLONE_MAX:-40}"
DEPTH="${WISEDB_CLONE_DEPTH:-7}"
AGORA=$(date +%s)

SUDO=""
if [ "${WISEDB_SUDO:-0}" = "1" ] && command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
  SUDO="sudo -n"
fi
TOUT=""; command -v timeout >/dev/null 2>&1 && TOUT="timeout 60"
TLIM="${WISEDB_CLONE_TIMEOUT:-180}"
TVAR=""; command -v timeout >/dev/null 2>&1 && TVAR="timeout $TLIM"
prog(){ echo "  ... $*" >&2; }

rd(){ if [ -r "$1" ]; then cat "$1" 2>/dev/null; elif [ -n "$SUDO" ]; then $SUDO cat "$1" 2>/dev/null; fi; }
existe(){ [ -e "$1" ] || { [ -n "$SUDO" ] && $SUDO test -e "$1" 2>/dev/null; }; }

# Mascara de segredos: PASSWORD, PWD, SENHA, TOKEN, KEY, KEY_ID, SECRET, api_secret,
# sqlcmd -P, user/senha@, user/senha as sysdba e connect target user/senha.
mask(){
  sed -E \
    -e 's/(([A-Za-z0-9_.-]*(password|passwd|pwd|senha|token|secret|key|key_id|keyid))[[:space:]]*[=:][[:space:]]*)[^[:space:]",;]+/\1***REMOVIDO***/Ig' \
    -e 's/(identified[[:space:]]+by[[:space:]]+)[^[:space:];]+/\1***REMOVIDO***/Ig' \
    -e 's#(//[^/:@[:space:]]+:)[^@[:space:]]+(@)#\1***REMOVIDO***\2#g' \
    -e 's#([A-Za-z0-9_.$]+)/[^[:space:]/@"'"'"'*]{2,}@#\1/***REMOVIDO***@#g' \
    -e 's#([A-Za-z0-9_.$]+)/[^[:space:]/@"'"'"'*]{2,}([[:space:]]+as[[:space:]]+sys)#\1/***REMOVIDO***\2#Ig' \
    -e 's#((connect|conn)[[:space:]]+((target|auxiliary|catalog)[[:space:]]+)?["'"'"']?[A-Za-z0-9_.$]+)/[^[:space:]@"'"'"']+#\1/***REMOVIDO***#Ig' \
    -e 's/(sqlcmd.*-P[[:space:]]*)[^[:space:]]+/\1***REMOVIDO***/g' \
    -e 's/(-P[[:space:]]+)[^[:space:]]+/\1***REMOVIDO***/g'
}

# Marcadores. SCR_RX: comando de clone/restore em script. LOG_RX: execucao em log.
SCR_RX='duplicate[[:space:]]+(target[[:space:]]+)?database|from[[:space:]]+active[[:space:]]+database|restore[[:space:]]+(clone[[:space:]]+)?(primary[[:space:]]+)?(database|controlfile)|(^|[[:space:]/])impdp[[:space:]]|RESTORE[[:space:]]+DATABASE[[:space:]]'
LOG_RX='Starting Duplicate Db|Finished Duplicate Db|duplicate[[:space:]]+(target[[:space:]]+)?database|from active database|Starting restore at|Import: Release|RESTORE DATABASE successfully|restore[[:space:]]+(clone[[:space:]]+)?database'
TIER1_RX='Duplicate Db|duplicate[[:space:]]+(target[[:space:]]+)?database|Import: Release|RESTORE DATABASE successfully|restore clone'
NOME_OUT='rclone|/kit_coleta_backup/|/wisedb-kit/|/[0-9]{2}_coleta_[a-z_]+\.(sh|ps1)$|/wisedb_coleta_auto|/wisedb_digest|/coleta_[^/]+_[0-9]{8}/|/\.config/|/\.cache/|/\.local/|/\.git/|/wisedb_coleta_|/09_restore/|\.(gz|zip|bz2|xz|tar|dmp|bkp|bak|dbf|arc|trc|trm|aud|so|jar|pyc)$'

#---------------------------- 1. cron: rotinas agendadas -----------------------
# Le o cron completo (nao so linhas com "clone"): a rotina pode se chamar
# refresh_hml.sh, atualiza_base.sh, etc. O que decide e o conteudo do script.
: > "$TMPD/cron_all"
for u in $(printf '%s\n' "$(whoami)" oracle root grid | awk '!v[$0]++'); do
  if [ "$u" = "$(whoami)" ]; then c=$(crontab -l 2>/dev/null)
  elif [ -n "$SUDO" ]; then c=$($SUDO crontab -l -u "$u" 2>/dev/null)
  else c=$(crontab -l -u "$u" 2>/dev/null); fi
  [ -n "$c" ] && printf '%s\n' "$c" | grep -Ev '^[[:space:]]*(#|$)|^[A-Z_]+=' | sed "s|^|$u: |" >> "$TMPD/cron_all"
done
for f in /etc/crontab /etc/cron.d/*; do
  [ -f "$f" ] || continue
  rd "$f" | grep -Ev '^[[:space:]]*(#|$)|^[A-Z_]+=' | sed "s|^|$(basename "$f"): |" >> "$TMPD/cron_all"
done

caminhos(){ grep -oE '/[A-Za-z0-9._/+-]{2,}' | grep -vE '^/(dev|proc|sys)/' ; }
eh_script(){ echo "$1" | grep -qiE '\.(sh|ksh|bash|rman|rcv|sql|par|cmd|py)$' || rd "$1" | head -1 | grep -q '^#!'; }

declare -A ROT=()           # script de clone -> origem da descoberta
declare -a LOGDIRS=()
: > "$OUT/cron_clone.txt"
while IFS= read -r linha; do
  achou=0
  for p in $(printf '%s\n' "$linha" | caminhos | sort -u); do
    [ -f "$p" ] || existe "$p" || continue
    eh_script "$p" || continue
    if rd "$p" | grep -qiE "$SCR_RX"; then
      ROT[$p]="cron"; achou=1
    else
      # um nivel abaixo: script agendado que chama o script de clone
      for q in $(rd "$p" | caminhos | sort -u | head -50); do
        [ -f "$q" ] || existe "$q" || continue
        eh_script "$q" || continue
        rd "$q" | grep -qiE "$SCR_RX" && { ROT[$q]="cron (chamado por $p)"; achou=1; }
      done
    fi
  done
  if [ "$achou" = "1" ]; then
    echo "$linha" >> "$OUT/cron_clone.txt"
    for lg in $(printf '%s\n' "$linha" | grep -oE '>>?[[:space:]]*/[^[:space:];|&]+' | sed -E 's/^>>?[[:space:]]*//'); do
      LOGDIRS+=("$(dirname "$lg")")
    done
  fi
done < "$TMPD/cron_all"
mask < "$OUT/cron_clone.txt" > "$TMPD/cc" && mv "$TMPD/cc" "$OUT/cron_clone.txt"

#---------------------------- 2/3. varredura de arquivos -----------------------
# Pastas WiseDB em qualquer grafia na raiz (/WiseDb, /wisedb, /WISEDB...)
declare -a WDIRS=()
mapfile -t WDIRS < <(find / -maxdepth 1 -type d -iname '*wisedb*' 2>/dev/null)
declare -a DIRS=(${WDIRS[@]+"${WDIRS[@]}"} /wisedb /home /u01 /u02 /u03 /u04 /u05 /backup /bkp /orabackup /oracle
                 /scripts /dba /opt /dados "$HOME")
while read -r mp tp; do
  case "$tp" in ext2|ext3|ext4|xfs|btrfs|nfs|nfs4|ocfs2|acfs|cifs|vxfs) ;; *) continue;; esac
  case "$mp" in /|/boot|/boot/*|/var|/var/*|/usr|/usr/*|/tmp|/dev*|/run*|/proc*|/sys*) continue;; esac
  DIRS+=("$mp")
done < <(awk '{print $2, $3}' /proc/mounts 2>/dev/null)
if [ -n "${WISEDB_CLONE_DIRS:-}" ]; then
  IFS=':' read -r -a _ext <<< "$WISEDB_CLONE_DIRS"
  DIRS+=(${_ext[@]+"${_ext[@]}"})
fi
[ $# -gt 0 ] && DIRS+=("$@")
DIRS+=(${LOGDIRS[@]+"${LOGDIRS[@]}"})
# Diretorios de log citados dentro dos scripts de clone descobertos
for s in "${!ROT[@]}"; do
  for p in $(rd "$s" | grep -iE 'log|out|spool' | caminhos | sort -u | head -30); do
    d="$p"; [ -d "$d" ] || d=$(dirname "$p")
    [ -d "$d" ] && DIRS+=("$d")
  done
done

# Existentes, sem duplicar e sem subdiretorio de raiz ja listada
declare -a DIRS_OK=() DIRS_NEG=()
for d in $(printf '%s\n' "${DIRS[@]}" | sed 's:/*$::' | grep -v '^$' | sort -u); do
  if [ -d "$d" ] && [ -r "$d" ] && [ -x "$d" ]; then DIRS_OK+=("$d")
  elif [ -n "$SUDO" ] && $SUDO test -d "$d" 2>/dev/null; then DIRS_OK+=("$d")
  elif [ -d "$d" ]; then DIRS_NEG+=("$d")
  fi
done
declare -a RAIZES=()
for d in ${DIRS_OK[@]+"${DIRS_OK[@]}"}; do
  dentro=0
  for r in ${RAIZES[@]+"${RAIZES[@]}"}; do case "$d/" in "$r"/*) dentro=1; break;; esac; done
  [ "$dentro" = "0" ] && RAIZES+=("$d")
done

# 1) find lista os candidatos (poda de areas de banco/binarios) com limite de
#    tempo; 2) um unico grep por raiz filtra pelo CONTEUDO. Evita abrir arquivo
#    por arquivo em shell, que travava servidores com muitos logs.
PODA=( \( -path '*/diag' -o -path '*/product' -o -path '*/oradata' -o -path '*/fast_recovery_area'
          -o -path '*/flash_recovery_area' -o -path '*/oraInventory' -o -path '*/adump' -o -path '*/audit'
          -o -path '*/cfgtoollogs' -o -path '*/.cache' -o -path '*/.config' -o -path '*/.local' -o -path '*/.git'
          -o -path '*/checkpoints' -o -path '*/lost+found' -o -path '*/grid' -o -ipath '*protheus_data*'
          -o -ipath '*/totvs*/bin' -o -path '/proc' \) -prune )
: > "$TMPD/logs"; : > "$TMPD/scripts"; : > "$OUT/descartados.txt"; : > "$TMPD/timeout"
for r in ${RAIZES[@]+"${RAIZES[@]}"}; do
  prog "varrendo $r"
  : > "$TMPD/l_log"; : > "$TMPD/l_scr"
  $TVAR $SUDO find "$r" -maxdepth "$DEPTH" "${PODA[@]}" -o -type f -mtime -"$DIAS" -size -50M \
    \( -iname '*.log' -o -iname '*.out' -o -iname '*.lst' -o -iname '*.txt' \
       -o -iname '*clon*' -o -iname '*duplic*' -o -iname '*refresh*' -o -iname '*restore*' \) -print 2>/dev/null \
    | grep -vE "$NOME_OUT" | tr '\n' '\0' > "$TMPD/l_log"
  [ "${PIPESTATUS[0]}" = "124" ] && echo "$r (find de logs)" >> "$TMPD/timeout"
  $TVAR $SUDO find "$r" -maxdepth "$DEPTH" "${PODA[@]}" -o -type f -mtime -"$DIAS" -size -5M \
    \( -iname '*.sh' -o -iname '*.ksh' -o -iname '*.bash' -o -iname '*.rman' -o -iname '*.rcv' -o -iname '*.sql' -o -iname '*.par' \) -print 2>/dev/null \
    | grep -vE "$NOME_OUT" | tr '\n' '\0' > "$TMPD/l_scr"
  [ "${PIPESTATUS[0]}" = "124" ] && echo "$r (find de scripts)" >> "$TMPD/timeout"
  $TVAR xargs -0 -r $SUDO grep -lIiE "$LOG_RX" < "$TMPD/l_log" 2>/dev/null >> "$TMPD/hit_log"
  [ $? = 124 ] && echo "$r (grep de logs)" >> "$TMPD/timeout"
  $TVAR xargs -0 -r $SUDO grep -lIiE "$SCR_RX" < "$TMPD/l_scr" 2>/dev/null >> "$TMPD/hit_scr"
  [ $? = 124 ] && echo "$r (grep de scripts)" >> "$TMPD/timeout"
  # nomes que sugerem clone mas nao tem comando/saida de clone (transparencia)
  tr '\0' '\n' < "$TMPD/l_log" | grep -iE '/[^/]*(clon|duplic|refresh)[^/]*$' >> "$TMPD/nome_suspeito"
done
touch "$TMPD/hit_log" "$TMPD/hit_scr" "$TMPD/nome_suspeito"
for s in "${!ROT[@]}"; do echo "$s"; done >> "$TMPD/hit_scr"
sort -u -o "$TMPD/hit_log" "$TMPD/hit_log"; sort -u -o "$TMPD/hit_scr" "$TMPD/hit_scr"
sort -u "$TMPD/nome_suspeito" | grep -vxF -f "$TMPD/hit_log" | sed 's/$/ (nome sugere clone, mas sem saida de DUPLICATE\/RESTORE\/impdp)/' > "$OUT/descartados.txt"

while read -r f; do
  [ -z "$f" ] && continue
  st=$( { stat -c '%Y|%s|%U' "$f" 2>/dev/null || $SUDO stat -c '%Y|%s|%U' "$f" 2>/dev/null; } ) || continue
  echo "$st|$f" >> "$TMPD/scripts"
  [ -z "${ROT[$f]+x}" ] && ROT[$f]="varredura por conteudo"
done < "$TMPD/hit_scr"
prog "classificando $(grep -c . "$TMPD/hit_log") log(s) e $(grep -c . "$TMPD/hit_scr") script(s) com comando de clone/restore"
while read -r f; do
  [ -z "$f" ] && continue
  st=$( { stat -c '%Y|%s|%U' "$f" 2>/dev/null || $SUDO stat -c '%Y|%s|%U' "$f" 2>/dev/null; } ) || continue
  if rd "$f" | grep -qiE "$TIER1_RX"; then echo "1|$st|$f" >> "$TMPD/logs"; else echo "2|$st|$f" >> "$TMPD/logs"; fi
done < "$TMPD/hit_log"
# Tier 1 (clone/import/restore) primeiro; RESTORE VALIDATE limitado aos 5 mais novos
{ grep '^1|' "$TMPD/logs" | cut -d'|' -f2- | sort -t'|' -k1,1nr | head -"$MAXF"
  grep '^2|' "$TMPD/logs" | cut -d'|' -f2- | sort -t'|' -k1,1nr | head -5; } > "$TMPD/logs_ord"
NLOGS_T1=$(grep -c '^1|' "$TMPD/logs"); NLOGS_T2=$(grep -c '^2|' "$TMPD/logs")
NLOGS=$(wc -l < "$TMPD/logs_ord"); NSCR=$(sort -u "$TMPD/scripts" | wc -l)

#---------------------------- funcoes de apoio ---------------------------------
to_epoch(){ # converte timestamp em varios formatos para epoch
  local s="$1"
  s=$(echo "$s" | sed -E 's#^([0-9]{2})/([0-9]{2})/([0-9]{4})#\3-\2-\1#;
        s#^([0-9]{2}-[A-Za-z]{3}-[0-9]{2,4}):#\1 #;
        s#^(dom|seg|ter|qua|qui|sex|sab|sáb|Sun|Mon|Tue|Wed|Thu|Fri|Sat)[a-z.]*[[:space:]]+##I;
        s#\b[Ff][Ee][Vv]\b#Feb#; s#\b[Aa][Bb][Rr]\b#Apr#; s#\b[Mm][Aa][Ii]\b#May#;
        s#\b[Aa][Gg][Oo]\b#Aug#; s#\b[Ss][Ee][Tt]\b#Sep#; s#\b[Oo][Uu][Tt]\b#Oct#; s#\b[Dd][Ee][Zz]\b#Dec#')
  local e; e=$(date -d "$s" +%s 2>/dev/null) || return 1
  [ "$e" -gt 946684800 ] && [ "$e" -le $((AGORA+86400)) ] && echo "$e"
}
RX_TS='[0-9]{4}-[0-9]{2}-[0-9]{2}[ T][0-9]{2}:[0-9]{2}:[0-9]{2}|[0-9]{2}/[0-9]{2}/[0-9]{4}[ ]+[0-9]{2}:[0-9]{2}(:[0-9]{2})?|[0-9]{2}-[A-Za-z]{3}-[0-9]{2,4}[ :][0-9]{2}:[0-9]{2}:[0-9]{2}|([A-Za-z]{3}[ ]+)?[A-Za-z]{3}[ ]+[0-9]{1,2}[ ]+[0-9]{2}:[0-9]{2}:[0-9]{2}[ ]+([A-Z+0-9-]{2,6}[ ]+)?[0-9]{4}'
# Inicio/fim: prioriza as linhas de marco do RMAN/Data Pump/SQL Server e so
# depois recorre ao primeiro/ultimo timestamp do arquivo.
RX_INI='Starting (Duplicate Db|restore|recover|session)|Import: Release|^In[ií]cio|^Inicio'
RX_FIM='Finished (Duplicate Db|recover|restore|session)|Duplicate Db complete|job .*(successfully )?completed|completed with [0-9]+ error|successfully processed|^Fim|^Termino|^T[eé]rmino|^End'
ts_de(){ grep -oE "$RX_TS" | while read -r t; do to_epoch "$t" && break; done | head -1; }
primeiro_ts(){ local e; e=$(grep -iE "$RX_INI" "$1" | ts_de); [ -z "$e" ] && e=$(grep -oE "$RX_TS" "$1" | head -8 | ts_de); echo "$e"; }
ultimo_ts(){ local e; e=$(grep -iE "$RX_FIM" "$1" | tac | ts_de); [ -z "$e" ] && e=$(grep -oE "$RX_TS" "$1" | tail -8 | tac | ts_de); echo "$e"; }
fmt(){ [ -n "$1" ] && date -d "@$1" '+%d/%m/%Y %H:%M:%S'; }
fmt_or(){ if [ -n "$1" ]; then fmt "$1"; else echo "$2"; fi; }
hms(){ local s=$1; printf '%02d:%02d:%02d' $((s/3600)) $(((s%3600)/60)) $((s%60)); }

# Proxima execucao de uma expressao cron (5 campos). Suporta *, */n, a-b, a-b/n e listas.
cron_casa(){ # valor campo min max
  local v=$1 f=$2 lo=$3 hi=$4 part a b st
  IFS=',' read -r -a parts <<< "$f"
  for part in "${parts[@]}"; do
    st=1
    [[ "$part" == */* ]] && { st=${part#*/}; part=${part%/*}; }
    if [ "$part" = "*" ]; then a=$lo; b=$hi
    elif [[ "$part" == *-* ]]; then a=${part%-*}; b=${part#*-}
    else a=$part; b=$part; [ "$st" != "1" ] && b=$hi; fi
    [[ "$a$b$st" =~ ^[0-9]+$ ]] || continue
    [ "$v" -ge "$a" ] && [ "$v" -le "$b" ] && [ $(( (v-a) % st )) -eq 0 ] && return 0
  done
  return 1
}
proxima_cron(){ # "min hora dom mes dow"
  local mi ho dm me dw d dt ddm dme ddw h m hh mm okd
  read -r mi ho dm me dw <<< "$1"
  [ -z "$dw" ] && return
  for d in $(seq 0 400); do
    dt=$(date -d "+$d day" '+%d %m %w %Y-%m-%d') || return
    read -r ddm dme ddw dt <<< "$dt"; ddm=$((10#$ddm)); dme=$((10#$dme))
    cron_casa "$dme" "$me" 1 12 || continue
    okd=1
    if [ "$dm" != "*" ] && [ "$dw" != "*" ]; then
      { cron_casa "$ddm" "$dm" 1 31 || cron_casa "$ddw" "${dw//7/0}" 0 6; } || okd=0
    else
      cron_casa "$ddm" "$dm" 1 31 || okd=0
      cron_casa "$ddw" "${dw//7/0}" 0 6 || okd=0
    fi
    [ "$okd" = "1" ] || continue
    for h in $(seq 0 23); do cron_casa "$h" "$ho" 0 23 || continue
      for m in $(seq 0 59); do cron_casa "$m" "$mi" 0 59 || continue
        hh=$(printf '%02d' "$h"); mm=$(printf '%02d' "$m")
        [ "$(date -d "$dt $hh:$mm" +%s)" -gt "$AGORA" ] && { echo "$(date -d "$dt" '+%d/%m/%Y') $hh:$mm"; return; }
      done
    done
  done
}


#---------------------------- 4. bancos locais (controlfile) -------------------
# Instancias: WISEDB_ORA_SIDS ou todas com pmon ativo e presentes no oratab.
declare -a SIDS=()
if [ -n "${WISEDB_ORA_SIDS:-}" ]; then read -r -a SIDS <<< "$WISEDB_ORA_SIDS"
else mapfile -t SIDS < <(ps -eo args 2>/dev/null | grep -oE '^ora_pmon_[A-Za-z0-9_]+' | sed 's/ora_pmon_//' | sort -u); fi
home_de(){ awk -F: -v s="$1" '$1==s{print $2; exit}' /etc/oratab 2>/dev/null; }
sqlq(){ # sqlq SID HOME  (SQL no stdin)
  ORACLE_SID="$1" ORACLE_HOME="$2" LD_LIBRARY_PATH="$2/lib" $TOUT "$2/bin/sqlplus" -s -L / as sysdba 2>/dev/null
}
: > "$TMPD/rman_sessoes"; : > "$TMPD/bkjobs"
{
  echo "## Inventario v\$database das instancias locais (valores como retornados)"
  echo "## SID | NAME | DBID | CREATED | RESETLOGS_TIME | LOG_MODE | OPEN_MODE | ROLE | INCARNATIONS"
} > "$OUT/bancos_locais.txt"
declare -a SIDS_OK=()
for sid in ${SIDS[@]+"${SIDS[@]}"}; do
  home=$(home_de "$sid")
  if [ -z "$home" ] || [ ! -x "$home/bin/sqlplus" ]; then echo "$sid | ORACLE_HOME nao encontrado no oratab" >> "$OUT/bancos_locais.txt"; continue; fi
  prog "consultando controlfile de $sid"
  inv=$(sqlq "$sid" "$home" <<SQL_EOF | grep '^I#' | sed 's/^I#//' | head -1
set heading off feedback off pagesize 0 linesize 400 trimspool on
select 'I#'||d.name||'|'||d.dbid||'|'||to_char(d.created,'YYYY-MM-DD HH24:MI:SS')||'|'||to_char(d.resetlogs_time,'YYYY-MM-DD HH24:MI:SS')||'|'||d.log_mode||'|'||d.open_mode||'|'||d.database_role||'|'||(select count(*) from v\$database_incarnation) from v\$database d;
exit
SQL_EOF
)
  if [ -z "$inv" ]; then echo "$sid | sem conexao (/ as sysdba falhou ou instancia fechada)" >> "$OUT/bancos_locais.txt"; continue; fi
  SIDS_OK+=("$sid")
  echo "$sid | $inv" | sed 's/|/ | /g; s/  */ /g' >> "$OUT/bancos_locais.txt"
  echo "$sid|$inv" >> "$TMPD/inv"

  # Sessoes RMAN de RESTORE/DUPLICATE registradas no controlfile
  sqlq "$sid" "$home" <<SQL_EOF | tee -a "$TMPD/sqlout_$sid" | grep '^S#' | sed "s/^S#/$sid|/" >> "$TMPD/rman_sessoes"
set heading off feedback off pagesize 0 linesize 1000 trimspool on
select 'S#'||s.session_recid||'|'||s.session_stamp||'|'||to_char(min(s.start_time),'YYYY-MM-DD HH24:MI:SS')||'|'||
       to_char(max(s.end_time),'YYYY-MM-DD HH24:MI:SS')||'|'||
       max(case when s.status like 'FAILED%' then 3 when s.status like '%ERRORS%' then 2
                when s.status like 'RUNNING%' then 4 when s.status like '%WARNING%' then 1 else 0 end)||'|'||
       min(s.operation)||decode(min(s.operation),max(s.operation),'',' / '||max(s.operation))||' '||
       nvl(max(s.object_type),'-')||' ('||count(*)||' comando(s))' 
from v\$rman_status s
where s.row_level = 1 and s.start_time > sysdate - $DIAS
  and (s.operation like 'RESTORE%' or s.operation like 'DUPLICATE%')
group by s.session_recid, s.session_stamp
order by 3;
exit
SQL_EOF

  # Jobs de backup (35 dias) para o RPO observado e referencia de RTO
  sqlq "$sid" "$home" <<SQL_EOF | tee -a "$TMPD/sqlout_$sid" | grep '^J#' | sed "s/^J#/$sid|/" >> "$TMPD/bkjobs"
set heading off feedback off pagesize 0 linesize 400 trimspool on
select 'J#'||input_type||'|'||status||'|'||to_char(start_time,'YYYY-MM-DD HH24:MI:SS')||'|'||to_char(end_time,'YYYY-MM-DD HH24:MI:SS')||'|'||elapsed_seconds
from v\$rman_backup_job_details where start_time > sysdate - 35 order by end_time;
exit
SQL_EOF
done

# Erros de SQL (ORA-/SP2-) por instancia, para diagnostico
for f in "$TMPD"/sqlout_*; do
  [ -f "$f" ] || continue
  e=$(grep -E 'ORA-[0-9]{5}|SP2-[0-9]{4}' "$f" | sort -u | head -10)
  [ -n "$e" ] && { echo "## ${f##*/sqlout_}"; echo "$e"; } >> "$OUT/sql_erros.txt"
done

# Uma pseudo-evidencia por sessao RMAN, com a saida de v$rman_output quando
# ainda estiver em memoria (a v$rman_output nao sobrevive a restart da instancia).
: > "$TMPD/sessoes_ord"
n=0
while IFS='|' read -r sid srecid sstamp ini fim sev ops; do
  [[ "$srecid" =~ ^[0-9]+$ ]] && [[ "$sstamp" =~ ^[0-9]+$ ]] || continue
  n=$((n+1)); [ "$n" -gt 60 ] && break
  home=$(home_de "$sid"); pl="$TMPD/sess_${sid}_${srecid}.log"
  { echo "## FONTE: controlfile de $sid (v\$rman_status sessao $srecid) | operacoes: $ops"
    echo "Starting session at $ini"
    sqlq "$sid" "$home" <<SQL_EOF | grep '^O#' | sed 's/^O#//' | head -400
set heading off feedback off pagesize 0 linesize 400 trimspool on
select 'O#'||output from v\$rman_output where session_recid = $srecid and session_stamp = $sstamp order by recid;
exit
SQL_EOF
    [ -n "$fim" ] && echo "Finished session at $fim"
  } > "$pl"
  echo "$sid|$srecid|$ini|$fim|$sev|$ops|$pl" >> "$TMPD/sessoes_ord"
done < "$TMPD/rman_sessoes"

# Tamanho atual de um banco local (v$datafile). Valor exibido como retornado.
declare -A TAM_CACHE=()
tam_db(){
  local n="$1" sid home r=""
  [ -z "$n" ] && return
  [ -n "${TAM_CACHE[$n]+x}" ] && { echo "${TAM_CACHE[$n]}"; return; }
  sid=$(printf '%s\n' ${SIDS_OK[@]+"${SIDS_OK[@]}"} | grep -ix "$n" | head -1)
  [ -z "$sid" ] && sid=$(awk -F'|' -v n="$n" 'toupper($2)==toupper(n){print $1; exit}' "$TMPD/inv" 2>/dev/null)
  if [ -n "$sid" ]; then
    home=$(home_de "$sid")
    r=$(sqlq "$sid" "$home" <<'SQL_EOF' | grep '^T#' | sed 's/^T#//' | head -1 | tr -d ' '
set heading off feedback off pagesize 0 linesize 200
select 'T#'||sum(bytes)/1024/1024/1024 from v$datafile;
exit
SQL_EOF
)
    [ -n "$r" ] && r="$r GB (v\$datafile atual de $sid, consultado em $(date '+%d/%m/%Y %H:%M'))"
  fi
  TAM_CACHE[$n]="$r"; echo "$r"
}

#---------------------------- analise de cada execucao -------------------------
TSV="$OUT/execucoes_clone.tsv"
printf 'id\tarquivo\tsegmento\tmetodo\tevidencia_de_backup\tstatus\torigem\tdestino\tinicio\tfim\tfonte_do_tempo\tduracao_seg\tduracao\tbackup_location\ttags_backup\tdata_backup_usado\tpecas_lidas\tuntil\terros\tdono\tmtime\n' > "$TSV"
ID=0
: > "$TMPD/blocos"
FORCE_STATUS=""; FORCE_ORI=""; FORCE_DST=""; FORCE_CF=0

analisa(){ # seg arquivo idx nsegs mtime dono
  local seg="$1" arq="$2" idx="$3" nseg="$4" mt="$5" dono="$6"
  local met status ori dst ini fim fonte dur durh loc tags tmin tmax dbk pec unt err toperr efet evb
  if grep -qiE 'from active database|using network backup set|from service |backup as copy reuse' "$seg"; then met="ACTIVE_DATABASE"
  elif grep -qiE 'Duplicate Db|duplicate[[:space:]]+(target[[:space:]]+)?database|restore clone|RESTORE DATABASE successfully' "$seg" && \
       ! grep -qiE 'restore[^;]*validate' "$seg"; then
       if grep -qiE 'RESTORE DATABASE successfully|RESTORE LOG successfully' "$seg"; then met="SQLSERVER"; else met="BACKUP_RMAN"; fi
  elif grep -qiE 'restore[^;]*validate|validate[[:space:]]+(backupset|database)|RESTORE VALIDATE' "$seg"; then met="RESTORE_VALIDATE"
  elif grep -qiE 'reading from backup piece|restored backup piece|backup location|restore[[:space:]]+(database|controlfile)|RESTORE (DATABASE|CONTROLFILE|DATAFILE)' "$seg"; then met="BACKUP_RMAN"
  elif grep -qiE 'Import: Release|dumpfile=' "$seg"; then met="DATAPUMP"
  else met="INDETERMINADO"; fi
  [ "$nseg" -gt 1 ] && [ "$met" = "INDETERMINADO" ] && return 0

  if [ -n "$FORCE_STATUS" ]; then status="$FORCE_STATUS"
  elif grep -qiE 'RMAN-03002|RMAN-03009|failure of (duplicate|restore|recover)|RMAN-05501|RMAN-06054|RMAN-06026|job "[^"]*" (stopped|terminated)|terminating abnormally|ORA-01547|ORA-01194' "$seg"; then status="FALHA"
  elif grep -qiE 'completed with [1-9][0-9]* error' "$seg"; then status="SUCESSO_COM_ALERTAS"
  elif grep -qiE 'Finished Duplicate Db|Finished (restore|recover)|media recovery complete|database opened|successfully completed|successfully processed|Duplicate Db complete' "$seg"; then status="SUCESSO"
  else status="INCONCLUSIVO"; fi

  ori=$(grep -oiE 'connected to target database: [A-Za-z0-9_$#]+' "$seg" | head -1 | awk '{print $NF}')
  [ -z "$ori" ] && ori=$(grep -oiE 'duplicate[[:space:]]+database[[:space:]]+["'"'"']?[A-Za-z0-9_]+' "$seg" | grep -viE 'duplicate[[:space:]]+database[[:space:]]+to' | head -1 | awk '{print $NF}' | tr -d "\"'")
  dst=$(grep -oiE 'connected to auxiliary database: [A-Za-z0-9_$#]+' "$seg" | head -1 | awk '{print $NF}')
  [ -z "$dst" ] && dst=$(grep -oiE 'duplicate[^;]*[[:space:]]to[[:space:]]+["'"'"']?[A-Za-z0-9_]+' "$seg" | head -1 | awk '{print $NF}' | tr -d "\"'")
  [ -z "$dst" ] && [ "$met" = "SQLSERVER" ] && dst=$(grep -oiE 'RESTORE DATABASE[[:space:]]+\[?[A-Za-z0-9_]+' "$seg" | head -1 | awk '{print $NF}' | tr -d '[')
  [ -z "$ori" ] && ori="$FORCE_ORI"; [ -z "$dst" ] && dst="$FORCE_DST"
  ori=$(echo "$ori" | tr '[:lower:]' '[:upper:]'); dst=$(echo "$dst" | tr '[:lower:]' '[:upper:]')

  ini=$(primeiro_ts "$seg"); fim=$(ultimo_ts "$seg"); fonte="log"
  if [ -z "$fim" ] && [ -n "$ini" ] && [ "$idx" = "$nseg" ] && [ "$mt" -gt "$ini" ] && [ $((mt-ini)) -le 172800 ]; then
    fim="$mt"; fonte="inicio: log | fim: mtime do arquivo"
  fi
  if [ -n "$ini" ] && [ -n "$fim" ] && [ "$fim" -le "$ini" ]; then fonte="timestamps inconsistentes no log"; fi
  [ -z "$ini" ] && fonte="inicio nao identificado no log"
  dur=""; durh=""
  if [ -n "$ini" ] && [ -n "$fim" ] && [ "$fim" -gt "$ini" ]; then dur=$((fim-ini)); durh=$(hms "$dur"); fi

  loc=$(grep -oiE "backup location[[:space:]]*['\"][^'\"]+" "$seg" | head -1 | sed -E "s/^[^'\"]*['\"]//")
  tags=$(grep -iE 'reading from backup piece|restored backup piece|piece handle=.*tag=' "$seg" | grep -oE 'TAG[0-9]{8}T[0-9]{6}' | sort -u)
  [ "$met" != "BACKUP_RMAN" ] && [ "$met" != "RESTORE_VALIDATE" ] && tags=""
  tmin=$(echo "$tags" | grep . | head -1); tmax=$(echo "$tags" | grep . | tail -1)
  dbk=""
  [ -n "$tmax" ] && dbk=$(echo "$tmax" | sed -E 's/TAG([0-9]{4})([0-9]{2})([0-9]{2})T([0-9]{2})([0-9]{2}).*/\3\/\2\/\1 \4:\5/')
  pec=$(grep -ciE 'reading from backup piece|restored backup piece' "$seg")
  unt=$(grep -oiE "until[[:space:]]+(time|scn|sequence)[^;)]*" "$seg" | head -1 | tr -s ' ')
  err=$(grep -oE '(ORA|RMAN)-[0-9]{5}' "$seg" | grep -vE 'RMAN-(00569|00571|07554)' | wc -l)
  toperr=$(grep -oE '(ORA|RMAN)-[0-9]{5}' "$seg" | grep -vE 'RMAN-(00569|00571|07554)' | sort | uniq -c | sort -rn | head -4 | awk '{printf "%s%s(%s)", (NR>1?", ":""), $2, $1}')
  local dpn dmp
  dpn=$(grep -oiE 'completed with [0-9]+ error' "$seg" | tail -1 | grep -oE '[0-9]+')
  [ -n "$dpn" ] && [ "$dpn" -gt "$err" ] && err="$dpn"
  dmp=$(grep -oiE 'dumpfile=[^[:space:]]+' "$seg" | head -1 | cut -d= -f2-)
  case "$met" in BACKUP_RMAN|DATAPUMP|SQLSERVER) evb="SIM";; ACTIVE_DATABASE) evb="NAO";; RESTORE_VALIDATE) evb="PARCIAL";; *) evb="INDETERMINADO";; esac

  ID=$((ID+1))
  printf '%s\t%s\t%s/%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$ID" "$arq" "$idx" "$nseg" "$met" "$evb" \
    "$status" "${ori:-}" "${dst:-}" "$(fmt "$ini")" "$(fmt "$fim")" "$fonte" "${dur:-}" "${durh:-}" \
    "${loc:-${dmp:-}}" "${tmin:+$tmin..$tmax}" "${dbk:-}" "$pec" "${unt:-}" "$err" "$dono" "$(fmt "$mt")" >> "$TSV"

  { echo "## Extrato #$ID | $arq | segmento $idx/$nseg | metodo $met | status $status"
    grep -niE 'FONTE:|connected to|duplicate|active database|backup location|until|Starting|Finished|reading from backup piece|restored backup piece|validat|media recovery|database opened|ORA-[0-9]{5}|RMAN-0[0-9]{4}|Import: Release|job .*completed|RESTORE (DATABASE|LOG)|successfully|error' "$seg" |
      grep -vE 'RMAN-0(0569|0571)' | head -80
  } | mask > "$OUT/extratos/extrato_$(printf '%03d' "$ID").txt"

  local cr="" nx="" pref expr
  pref=$(basename "$arq" | sed -E 's/[._-]?[0-9]{6,}.*//; s/\.[A-Za-z]+$//')
  if [ -s "$OUT/cron_clone.txt" ]; then
    if [ "$(grep -c . "$OUT/cron_clone.txt")" = "1" ]; then cr=$(head -1 "$OUT/cron_clone.txt")
    else
      [ -n "$dst" ] && cr=$(grep -i "$dst" "$OUT/cron_clone.txt" | head -1)
      [ -z "$cr" ] && [ ${#pref} -ge 4 ] && cr=$(grep -iF "$pref" "$OUT/cron_clone.txt" | head -1)
    fi
    if [ -n "$cr" ]; then
      expr=$(echo "$cr" | sed -E 's/^[^:]+: //' | awk '{print $1,$2,$3,$4,$5}')
      echo "$expr" | grep -qE '^[0-9*,/-]+ [0-9*,/-]+ [0-9*,/-]+ [0-9*,/-]+ [0-9*,/-]+$' && nx=$(proxima_cron "$expr")
    fi
  fi

  case "$met" in
    BACKUP_RMAN|DATAPUMP|SQLSERVER)
      case "$status" in
        SUCESSO) efet="Sim. Restauracao a partir de backup concluida com sucesso";;
        SUCESSO_COM_ALERTAS) efet="Sim, com ressalvas. Concluida com $err erro(s) registrados";;
        FALHA) efet="Nao. Execucao falhou${toperr:+ ($toperr)}";;
        *) efet="Nao comprovado. Sem marcador de conclusao";;
      esac;;
    ACTIVE_DATABASE) efet="Nao se aplica. Clonagem via rede a partir da producao (Active Database/FROM SERVICE), nao utiliza os backups";;
    RESTORE_VALIDATE) efet="Parcial. RESTORE VALIDATE comprova a leitura dos backups, mas nao restaura nem abre o banco";;
    *) efet="Nao comprovado. Metodo nao identificado";;
  esac

  local tori tdst
  tori=$(tam_db "$ori"); tdst=$(tam_db "$dst")
  {
    echo "------------------------------------------------------------------------"
    echo " REGISTRO DE TESTE #$ID   metodo: $met   status: $status"
    echo "------------------------------------------------------------------------"
    echo " Servico de negocio ..............: [A PREENCHER] sistema que utiliza ${ori:-${dst:-o banco}}"
    case "$met" in
      SQLSERVER) echo " Servico de TI ...................: SQL Server | restore em ${dst:-destino nao identificado}";;
      DATAPUMP)  echo " Servico de TI ...................: Oracle Data Pump | importacao em ${dst:-destino nao identificado}";;
      RESTORE_VALIDATE) echo " Servico de TI ...................: Oracle Database | validacao de backup${dst:+ de $dst}${ori:+ de $ori}";;
      *)         echo " Servico de TI ...................: Oracle Database | ${ori:-origem nao identificada} -> ${dst:-destino nao identificado}";;
    esac
    echo " Responsavel pela execucao .......: WiseDB (rotina automatizada; dono: $dono)"
    echo " Responsavel pela validacao ......: [A PREENCHER]"
    echo " Tamanho na origem ...............: ${tori:-[A PREENCHER] banco de origem nao e local a este host}"
    echo " Tamanho no destino ..............: ${tdst:-[A PREENCHER] banco de destino nao esta ativo neste host}"
    echo " Tempo total previsto ............: A DEFINIR (RTO nao acordado com o cliente)"
    echo " Data/Hora inicio ................: $(fmt_or "$ini" "nao identificado")"
    echo " Data/Hora fim ...................: $(fmt_or "$fim" "nao identificado")"
    echo " Tempo total real ................: ${durh:-nao mensuravel}${dur:+ ($fonte)}"
    echo " Dentro do tempo previsto ........: Nao avaliavel (RTO a definir)"
    echo " Teste efetivo (Sim/Nao) .........: $efet"
    if [ -n "$nx" ]; then echo " Data do proximo teste ...........: $nx (proxima execucao do agendamento abaixo)"
    else echo " Data do proximo teste ...........: A DEFINIR (nenhum agendamento associado)"; fi
    echo " Observacoes .....................:"
    [ -n "$durh" ] && [ "$evb" = "SIM" ] && echo "   - RTO observado neste teste: $durh"
    case "$met" in BACKUP_RMAN|RESTORE_VALIDATE)
      echo "   - Backup utilizado: ${loc:+location $loc; }${tmin:+tags $tmin..$tmax; }${dbk:+backup mais recente de $dbk; }$pec leitura(s) de backup piece";;
    esac
    [ -n "$dmp" ] && echo "   - Dump utilizado: $dmp"
    [ -n "$unt" ] && echo "   - Ponto de recuperacao: $unt"
    echo "   - Erros ORA/RMAN: $err${toperr:+ ($toperr)}"
    [ -n "$cr" ] && echo "   - Agendamento: $cr"
    [ "$FORCE_CF" = "1" ] && echo "   - Registro do controlfile do proprio banco: pode ser teste ou recuperacao real; confirmar com a equipe antes de usar como teste"
    echo "   - Evidencia: $arq (segmento $idx/$nseg); extrato_$(printf '%03d' "$ID").txt"
    echo
  } >> "$TMPD/blocos"
}

# Logs de arquivo
n=0
while IFS='|' read -r mt sz dono f; do
  [ -z "$f" ] && continue
  rd "$f" > "$TMPD/log_atual"
  ndup=$(grep -ciE 'Starting Duplicate Db|Import: Release|Starting restore at' "$TMPD/log_atual")
  rm -f "$TMPD"/seg_*
  if [ "$ndup" -gt 1 ] && [ "$(grep -c 'Recovery Manager: Release\|Import: Release' "$TMPD/log_atual")" -gt 1 ]; then
    awk -v o="$TMPD/seg_" '/Recovery Manager: Release|Import: Release/{ if (seen) n++; seen=1 } { printf "%s\n", $0 > (o sprintf("%04d", n+1)) }' "$TMPD/log_atual"
  else
    cp "$TMPD/log_atual" "$TMPD/seg_0001"
  fi
  segs=$(ls -1 "$TMPD"/seg_* 2>/dev/null | wc -l); i=0
  for s in $(ls -1 "$TMPD"/seg_* 2>/dev/null); do
    i=$((i+1)); analisa "$s" "$f" "$i" "$segs" "$mt" "$dono"
  done
done < "$TMPD/logs_ord"

# Sessoes do controlfile
while IFS='|' read -r sid srecid ini fim sev ops pl; do
  [ -z "$srecid" ] && continue
  case "$sev" in 0) FORCE_STATUS="SUCESSO";; 1) FORCE_STATUS="SUCESSO_COM_ALERTAS";; 2|3) FORCE_STATUS="FALHA";; *) FORCE_STATUS="INCONCLUSIVO";; esac
  nm=$(awk -F'|' -v s="$sid" '$1==s{print $2; exit}' "$TMPD/inv")
  FORCE_DST="${nm:-$sid}"; FORCE_ORI="${nm:-$sid}"; FORCE_CF=1
  # Sem saida em memoria, o tipo vem da propria operacao registrada
  [ -f "$pl" ] || continue
  nlin=$(grep -vc '^\(##\|Starting session\|Finished session\)' "$pl" 2>/dev/null); nlin=${nlin:-0}
  if [ "$nlin" -eq 0 ]; then
    case "$ops" in *VALIDATE*) echo "RESTORE VALIDATE" >> "$pl";; *DUPLICATE*) echo "Duplicate Db (sem saida em v\$rman_output)" >> "$pl";; *) echo "restore database (registro de controlfile: $ops)" >> "$pl";; esac
  fi
  e_fim=$(to_epoch "$fim"); [ -z "$e_fim" ] && e_fim=$(to_epoch "$ini")
  analisa "$pl" "controlfile:$sid(v\$rman_status sessao $srecid: $ops)" 1 1 "${e_fim:-$AGORA}" "oracle"
  FORCE_STATUS=""; FORCE_DST=""; FORCE_ORI=""; FORCE_CF=0
done < "$TMPD/sessoes_ord"

#---------------------------- rotinas (scripts) descobertas --------------------
{
  echo "## Rotinas de clonagem/restauracao descobertas (scripts com comando DUPLICATE/RESTORE/impdp)"
  sort -u "$TMPD/scripts" | sort -t'|' -k1,1nr | while IFS='|' read -r mt sz dono f; do
    [ -z "$f" ] && continue
    m="INDETERMINADO"
    if rd "$f" | grep -qiE 'from[[:space:]]+active[[:space:]]+database|from[[:space:]]+service'; then m="ACTIVE_DATABASE"
    elif rd "$f" | grep -qiE 'restore[^;]*validate'; then m="RESTORE_VALIDATE"
    elif rd "$f" | grep -qiE 'duplicate|restore[[:space:]]+(clone[[:space:]]+)?(database|controlfile)'; then m="BACKUP_RMAN"
    elif rd "$f" | grep -qiE 'impdp'; then m="DATAPUMP"
    elif rd "$f" | grep -qiE 'RESTORE[[:space:]]+DATABASE'; then m="SQLSERVER"; fi
    echo "  $(fmt "$mt") | $m | origem da descoberta: ${ROT[$f]:-varredura} | $dono | $f"
    rd "$f" | head -c 204800 | mask > "$OUT/scripts_clone/$(echo "${f#/}" | tr '/' '_').txt"
  done
} > "$OUT/rotinas_descobertas.txt"
cp "$OUT/rotinas_descobertas.txt" "$OUT/scripts_clone/indice.txt"

#---------------------------- RPO / RTO observados -----------------------------
cnt(){ awk -F'\t' -v c="$1" -v v="$2" 'NR>1 && $c==v' "$TSV" | wc -l; }
TOT=$(( $(wc -l < "$TSV") - 1 ))
B_OK=$(awk -F'\t' 'NR>1 && $5=="SIM" && ($6=="SUCESSO"||$6=="SUCESSO_COM_ALERTAS")' "$TSV" | wc -l)
ULT_OK=$(awk -F'\t' 'NR>1 && $5=="SIM" && ($6=="SUCESSO"||$6=="SUCESSO_COM_ALERTAS"){print $10" | "$4" | "$7" -> "$8}' "$TSV" |
         awk '{split($1,d,"/"); print d[3] d[2] d[1] " " $0}' | sort -r | head -1 | cut -d' ' -f2-)

RR="$OUT/rpo_rto_observado.txt"
{
  echo "RPO / RTO: acordado = A DEFINIR (sem valor default). Abaixo, o que o ambiente pratica hoje."
  echo
  echo "RTO OBSERVADO (restauracoes a partir de backup concluidas):"
  awk -F'\t' 'NR>1 && $5=="SIM" && ($6=="SUCESSO"||$6=="SUCESSO_COM_ALERTAS") && $12!=""' "$TSV" > "$TMPD/rto"
  if [ -s "$TMPD/rto" ]; then
    mx=$(sort -t$'\t' -k12,12n "$TMPD/rto" | tail -1)
    ul=$(awk -F'\t' '{split($10,a," "); split(a[1],d,"/"); print d[3] d[2] d[1] a[2] "\t" $0}' "$TMPD/rto" | sort -r | head -1 | cut -f2-)
    echo "  - Testes medidos ............: $(wc -l < "$TMPD/rto")"
    echo "  - Ultimo ....................: $(echo "$ul" | cut -f13) em $(echo "$ul" | cut -f10) ($(echo "$ul" | cut -f4), $(echo "$ul" | cut -f7) -> $(echo "$ul" | cut -f8))"
    echo "  - Maior .....................: $(echo "$mx" | cut -f13) em $(echo "$mx" | cut -f10) ($(echo "$mx" | cut -f7) -> $(echo "$mx" | cut -f8))"
  else
    echo "  - Nao mensuravel: nenhuma restauracao a partir de backup com sucesso e com duracao registrada."
  fi
  echo
  echo "RPO OBSERVADO POR BANCO (v\$rman_backup_job_details, ultimos 35 dias, jobs com sucesso):"
  if [ ! -s "$TMPD/bkjobs" ]; then
    echo "  - Nao mensuravel neste host: nenhuma instancia local consultada ou sem jobs de backup registrados."
  fi
  for sid in $(cut -d'|' -f1 "$TMPD/bkjobs" 2>/dev/null | sort -u); do
    lm=$(awk -F'|' -v s="$sid" '$1==s{print $6; exit}' "$TMPD/inv")
    awk -F'|' -v s="$sid" '$1==s && $3 ~ /^COMPLETED/ && $2!="CONTROLFILE" && $2!="SPFILE" && $5!=""{print $5}' "$TMPD/bkjobs" > "$TMPD/fins"
    echo "  [$sid] log_mode=${lm:-?}"
    if [ ! -s "$TMPD/fins" ]; then echo "    - Nenhum backup com sucesso em 35 dias: RPO nao garantido"; continue; fi
    date -f "$TMPD/fins" +%s 2>/dev/null | sort -n > "$TMPD/ep"
    echo "$AGORA" >> "$TMPD/ep"
    awk 'NR>1{g=$1-p; print g" "p" "$1} {p=$1}' "$TMPD/ep" > "$TMPD/gaps"
    maior=$(sort -n "$TMPD/gaps" | tail -1)
    med=$(awk '{print $1}' "$TMPD/gaps" | sort -n | awk '{a[NR]=$1} END{print a[int((NR+1)/2)]}')
    ult=$(tail -2 "$TMPD/ep" | head -1)
    g=${maior%% *}; gi=$(echo "$maior" | cut -d' ' -f2); gf=$(echo "$maior" | cut -d' ' -f3)
    echo "    - Jobs com sucesso ........: $(wc -l < "$TMPD/fins") ($(awk -F'|' -v s="$sid" '$1==s && $3 ~ /^COMPLETED/{c[$2]++} END{for(k in c) printf "%s%s=%d", (n++?", ":""), k, c[k]}' "$TMPD/bkjobs"))"
    echo "    - Ultimo backup ...........: $(fmt "$ult") (ha $(hms $((AGORA-ult))))"
    for tp in ARCHIVELOG "DB INCR" "DB FULL"; do
      u=$(awk -F'|' -v s="$sid" -v t="$tp" '$1==s && $2==t && $3 ~ /^COMPLETED/{x=$5} END{print x}' "$TMPD/bkjobs")
      [ -n "$u" ] && printf '    - Ultimo %-15s: %s\n' "$tp" "$u"
    done
    echo "    - Intervalo tipico ........: $(hms "${med:-0}") (mediana entre backups)"
    if [ "$gf" = "$AGORA" ]; then
      echo "    - RPO observado (pior caso): $(hms "$g") (desde o ultimo backup ate agora)"
    else
      echo "    - RPO observado (pior caso): $(hms "$g") (sem backup entre $(fmt "$gi") e $(fmt "$gf"))"
    fi
    [ "$lm" = "NOARCHIVELOG" ] && echo "    - NOARCHIVELOG: perda maxima = intervalo entre backups do banco (sem recuperacao ponto no tempo)"
    rf=$(awk -F'|' -v s="$sid" '$1==s && ($2=="DB FULL"||$2=="DB INCR") && $3 ~ /^COMPLETED/ && $6+0>m{m=$6+0; l=$0} END{print l}' "$TMPD/bkjobs")
    [ -n "$rf" ] && echo "    - Referencia indireta de RTO: maior backup de banco levou elapsed_seconds=$(echo "$rf" | cut -d'|' -f6) ($(hms "$(echo "$rf" | cut -d'|' -f6 | cut -d. -f1)"), $(echo "$rf" | cut -d'|' -f2) em $(echo "$rf" | cut -d'|' -f5)); nao e medicao de restore"
    tb=$(tam_db "$sid"); [ -n "$tb" ] && echo "    - Tamanho atual ...........: $tb"
  done
} > "$RR"

#---------------------------- alertas -------------------------------------------
: > "$OUT/alertas.txt"
al(){ echo "$*" >> "$OUT/alertas.txt"; }
if [ "$TOT" -eq 0 ] && [ "$NSCR" -eq 0 ]; then
  al "[SEM EVIDENCIA] Nenhuma rotina ou execucao de clonagem/restauracao encontrada (cron, arquivos em ${#RAIZES[@]} raiz(es) e controlfile de ${#SIDS_OK[@]} banco(s)) nos ultimos $DIAS dias: registrar como risco (a politica exige ao menos 1 teste com sucesso)"
elif [ "$B_OK" -eq 0 ]; then
  al "Nenhuma restauracao A PARTIR DE BACKUP concluida com sucesso nos ultimos $DIAS dias: restaurabilidade dos backups nao comprovada, registrar como risco"
fi
[ "$(cnt 4 ACTIVE_DATABASE)" -gt 0 ] && al "$(cnt 4 ACTIVE_DATABASE) clonagem(ns) via Active Database/FROM SERVICE: nao utilizam backup e NAO contam como teste de restauracao"
[ "$(cnt 4 RESTORE_VALIDATE)" -gt 0 ] && al "$(cnt 4 RESTORE_VALIDATE) execucao(oes) de RESTORE VALIDATE: comprovam leitura dos backups, mas nao substituem teste de restauracao"
[ "$(cnt 6 FALHA)" -gt 0 ] && al "$(cnt 6 FALHA) execucao(oes) com FALHA no periodo: avaliar causa nos extratos"
[ "$(cnt 4 INDETERMINADO)" -gt 0 ] && al "$(cnt 4 INDETERMINADO) execucao(oes) sem metodo identificavel: confirmar manualmente"
[ "$NSCR" -gt 0 ] && [ "$TOT" -eq 0 ] && al "Existem $NSCR rotina(s) de clonagem/restauracao, mas nenhum log ou registro de execucao: nao ha como comprovar que o teste foi executado"
[ ${#DIRS_NEG[@]} -gt 0 ] && al "Diretorios sem permissao de leitura para $(whoami): ${DIRS_NEG[*]} (reexecutar como oracle ou com sudo)"
[ "$NLOGS_T1" -gt "$MAXF" ] && al "Encontrados $NLOGS_T1 logs de clone; analisados os $MAXF mais recentes (WISEDB_CLONE_MAX)"
if [ -n "$ULT_OK" ]; then
  ult_ep=$(to_epoch "$(echo "$ULT_OK" | cut -d'|' -f1 | xargs)")
  [ -n "$ult_ep" ] && [ $(( (AGORA-ult_ep)/86400 )) -gt 90 ] && al "Ultimo teste de restauracao com sucesso tem mais de 90 dias ($(echo "$ULT_OK" | cut -d'|' -f1 | xargs))"
fi
[ -s "$TMPD/timeout" ] && al "Varredura interrompida por tempo limite (${TLIM}s) em: $(paste -sd';' "$TMPD/timeout"). Reexecutar com WISEDB_CLONE_TIMEOUT maior ou informar o diretorio de logs como extra"
[ -s "$OUT/sql_erros.txt" ] && al "Erros ao consultar o controlfile de algumas instancias (ver sql_erros.txt): evidencias de restore dessas instancias podem estar incompletas"
al "RPO e RTO acordados: A DEFINIR com o cliente; valores observados no ambiente em rpo_rto_observado.txt"
{ [ -s "$TMPD/scripts" ] && sort -u "$TMPD/scripts" | cut -d'|' -f4 | tr '\n' '\0' | xargs -0 -r grep -iE 'secret_access_key|aws_secret|password[[:space:]]*=' -l 2>/dev/null; } | head -3 | while read -r f; do
  al "Credencial em texto claro em script de clone: $f (valor mascarado na coleta)"
done

{ echo "## Descoberta de rotinas de clonagem | host $HOSTN | usuario $(whoami) | sudo: $([ -n "$SUDO" ] && echo SIM || echo NAO)"
  echo "## Janela: $DIAS dias | profundidade: $DEPTH | executado em $(date '+%d/%m/%Y %H:%M')"
  echo "Linhas de cron analisadas: $(wc -l < "$TMPD/cron_all") | com rotina de clone: $(grep -c . "$OUT/cron_clone.txt")"
  echo "Raizes varridas por conteudo:"; printf '  - %s\n' ${RAIZES[@]+"${RAIZES[@]}"}
  [ ${#DIRS_NEG[@]} -gt 0 ] && { echo "Diretorios SEM permissao:"; printf '  - %s\n' "${DIRS_NEG[@]}"; }
  echo "Bancos consultados (controlfile): ${SIDS_OK[*]:-nenhum} | sessoes RESTORE/DUPLICATE: $(grep -c . "$TMPD/sessoes_ord")"
  echo "Logs de clone/restore: $NLOGS_T1 | logs de RESTORE VALIDATE: $NLOGS_T2 | analisados: $NLOGS"
  while IFS='|' read -r mt sz dono f; do echo "  $(fmt "$mt") | $sz bytes | $dono | $f"; done < "$TMPD/logs_ord"
  echo "Rotinas (scripts): $NSCR (ver rotinas_descobertas.txt)"
  [ -s "$TMPD/timeout" ] && { echo "Raizes com tempo limite estourado (${TLIM}s):"; sed 's/^/  - /' "$TMPD/timeout"; }
  echo "Descartados por conteudo: $(grep -c . "$OUT/descartados.txt") (ver descartados.txt)"
} > "$OUT/varredura.txt"

{
  echo "========================================================================"
  echo " WISEDB - EVIDENCIAS DE TESTE DE RESTAURACAO (ANEXO I - Registro de testes)"
  echo " Host ........................: $HOSTN"
  echo " Gerado em ...................: $(date '+%d/%m/%Y %H:%M %Z')"
  echo " Janela analisada ............: ultimos $DIAS dias"
  echo " Fontes ......................: cron ($(grep -c . "$OUT/cron_clone.txt") rotina(s)), arquivos ($NLOGS log(s), $NSCR script(s)), controlfile (${SIDS_OK[*]:-nenhum})"
  echo " Execucoes identificadas .....: $TOT"
  echo "   BACKUP_RMAN ...............: $(cnt 4 BACKUP_RMAN)   (valem como teste de restauracao)"
  echo "   DATAPUMP ..................: $(cnt 4 DATAPUMP)   (valem como teste do backup logico)"
  echo "   SQLSERVER .................: $(cnt 4 SQLSERVER)"
  echo "   RESTORE_VALIDATE ..........: $(cnt 4 RESTORE_VALIDATE)   (evidencia parcial)"
  echo "   ACTIVE_DATABASE ...........: $(cnt 4 ACTIVE_DATABASE)   (NAO valem como teste de restauracao)"
  echo "   INDETERMINADO .............: $(cnt 4 INDETERMINADO)"
  echo " Status ......................: SUCESSO $(cnt 6 SUCESSO) | COM ALERTAS $(cnt 6 SUCESSO_COM_ALERTAS) | FALHA $(cnt 6 FALHA) | INCONCLUSIVO $(cnt 6 INCONCLUSIVO)"
  echo " Ultimo teste valido c/ sucesso: ${ULT_OK:-nenhum no periodo}"
  echo "========================================================================"
  echo
  cat "$RR"
  echo
  echo "ROTINAS DE CLONAGEM/RESTAURACAO:"
  if [ "$NSCR" -gt 0 ]; then grep -v '^##' "$OUT/rotinas_descobertas.txt"; else echo "  (nenhuma)"; fi
  echo
  echo "AGENDAMENTOS:"
  if [ -s "$OUT/cron_clone.txt" ]; then sed 's/^/  /' "$OUT/cron_clone.txt"; else echo "  (nenhum agendamento de clone/restore no cron acessivel)"; fi
  echo
  echo "ALERTAS:"
  if [ -s "$OUT/alertas.txt" ]; then sed 's/^/  ! /' "$OUT/alertas.txt"; else echo "  (nenhum)"; fi
  echo
  echo "NOTA PARA A IA: preencher o Anexo I somente com registros BACKUP_RMAN, DATAPUMP ou"
  echo "SQLSERVER. ACTIVE_DATABASE e RESTORE_VALIDATE entram como observacao. RPO/RTO"
  echo "acordados ficam A DEFINIR; os valores observados vao em Observacoes. Campos"
  echo "[A PREENCHER] nao devem ser inventados."
  echo
  cat "$TMPD/blocos"
} | mask > "$OUT/anexo_I_evidencias.txt"

echo "[OK] Evidencias de restauracao: $TOT execucao(oes), $B_OK valida(s) com sucesso, $NSCR rotina(s). Saida: $OUT"
exit 0
