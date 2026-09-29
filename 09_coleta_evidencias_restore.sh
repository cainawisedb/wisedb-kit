#!/bin/bash
#===============================================================================
# 09_coleta_evidencias_restore.sh - WiseDB | Evidencias de teste de restauracao
#
# OBJETIVO : Varrer os logs e scripts de CLONAGEM do ambiente e transformar cada
#            execucao em um registro no formato do ANEXO I da Politica de Backup.
#            Classifica o metodo de cada clonagem:
#              BACKUP_RMAN      DUPLICATE/RESTORE a partir de backup: e evidencia
#                               valida de teste de restauracao.
#              ACTIVE_DATABASE  DUPLICATE FROM ACTIVE DATABASE: copia a producao
#                               pela rede, NAO usa backup, NAO comprova restore.
#              DATAPUMP         impdp a partir de dump: evidencia do backup logico.
#              SQLSERVER        RESTORE DATABASE a partir de .bak.
#              INDETERMINADO    log sem marcador conclusivo.
# RISCO    : Zero. Somente leitura (find, grep, stat, crontab -l e um SELECT em
#            v$datafile para tamanho do banco, quando o banco e local).
# EXECUCAO : bash 09_coleta_evidencias_restore.sh [dir_extra ...]
#            Variaveis opcionais:
#              WISEDB_CLONE_DIRS="/a:/b"   diretorios extras (separados por ":")
#              WISEDB_CLONE_DAYS=365       janela de busca em dias
#              WISEDB_CLONE_MAX=40         maximo de logs analisados (mais novos)
#              WISEDB_CLONE_DEPTH=5        profundidade do find
#              WISEDB_CLONE_PATTERN="x*"   padrao de nome adicional (-iname)
#              WISEDB_TEMPO_PREVISTO="4h"  tempo previsto (aceita 4h, 90min, 04:30)
#              WISEDB_SUDO=1               usa sudo -n para ler logs de outro dono
# SAIDA    : ./coleta_<hostname>_<data>/09_restore/
#              anexo_I_evidencias.txt   registros prontos no formato do Anexo I
#              execucoes_clone.tsv      uma linha por execucao (estruturado)
#              alertas.txt              achados para a IA classificar como risco
#              varredura.txt            diretorios, arquivos e permissoes
#              cron_clone.txt           agendamentos de clonagem
#              scripts_clone/           scripts de clone (senhas mascaradas)
#              extratos/                linhas-chave de cada log analisado
#
# Versao 1.0 (setembro/2026)
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
DEPTH="${WISEDB_CLONE_DEPTH:-5}"
PREVISTO="${WISEDB_TEMPO_PREVISTO:-}"
AGORA=$(date +%s)

SUDO=""
if [ "${WISEDB_SUDO:-0}" = "1" ] && command -v sudo >/dev/null 2>&1 && sudo -n true 2>/dev/null; then
  SUDO="sudo -n"
fi
TOUT=""; command -v timeout >/dev/null 2>&1 && TOUT="timeout 60"

rd(){ if [ -r "$1" ]; then cat "$1" 2>/dev/null; elif [ -n "$SUDO" ]; then $SUDO cat "$1" 2>/dev/null; fi; }

# Mascara de segredos. Cobre PASSWORD, PWD, SENHA, TOKEN, KEY, SECRET, api_secret,
# sqlcmd -P, user/senha@, user/senha as sysdba e connect target user/senha.
mask(){
  sed -E \
    -e 's/((password|passwd|pwd|senha|token|secret|api_secret|apikey|api_key|client_secret|key)[[:space:]]*[=:][[:space:]]*)[^[:space:]",;]+/\1***REMOVIDO***/Ig' \
    -e 's/(identified[[:space:]]+by[[:space:]]+)[^[:space:];]+/\1***REMOVIDO***/Ig' \
    -e 's#(//[^/:@[:space:]]+:)[^@[:space:]]+(@)#\1***REMOVIDO***\2#g' \
    -e 's#([A-Za-z0-9_.$]+)/[^[:space:]/@"'"'"'*]{2,}@#\1/***REMOVIDO***@#g' \
    -e 's#([A-Za-z0-9_.$]+)/[^[:space:]/@"'"'"'*]{2,}([[:space:]]+as[[:space:]]+sys)#\1/***REMOVIDO***\2#Ig' \
    -e 's#((connect|conn)[[:space:]]+((target|auxiliary|catalog)[[:space:]]+)?["'"'"']?[A-Za-z0-9_.$]+)/[^[:space:]@"'"'"']+#\1/***REMOVIDO***#Ig' \
    -e 's/(sqlcmd.*-P[[:space:]]*)[^[:space:]]+/\1***REMOVIDO***/g' \
    -e 's/(-P[[:space:]]+)[^[:space:]]+/\1***REMOVIDO***/g'
}

#---------------------------- diretorios de busca ------------------------------
declare -a DIRS=(/wisedb/scripts/logs /wisedb/scripts/clone /wisedb/scripts/clones
                 /wisedb/scripts /wisedb/logs /wisedb /home/oracle /opt/wisedb
                 /u01/app/oracle/admin /scripts /dba "$HOME")
if [ -n "${WISEDB_CLONE_DIRS:-}" ]; then
  IFS=':' read -r -a _ext <<< "$WISEDB_CLONE_DIRS"
  DIRS+=(${_ext[@]+"${_ext[@]}"})
fi
[ $# -gt 0 ] && DIRS+=("$@")

#---------------------------- agendamentos de clone ----------------------------
{
  for u in "$(whoami)" oracle root grid; do
    if [ "$u" = "$(whoami)" ]; then c=$(crontab -l 2>/dev/null)
    elif [ -n "$SUDO" ]; then c=$($SUDO crontab -l -u "$u" 2>/dev/null)
    else c=$(crontab -l -u "$u" 2>/dev/null); fi
    [ -n "$c" ] && printf '%s\n' "$c" | grep -Ev '^[[:space:]]*#' | grep -iE 'clon|duplic|refresh' | sed "s|^|$u: |"
  done
  for f in /etc/crontab /etc/cron.d/*; do
    [ -f "$f" ] || continue
    rd "$f" | grep -Ev '^[[:space:]]*#' | grep -iE 'clon|duplic|refresh' | sed "s|^|$(basename "$f"): |"
  done
} 2>/dev/null | sort -u | mask > "$OUT/cron_clone.txt"

# Diretorios citados nos agendamentos (script e destino do redirecionamento)
while read -r p; do
  [ -z "$p" ] && continue
  DIRS+=("$(dirname "$p")")
done < <(grep -oE '/[A-Za-z0-9._/${}-]{3,}' "$OUT/cron_clone.txt" 2>/dev/null | grep -v '\$' | sort -u)

# Normaliza e deduplica os diretorios existentes
declare -a DIRS_OK=() DIRS_NEG=()
for d in $(printf '%s\n' "${DIRS[@]}" | sed 's:/*$::' | grep -v '^$' | sort -u); do
  if [ -d "$d" ] && [ -r "$d" ] && [ -x "$d" ]; then DIRS_OK+=("$d")
  elif [ -n "$SUDO" ] && $SUDO test -d "$d" 2>/dev/null; then DIRS_OK+=("$d")
  elif [ -d "$d" ]; then DIRS_NEG+=("$d")
  fi
done

#---------------------------- descoberta de arquivos ---------------------------
PAT_EXTRA=()
[ -n "${WISEDB_CLONE_PATTERN:-}" ] && PAT_EXTRA=(-o -iname "$WISEDB_CLONE_PATTERN")
: > "$TMPD/cand"
for d in ${DIRS_OK[@]+"${DIRS_OK[@]}"}; do
  # Por nome: Clone*, clonagem, duplicate, refresh (sem diferenciar maiusculas)
  $SUDO find "$d" -maxdepth "$DEPTH" -type f \
    \( -iname '*clon*' -o -iname '*duplic*' -o -iname '*refresh*' ${PAT_EXTRA[@]+"${PAT_EXTRA[@]}"} \) \
    -mtime -"$DIAS" -size -200M 2>/dev/null >> "$TMPD/cand"
  # Por conteudo, em diretorios de log, para pegar clone com nome fora do padrao
  case "$d" in *log*|*clone*|*clon*)
    $SUDO find "$d" -maxdepth 2 -type f -mtime -"$DIAS" -size -200M 2>/dev/null |
      while read -r f; do
        rd "$f" | grep -qiE 'duplicate[[:space:]]+(target[[:space:]]+)?database|from active database|Starting Duplicate Db' && echo "$f"
      done >> "$TMPD/cand";;
  esac
done
sort -u "$TMPD/cand" | grep -vE '/wisedb_coleta_|/09_restore/|\.(gz|zip|bz2|xz|tar|dmp|bkp|bak|dbf|arc|trc|trm)$' > "$TMPD/cand2"

: > "$TMPD/logs"; : > "$TMPD/scripts"
while read -r f; do
  [ -z "$f" ] && continue
  rd "$f" | head -c 65536 | grep -qI . || continue          # descarta binario/vazio
  st=$( { stat -c '%Y|%s|%U' "$f" 2>/dev/null || $SUDO stat -c '%Y|%s|%U' "$f" 2>/dev/null; } )
  [ -z "$st" ] && continue
  if echo "$f" | grep -qiE '\.(sh|ksh|bash|rman|rcv|sql|cmd|py|par|ctl|cfg|conf|env)$' || \
     rd "$f" | head -1 | grep -q '^#!'; then
    echo "$st|$f" >> "$TMPD/scripts"
  else
    echo "$st|$f" >> "$TMPD/logs"
  fi
done < "$TMPD/cand2"
sort -t'|' -k1,1nr "$TMPD/logs" > "$TMPD/logs_ord"
NLOGS=$(wc -l < "$TMPD/logs_ord"); NSCR=$(wc -l < "$TMPD/scripts")

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
RX_INI='Starting (Duplicate Db|restore|recover)|Import: Release|^In[ií]cio|^Inicio|^Start'
RX_FIM='Finished (Duplicate Db|recover|restore)|Duplicate Db complete|job .*(successfully )?completed|completed with [0-9]+ error|successfully processed|^Fim|^Termino|^T[eé]rmino|^End'
ts_de(){ grep -oE "$RX_TS" | while read -r t; do to_epoch "$t" && break; done | head -1; }
primeiro_ts(){ local e; e=$(grep -iE "$RX_INI" "$1" | ts_de); [ -z "$e" ] && e=$(grep -oE "$RX_TS" "$1" | head -8 | ts_de); echo "$e"; }
ultimo_ts(){ local e; e=$(grep -iE "$RX_FIM" "$1" | tac | ts_de); [ -z "$e" ] && e=$(grep -oE "$RX_TS" "$1" | tail -8 | tac | ts_de); echo "$e"; }
fmt(){ [ -n "$1" ] && date -d "@$1" '+%d/%m/%Y %H:%M:%S'; }
fmt_or(){ if [ -n "$1" ]; then fmt "$1"; else echo "$2"; fi; }
hms(){ local s=$1; printf '%02d:%02d:%02d' $((s/3600)) $(((s%3600)/60)) $((s%60)); }
prev_seg(){ # 4h | 90min | 04:30 | 2h30 -> segundos
  local p; p=$(echo "$1" | tr '[:upper:]' '[:lower:]' | tr -d ' ')
  if [[ "$p" =~ ^([0-9]+):([0-9]{2})$ ]]; then echo $(( ${BASH_REMATCH[1]}*3600 + 10#${BASH_REMATCH[2]}*60 ))
  elif [[ "$p" =~ ^([0-9]+)h([0-9]+)(m|min)?$ ]]; then echo $(( ${BASH_REMATCH[1]}*3600 + ${BASH_REMATCH[2]}*60 ))
  elif [[ "$p" =~ ^([0-9]+)(h|hs|hora|horas)$ ]]; then echo $(( ${BASH_REMATCH[1]}*3600 ))
  elif [[ "$p" =~ ^([0-9]+)(m|min|minutos)$ ]]; then echo $(( ${BASH_REMATCH[1]}*60 ))
  fi
}
PREV_S=$(prev_seg "$PREVISTO")

# Tamanho atual de um banco local (v$datafile). Valor exibido como retornado.
declare -A TAM_CACHE=()
tam_db(){
  local n="$1" sid home r
  [ -z "$n" ] && return
  [ -n "${TAM_CACHE[$n]+x}" ] && { echo "${TAM_CACHE[$n]}"; return; }
  sid=$(ps -eo args 2>/dev/null | grep -o 'ora_pmon_[A-Za-z0-9_]*' | sed 's/ora_pmon_//' | grep -ix "$n" | head -1)
  home=""
  [ -n "$sid" ] && home=$(awk -F: -v s="$sid" '$1==s{print $2; exit}' /etc/oratab 2>/dev/null)
  if [ -n "$sid" ] && [ -n "$home" ] && [ -x "$home/bin/sqlplus" ]; then
    r=$(ORACLE_SID="$sid" ORACLE_HOME="$home" $TOUT "$home/bin/sqlplus" -s -L / as sysdba <<'SQL_EOF' 2>/dev/null | grep -E '^[[:space:]]*[0-9.,]+[[:space:]]*$' | head -1 | tr -d ' '
set heading off feedback off pagesize 0 linesize 200
select sum(bytes)/1024/1024/1024 from v$datafile;
exit
SQL_EOF
)
    [ -n "$r" ] && r="$r GB (v\$datafile atual de $sid, consultado em $(date '+%d/%m/%Y %H:%M'))"
  fi
  TAM_CACHE[$n]="${r:-}"
  echo "${r:-}"
}

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

#---------------------------- analise de cada execucao -------------------------
TSV="$OUT/execucoes_clone.tsv"
printf 'id\tarquivo\tsegmento\tmetodo\tevidencia_de_backup\tstatus\torigem\tdestino\tinicio\tfim\tfonte_do_tempo\tduracao_seg\tduracao\tbackup_location\ttags_backup\tdata_backup_usado\tpecas_lidas\tuntil\terros\tdono\tmtime\n' > "$TSV"
ID=0
: > "$TMPD/blocos"

analisa(){ # seg arquivo idx nsegs mtime dono
  local seg="$1" arq="$2" idx="$3" nseg="$4" mt="$5" dono="$6"
  local met status ori dst ini fim fonte dur durh loc tags tmin tmax dbk pec unt err toperr ev efet dentro
  if grep -qiE 'from active database|using network backup set|from service |backup as copy reuse' "$seg"; then met="ACTIVE_DATABASE"
  elif grep -qiE 'reading from backup piece|piece handle=|backup location|restored backup piece|restore clone (primary )?(database|controlfile)|restore (database|controlfile)' "$seg"; then met="BACKUP_RMAN"
  elif grep -qiE 'Import: Release|impdp|dumpfile=' "$seg"; then met="DATAPUMP"
  elif grep -qiE 'RESTORE (DATABASE|LOG).*(successfully|processed)|FROM[[:space:]]+(DISK|URL)[[:space:]]*=' "$seg"; then met="SQLSERVER"
  else met="INDETERMINADO"; fi
  [ "$nseg" -gt 1 ] && [ "$met" = "INDETERMINADO" ] && return 0

  if grep -qiE 'RMAN-03002|RMAN-03009|failure of (duplicate|restore|recover)|RMAN-05501|RMAN-06054|RMAN-06026|job "[^"]*" (stopped|terminated)|terminating abnormally|ORA-01547|ORA-01194' "$seg"; then status="FALHA"
  elif grep -qiE 'completed with [1-9][0-9]* error' "$seg"; then status="SUCESSO_COM_ALERTAS"
  elif grep -qiE 'Finished Duplicate Db|Finished (restore|recover)|media recovery complete|database opened|successfully completed|successfully processed|Duplicate Db complete' "$seg"; then status="SUCESSO"
  else status="INCONCLUSIVO"; fi

  ori=$(grep -oiE 'connected to target database: [A-Za-z0-9_$#]+' "$seg" | head -1 | awk '{print $NF}')
  [ -z "$ori" ] && ori=$(grep -oiE 'duplicate[[:space:]]+database[[:space:]]+["'"'"']?[A-Za-z0-9_]+' "$seg" | grep -viE 'duplicate[[:space:]]+database[[:space:]]+to' | head -1 | awk '{print $NF}' | tr -d "\"'")
  dst=$(grep -oiE 'connected to auxiliary database: [A-Za-z0-9_$#]+' "$seg" | head -1 | awk '{print $NF}')
  [ -z "$dst" ] && dst=$(grep -oiE 'duplicate[^;]*[[:space:]]to[[:space:]]+["'"'"']?[A-Za-z0-9_]+' "$seg" | head -1 | awk '{print $NF}' | tr -d "\"'")
  [ -z "$dst" ] && [ "$met" = "SQLSERVER" ] && dst=$(grep -oiE 'RESTORE DATABASE[[:space:]]+\[?[A-Za-z0-9_]+' "$seg" | head -1 | awk '{print $NF}' | tr -d '[')
  ori=$(echo "$ori" | tr '[:lower:]' '[:upper:]'); dst=$(echo "$dst" | tr '[:lower:]' '[:upper:]')

  ini=$(primeiro_ts "$seg"); fim=$(ultimo_ts "$seg"); fonte="log"
  # mtime so substitui o fim quando o log nao tem horario de termino e o arquivo
  # foi fechado ate 48h depois do inicio; fora disso a duracao seria ficticia.
  if [ -z "$fim" ] && [ -n "$ini" ] && [ "$idx" = "$nseg" ] && [ "$mt" -gt "$ini" ] && [ $((mt-ini)) -le 172800 ]; then
    fim="$mt"; fonte="inicio: log | fim: mtime do arquivo"
  fi
  if [ -n "$ini" ] && [ -n "$fim" ] && [ "$fim" -le "$ini" ]; then fonte="timestamps inconsistentes no log"; fi
  [ -z "$ini" ] && fonte="inicio nao identificado no log"
  dur=""; durh=""
  if [ -n "$ini" ] && [ -n "$fim" ] && [ "$fim" -gt "$ini" ]; then dur=$((fim-ini)); durh=$(hms "$dur"); fi

  loc=$(grep -oiE "backup location[[:space:]]*['\"][^'\"]+" "$seg" | head -1 | sed -E "s/^[^'\"]*['\"]//")
  tags=$(grep -oE 'TAG[0-9]{8}T[0-9]{6}' "$seg" | sort -u)
  tmin=$(echo "$tags" | grep . | head -1); tmax=$(echo "$tags" | grep . | tail -1)
  dbk=""
  [ -n "$tmax" ] && dbk=$(echo "$tmax" | sed -E 's/TAG([0-9]{4})([0-9]{2})([0-9]{2})T([0-9]{2})([0-9]{2}).*/\3\/\2\/\1 \4:\5/')
  pec=$(grep -ciE 'reading from backup piece|piece handle=' "$seg")
  unt=$(grep -oiE "until[[:space:]]+(time|scn|sequence)[^;)]*" "$seg" | head -1 | tr -s ' ')
  err=$(grep -oE '(ORA|RMAN)-[0-9]{5}' "$seg" | grep -vE 'RMAN-(00569|00571|07554)' | wc -l)
  toperr=$(grep -oE '(ORA|RMAN)-[0-9]{5}' "$seg" | grep -vE 'RMAN-(00569|00571|07554)' | sort | uniq -c | sort -rn | head -4 | awk '{printf "%s%s(%s)", (NR>1?", ":""), $2, $1}')
  local dpn dmp
  dpn=$(grep -oiE 'completed with [0-9]+ error' "$seg" | tail -1 | grep -oE '[0-9]+')
  [ -n "$dpn" ] && [ "$dpn" -gt "$err" ] && err="$dpn"
  dmp=$(grep -oiE 'dumpfile=[^[:space:]]+' "$seg" | head -1 | cut -d= -f2-)

  ID=$((ID+1))
  printf '%s\t%s\t%s/%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$ID" "$arq" "$idx" "$nseg" "$met" \
    "$(case $met in BACKUP_RMAN|DATAPUMP|SQLSERVER) echo SIM;; ACTIVE_DATABASE) echo NAO;; *) echo INDETERMINADO;; esac)" \
    "$status" "${ori:-}" "${dst:-}" "$(fmt "$ini")" "$(fmt "$fim")" "$fonte" "${dur:-}" "${durh:-}" \
    "${loc:-${dmp:-}}" "${tmin:+$tmin..$tmax}" "${dbk:-}" "$pec" "${unt:-}" "$err" "$dono" "$(fmt "$mt")" >> "$TSV"

  # Extrato das linhas-chave, para auditoria sem expor o log inteiro
  { echo "## Extrato #$ID | $arq | segmento $idx/$nseg | metodo $met | status $status"
    grep -niE 'connected to|duplicate|active database|backup location|until|Starting|Finished|piece handle|reading from backup piece|media recovery|database opened|ORA-[0-9]{5}|RMAN-0[0-9]{4}|Import: Release|job .*completed|RESTORE (DATABASE|LOG)|successfully|error' "$seg" |
      grep -vE 'RMAN-0(0569|0571)' | head -80
  } | mask > "$OUT/extratos/extrato_$(printf '%03d' "$ID").txt"

  # Proxima execucao: agendamento que cita o destino ou o prefixo do log
  local cr="" nx="" pref
  pref=$(basename "$arq" | sed -E 's/[._-]?[0-9]{6,}.*//; s/\.[A-Za-z]+$//')
  if [ -s "$OUT/cron_clone.txt" ]; then
    if [ "$(grep -c . "$OUT/cron_clone.txt")" = "1" ]; then cr=$(head -1 "$OUT/cron_clone.txt")
    else
      [ -n "$dst" ] && cr=$(grep -i "$dst" "$OUT/cron_clone.txt" | head -1)
      [ -z "$cr" ] && [ ${#pref} -ge 4 ] && cr=$(grep -iF "$pref" "$OUT/cron_clone.txt" | head -1)
    fi
    if [ -n "$cr" ]; then
      local expr; expr=$(echo "$cr" | sed -E 's/^[^:]+: //' | awk '{print $1,$2,$3,$4,$5}')
      echo "$expr" | grep -qE '^[0-9*,/-]+ [0-9*,/-]+ [0-9*,/-]+ [0-9*,/-]+ [0-9*,/-]+$' && nx=$(proxima_cron "$expr")
    fi
  fi

  case "$met" in
    BACKUP_RMAN|DATAPUMP|SQLSERVER)
      case "$status" in
        SUCESSO) efet="Sim. Restauracao a partir de backup concluida com sucesso";;
        SUCESSO_COM_ALERTAS) efet="Sim, com ressalvas. Concluida com $err erro(s) registrados no log";;
        FALHA) efet="Nao. Execucao falhou ($toperr)";;
        *) efet="Nao comprovado. Log sem marcador de conclusao";;
      esac;;
    ACTIVE_DATABASE) efet="Nao se aplica. DUPLICATE FROM ACTIVE DATABASE copia a producao pela rede e nao utiliza os backups: nao comprova restaurabilidade";;
    *) efet="Nao comprovado. Metodo nao identificado no log";;
  esac
  dentro="Nao avaliavel (tempo previsto nao informado)"
  if [ -n "$PREV_S" ] && [ -n "$dur" ]; then
    [ "$dur" -le "$PREV_S" ] && dentro="Sim ($durh <= $PREVISTO)" || dentro="Nao ($durh > $PREVISTO)"
  elif [ -n "$PREV_S" ]; then dentro="Nao avaliavel (duracao nao mensuravel pelo log)"; fi

  local tori tdst
  tori=$(tam_db "$ori"); tdst=$(tam_db "$dst")
  {
    echo "------------------------------------------------------------------------"
    echo " REGISTRO DE TESTE #$ID   metodo: $met   status: $status"
    echo "------------------------------------------------------------------------"
    echo " Servico de negocio ..............: [A PREENCHER] sistema que utiliza ${ori:-o banco de origem}"
    case "$met" in
      SQLSERVER) echo " Servico de TI ...................: SQL Server | restore de ${ori:-origem nao identificada} em ${dst:-destino nao identificado}";;
      DATAPUMP)  echo " Servico de TI ...................: Oracle Data Pump | importacao em ${dst:-destino nao identificado}";;
      *)         echo " Servico de TI ...................: Oracle Database | clonagem ${ori:-origem nao identificada} -> ${dst:-destino nao identificado}";;
    esac
    echo " Responsavel pela execucao .......: WiseDB (rotina de clonagem, dono do log: $dono)"
    echo " Responsavel pela validacao ......: [A PREENCHER]"
    echo " Tamanho na origem ...............: ${tori:-[A PREENCHER] origem nao e local a este host; obter na coleta da producao}"
    echo " Tamanho no destino ..............: ${tdst:-[A PREENCHER] banco de destino nao esta ativo neste host}"
    echo " Tempo total previsto ............: ${PREVISTO:-[A DEFINIR] usar o RTO da politica}"
    echo " Data/Hora inicio ................: $(fmt_or "$ini" "nao identificado no log")"
    echo " Data/Hora fim ...................: $(fmt_or "$fim" "nao identificado no log")"
    echo " Tempo total real ................: ${durh:-nao mensuravel pelo log}${dur:+ ($fonte)}"
    echo " Dentro do tempo previsto ........: $dentro"
    echo " Teste efetivo (Sim/Nao) .........: $efet"
    if [ -n "$nx" ]; then echo " Data do proximo teste ...........: $nx (proxima execucao do agendamento abaixo)"
    else echo " Data do proximo teste ...........: [A DEFINIR] nenhum agendamento de clone associado"; fi
    echo " Observacoes .....................:"
    [ "$met" = "BACKUP_RMAN" ] && echo "   - Backup utilizado: ${loc:+location $loc; }${tmin:+tags $tmin..$tmax; }${dbk:+backup mais recente de $dbk; }$pec leitura(s) de backup piece"
    [ -n "$dmp" ] && echo "   - Dump utilizado: $dmp"
    [ -n "$unt" ] && echo "   - Ponto de recuperacao: $unt"
    echo "   - Erros ORA/RMAN no log: $err${toperr:+ ($toperr)}"
    [ -n "$cr" ] && echo "   - Agendamento: $cr"
    echo "   - Evidencia: $arq (segmento $idx/$nseg, modificado em $(fmt "$mt")); extrato_$(printf '%03d' "$ID").txt"
    echo
  } >> "$TMPD/blocos"
}

n=0
while IFS='|' read -r mt sz dono f; do
  [ -z "$f" ] && continue
  n=$((n+1)); [ "$n" -gt "$MAXF" ] && break
  rd "$f" > "$TMPD/log_atual"
  ndup=$(grep -ciE 'Starting Duplicate Db|Import: Release' "$TMPD/log_atual")
  rm -f "$TMPD"/seg_*
  if [ "$ndup" -gt 1 ] && grep -q 'Recovery Manager: Release\|Import: Release' "$TMPD/log_atual"; then
    awk -v o="$TMPD/seg_" '/Recovery Manager: Release|Import: Release/{ if (seen) n++; seen=1 } { printf "%s\n", $0 > (o sprintf("%04d", n+1)) }' "$TMPD/log_atual"
  else
    cp "$TMPD/log_atual" "$TMPD/seg_0001"
  fi
  segs=$(ls -1 "$TMPD"/seg_* 2>/dev/null | wc -l); i=0
  for s in $(ls -1 "$TMPD"/seg_* 2>/dev/null); do
    i=$((i+1)); analisa "$s" "$f" "$i" "$segs" "$mt" "$dono"
  done
done < "$TMPD/logs_ord"

#---------------------------- scripts de clonagem ------------------------------
{
  echo "## Scripts de clonagem encontrados (senhas mascaradas)"
  while IFS='|' read -r mt sz dono f; do
    [ -z "$f" ] && continue
    m="INDETERMINADO"
    if rd "$f" | grep -qiE 'from active database'; then m="ACTIVE_DATABASE"
    elif rd "$f" | grep -qiE 'backup location|restore (clone )?(database|controlfile)|duplicate[^;]*database'; then m="BACKUP_RMAN"
    elif rd "$f" | grep -qiE 'impdp'; then m="DATAPUMP"; fi
    ag="nao"; grep -qF "$(basename "$f")" "$OUT/cron_clone.txt" 2>/dev/null && ag="sim"
    echo "  $(fmt "$mt") | $m | agendado no cron: $ag | $dono | $f"
    dest="$OUT/scripts_clone/$(echo "${f#/}" | tr '/' '_').txt"
    rd "$f" | head -c 204800 | mask > "$dest"
  done < <(sort -t'|' -k1,1nr "$TMPD/scripts")
} > "$OUT/scripts_clone/indice.txt"

#---------------------------- consolidacao -------------------------------------
cnt(){ awk -F'\t' -v c="$1" -v v="$2" 'NR>1 && $c==v' "$TSV" | wc -l; }
TOT=$(( $(wc -l < "$TSV") - 1 ))
B_OK=$(awk -F'\t' 'NR>1 && $5=="SIM" && ($6=="SUCESSO"||$6=="SUCESSO_COM_ALERTAS")' "$TSV" | wc -l)
ULT_OK=$(awk -F'\t' 'NR>1 && $5=="SIM" && ($6=="SUCESSO"||$6=="SUCESSO_COM_ALERTAS"){print $10" | "$4" | "$7" -> "$8}' "$TSV" |
         awk -F' ' '{split($1,d,"/"); print d[3] d[2] d[1] " " $0}' | sort -r | head -1 | cut -d' ' -f2-)

: > "$OUT/alertas.txt"
al(){ echo "$*" >> "$OUT/alertas.txt"; }
if [ "$NLOGS" -eq 0 ] && [ "$NSCR" -eq 0 ]; then
  al "[SEM EVIDENCIA] Nenhum log ou script de clonagem encontrado nos ultimos $DIAS dias nos diretorios varridos. Sem historico de teste de restauracao: registrar como risco (a politica exige ao menos 1 teste com sucesso)"
elif [ "$B_OK" -eq 0 ]; then
  al "Nenhuma restauracao A PARTIR DE BACKUP concluida com sucesso nos ultimos $DIAS dias: restaurabilidade dos backups nao comprovada, registrar como risco"
fi
[ "$(cnt 4 ACTIVE_DATABASE)" -gt 0 ] && al "$(cnt 4 ACTIVE_DATABASE) clonagem(ns) via DUPLICATE FROM ACTIVE DATABASE: nao utilizam backup e NAO contam como teste de restauracao"
[ "$(cnt 6 FALHA)" -gt 0 ] && al "$(cnt 6 FALHA) execucao(oes) de clonagem com FALHA no periodo: avaliar causa nos extratos"
[ "$(cnt 4 INDETERMINADO)" -gt 0 ] && al "$(cnt 4 INDETERMINADO) log(s) de clone sem metodo identificavel: confirmar manualmente se foi a partir de backup"
[ "$NSCR" -gt 0 ] && [ "$NLOGS" -eq 0 ] && al "Existem $NSCR script(s) de clonagem, mas nenhum log de execucao: nao ha como comprovar que o teste foi executado"
[ ${#DIRS_NEG[@]} -gt 0 ] && al "Diretorios sem permissao de leitura para $(whoami): ${DIRS_NEG[*]} (reexecutar como oracle ou com sudo)"
[ "$(wc -l < "$TMPD/logs_ord")" -gt "$MAXF" ] && al "Foram encontrados $(wc -l < "$TMPD/logs_ord") logs; analisados apenas os $MAXF mais recentes (WISEDB_CLONE_MAX)"
if [ -n "$ULT_OK" ]; then
  ult_ep=$(to_epoch "$(echo "$ULT_OK" | cut -d'|' -f1 | xargs)")
  [ -n "$ult_ep" ] && [ $(( (AGORA-ult_ep)/86400 )) -gt 90 ] && al "Ultimo teste de restauracao a partir de backup com sucesso tem mais de 90 dias ($(echo "$ULT_OK" | cut -d'|' -f1 | xargs))"
fi

{ echo "## Varredura de evidencias de clonagem | host $HOSTN | usuario $(whoami) | sudo: $([ -n "$SUDO" ] && echo SIM || echo NAO)"
  echo "## Janela: $DIAS dias | profundidade: $DEPTH | limite de logs: $MAXF | executado em $(date '+%d/%m/%Y %H:%M')"
  echo "Diretorios varridos:"; printf '  - %s\n' ${DIRS_OK[@]+"${DIRS_OK[@]}"}
  [ ${#DIRS_NEG[@]} -gt 0 ] && { echo "Diretorios SEM permissao:"; printf '  - %s\n' "${DIRS_NEG[@]}"; }
  echo "Logs encontrados ($NLOGS):"
  while IFS='|' read -r mt sz dono f; do echo "  $(fmt "$mt") | $sz bytes | $dono | $f"; done < "$TMPD/logs_ord"
  echo "Scripts encontrados ($NSCR): ver scripts_clone/indice.txt"
} > "$OUT/varredura.txt"

{
  echo "========================================================================"
  echo " WISEDB - EVIDENCIAS DE TESTE DE RESTAURACAO (ANEXO I - Registro de testes)"
  echo " Host ........................: $HOSTN"
  echo " Gerado em ...................: $(date '+%d/%m/%Y %H:%M %Z')"
  echo " Janela analisada ............: ultimos $DIAS dias"
  echo " Logs de clone analisados ....: $NLOGS (limite $MAXF) | scripts: $NSCR"
  echo " Execucoes identificadas .....: $TOT"
  echo "   BACKUP_RMAN ...............: $(cnt 4 BACKUP_RMAN)   (valem como teste de restauracao)"
  echo "   DATAPUMP ..................: $(cnt 4 DATAPUMP)   (valem como teste do backup logico)"
  echo "   SQLSERVER .................: $(cnt 4 SQLSERVER)"
  echo "   ACTIVE_DATABASE ...........: $(cnt 4 ACTIVE_DATABASE)   (NAO valem como teste de restauracao)"
  echo "   INDETERMINADO .............: $(cnt 4 INDETERMINADO)"
  echo " Status ......................: SUCESSO $(cnt 6 SUCESSO) | COM ALERTAS $(cnt 6 SUCESSO_COM_ALERTAS) | FALHA $(cnt 6 FALHA) | INCONCLUSIVO $(cnt 6 INCONCLUSIVO)"
  echo " Ultimo teste valido c/ sucesso: ${ULT_OK:-nenhum no periodo}"
  echo "========================================================================"
  echo
  echo "AGENDAMENTOS DE CLONAGEM:"
  if [ -s "$OUT/cron_clone.txt" ]; then sed 's/^/  /' "$OUT/cron_clone.txt"; else echo "  (nenhum agendamento de clone no cron acessivel)"; fi
  echo
  echo "ALERTAS:"
  if [ -s "$OUT/alertas.txt" ]; then sed 's/^/  ! /' "$OUT/alertas.txt"; else echo "  (nenhum)"; fi
  echo
  echo "NOTA PARA A IA: preencher o Anexo I somente com registros de metodo BACKUP_RMAN,"
  echo "DATAPUMP ou SQLSERVER. Registros ACTIVE_DATABASE entram apenas como observacao,"
  echo "nunca como teste de restauracao. Campos [A PREENCHER] nao devem ser inventados."
  echo
  cat "$TMPD/blocos"
} | mask > "$OUT/anexo_I_evidencias.txt"

echo "[OK] Evidencias de restauracao: $TOT execucao(oes), $B_OK valida(s) com sucesso. Saida: $OUT"
exit 0
