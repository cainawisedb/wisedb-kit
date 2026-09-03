#!/bin/bash
#===============================================================================
# 99_sanitizar_e_empacotar.sh - WiseDB | Kit de Coleta para Politica de Backup
#
# OBJETIVO : Mascarar possiveis segredos remanescentes nos arquivos coletados
#            e gerar um unico .tar.gz pronto para envio a IA.
# RISCO    : Altera SOMENTE os arquivos dentro da pasta de coleta informada.
# EXECUCAO : bash 99_sanitizar_e_empacotar.sh ./coleta_<host>_<data>
#===============================================================================
set -euo pipefail
DIR="${1:?Uso: $0 <pasta_de_coleta>}"
[ -d "$DIR" ] || { echo "Pasta nao encontrada: $DIR"; exit 1; }

echo "== Sanitizando segredos em $DIR =="
find "$DIR" -type f \( -name "*.txt" -o -name "*.log" -o -name "*.json" \) -print0 |
while IFS= read -r -d '' f; do
  sed -i -E \
    -e 's/((password|passwd|pwd|secret|token|apikey|api_key|client_secret)[[:space:]]*[=:][[:space:]]*)[^[:space:]",]+/\1***REMOVIDO***/Ig' \
    -e 's/(identified[[:space:]]+by[[:space:]]+)[^[:space:];]+/\1***REMOVIDO***/Ig' \
    -e 's#(//[^/:@[:space:]]+:)[^@[:space:]]+(@)#\1***REMOVIDO***\2#g' \
    -e 's#([A-Za-z0-9_.$]+)/[^[:space:]/@"'"'"']{3,}@#\1/***REMOVIDO***@#g' \
    -e 's/(-P[[:space:]]+)[^[:space:]]+/\1***REMOVIDO***/g' \
    "$f"
done

echo "== Verificacao final (ocorrencias remanescentes, revise manualmente) =="
grep -rniE 'password|passwd|secret|token' "$DIR" | grep -v 'REMOVIDO' | head -20 || echo "Nenhuma ocorrencia suspeita."

PACOTE="${DIR%/}_$(date +%H%M%S).tar.gz"
tar -czf "$PACOTE" "$DIR"
echo
echo "Pacote gerado: $PACOTE"
echo "Envie este arquivo (e os complementos nao estruturados) para a IA gerar a politica."
