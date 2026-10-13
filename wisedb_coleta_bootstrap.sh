#!/bin/bash
# WiseDB bootstrap resiliente a CA/SSL legados (v1.1).
# v1.1: o fallback -k nunca disparava (o $? lido era o do teste anterior).
set -u
BASE_URL="${WISEDB_BASE_URL:-https://raw.githubusercontent.com/cainawisedb/wisedb-kit/main}"
SCRIPT="${WISEDB_SCRIPT:-wisedb_coleta_auto.sh}"
FALLBACK="${WISEDB_SSL_FALLBACK:-1}"
TMP=$(mktemp "${TMPDIR:-/tmp}/wisedb_bootstrap.XXXXXX") || exit 1
trap 'rm -f "$TMP"' EXIT

curl -fsSL "$BASE_URL/$SCRIPT" -o "$TMP"; rc=$?
if [ "$rc" -eq 60 ] && [ "$FALLBACK" = "1" ]; then
  echo "[WiseDB] CA/certificado nao confiavel (curl 60); usando fallback SSL (-k) para baixar o script principal." >&2
  curl -k -fsSL "$BASE_URL/$SCRIPT" -o "$TMP"; rc=$?
fi
if [ "$rc" -ne 0 ]; then
  echo "[WiseDB] Falha ao baixar $BASE_URL/$SCRIPT (curl rc=$rc)." >&2
  exit "$rc"
fi
chmod 700 "$TMP" 2>/dev/null || true
bash "$TMP" "$@"
