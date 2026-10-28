#!/bin/bash
# WiseDB bootstrap resiliente (v1.2).
# v1.2: teto de tempo no download (rede que descarta pacotes travava o curl),
#       repassa WISEDB_BASE_URL ao orquestrador (antes ele caia no placeholder)
#       e, se o GitHub nao responder, roda a copia local do kit quando existir.
# v1.1: o fallback -k nunca disparava (o $? lido era o do teste anterior).
set -u
BASE_URL="${WISEDB_BASE_URL:-https://raw.githubusercontent.com/cainawisedb/wisedb-kit/main}"
SCRIPT="${WISEDB_SCRIPT:-wisedb_coleta_auto.sh}"
FALLBACK="${WISEDB_SSL_FALLBACK:-1}"
CTO="${WISEDB_CONNECT_TIMEOUT:-8}"
MTO="${WISEDB_DL_TIMEOUT:-60}"
export WISEDB_BASE_URL="$BASE_URL" WISEDB_SSL_FALLBACK="$FALLBACK"

# Copia local do kit: WISEDB_KIT_DIR, pasta deste bootstrap, pasta atual ou ./kit_coleta_backup
kit_local(){
  local self_dir="" c
  [ -f "${BASH_SOURCE[0]:-}" ] && self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" 2>/dev/null && pwd)"
  for c in "${WISEDB_KIT_DIR:-}" "$self_dir" "$(pwd)" "$(pwd)/kit_coleta_backup"; do
    [ -n "$c" ] && [ -f "$c/$SCRIPT" ] && [ -f "$c/01_coleta_linux_geral.sh" ] && { echo "$c"; return 0; }
  done
  return 1
}
roda_local(){
  local k
  if k=$(kit_local); then
    echo "[WiseDB] Usando a copia local do kit em $k (modo local, sem rede)." >&2
    WISEDB_ORIGEM=LOCAL WISEDB_KIT_DIR="$k" exec bash "$k/$SCRIPT" "$@"
  fi
  echo "[WiseDB] Nao ha copia local do kit. Leve a pasta completa do kit para o servidor e rode:" >&2
  echo "[WiseDB]   cd <pasta_do_kit> && bash $SCRIPT" >&2
  exit 1
}

baixa(){ # baixa [-k] destino
  local k=""; [ "${1:-}" = "-k" ] && { k="-k"; shift; }
  if command -v timeout >/dev/null 2>&1; then
    timeout -k 5 $((MTO+10)) curl $k -fsSL --connect-timeout "$CTO" -m "$MTO" "$BASE_URL/$SCRIPT" -o "$1"
  else
    curl $k -fsSL --connect-timeout "$CTO" -m "$MTO" "$BASE_URL/$SCRIPT" -o "$1"
  fi
}

if [ "${WISEDB_OFFLINE:-0}" = "1" ]; then roda_local "$@"; fi
command -v curl >/dev/null 2>&1 || { echo "[WiseDB] curl ausente neste host." >&2; roda_local "$@"; }

TMP=$(mktemp "${TMPDIR:-/tmp}/wisedb_bootstrap.XXXXXX") || exit 1
trap 'rm -f "$TMP"' EXIT
echo "[WiseDB] Baixando $SCRIPT de $BASE_URL (no maximo ${MTO}s)..." >&2
baixa "$TMP"; rc=$?
if [ "$rc" -eq 60 ] && [ "$FALLBACK" = "1" ]; then
  echo "[WiseDB] CA/certificado nao confiavel (curl 60); usando fallback SSL (-k) para baixar o script principal." >&2
  baixa -k "$TMP"; rc=$?
fi
if [ "$rc" -ne 0 ] || [ ! -s "$TMP" ]; then
  echo "[WiseDB] Falha ao baixar $BASE_URL/$SCRIPT (rc=$rc)." >&2
  roda_local "$@"
fi
chmod 700 "$TMP" 2>/dev/null || true
WISEDB_ORIGEM=GITHUB bash "$TMP" "$@"
