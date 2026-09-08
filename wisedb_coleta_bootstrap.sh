#!/bin/bash
# WiseDB bootstrap resiliente a CA/SSL legados.
set -u
BASE_URL="${WISEDB_BASE_URL:-https://raw.githubusercontent.com/cainawisedb/wisedb-kit/main}"
SCRIPT="${WISEDB_SCRIPT:-wisedb_coleta_auto.sh}"
FALLBACK="${WISEDB_SSL_FALLBACK:-1}"
TMP=$(mktemp "${TMPDIR:-/tmp}/wisedb_bootstrap.XXXXXX") || exit 1
trap 'rm -f "$TMP"' EXIT

if curl -fsSL "$BASE_URL/$SCRIPT" -o "$TMP"; then
  :
elif [ "$FALLBACK" = "1" ] && [ "$?" -eq 60 ]; then
  echo "[WiseDB] CA/certificado nao confiavel; usando fallback SSL (-k) para baixar o script principal." >&2
  curl -k -fsSL "$BASE_URL/$SCRIPT" -o "$TMP" || exit $?
else
  rc=$?
  echo "[WiseDB] Falha ao baixar $BASE_URL/$SCRIPT (curl rc=$rc)." >&2
  exit "$rc"
fi

chmod 700 "$TMP" 2>/dev/null || true
exec bash "$TMP" "$@"
