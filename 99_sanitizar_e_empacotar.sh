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
SEDF=$(mktemp)
cat > "$SEDF" <<'SEDEOF'
s/(([A-Za-z0-9_.-]*(password|passwd|pwd|senha|secret|token|passphrase|pass_phrase|credential|api_?key|access_?key|key_id|keyid|private_?key|key))["']?[[:space:]]*[=:][[:space:]]*)("[^"]*"|'[^']*'|[^[:space:]",;]+)/\1***REMOVIDO***/Ig
s/(--?(password|passwd|pwd|senha|token|secret)[[:space:]]+)("[^"]*"|'[^']*'|[^-[:space:]][^[:space:]]*)/\1***REMOVIDO***/Ig
s/(identified[[:space:]]+by[[:space:]]+)("[^"]*"|[^[:space:];]+)/\1***REMOVIDO***/Ig
s#(//[^/:@[:space:]]+:)[^@[:space:]]+(@)#\1***REMOVIDO***\2#g
s#([A-Za-z0-9_.$]+)/[^[:space:]/@"'*]{2,}@#\1/***REMOVIDO***@#g
s#([A-Za-z0-9_.$]+)/[^[:space:]/@"'*]{2,}([[:space:]]+as[[:space:]]+sys)#\1/***REMOVIDO***\2#Ig
s#((connect|conn)[[:space:]]+((target|auxiliary|catalog)[[:space:]]+)?["']?[A-Za-z0-9_.$]+)/[^[:space:]@"']+#\1/***REMOVIDO***#Ig
s/(sqlcmd[^|;]*[[:space:]]-P[[:space:]]*)("[^"]*"|'[^']*'|[^[:space:]-][^[:space:]]*)/\1***REMOVIDO***/g
s/([[:space:]]-P[[:space:]]+)("[^"]*"|'[^']*'|[^[:space:]-][^[:space:]]*)/\1***REMOVIDO***/g
s/(Bearer[[:space:]]+)[A-Za-z0-9._~+\/=-]{8,}/\1***REMOVIDO***/Ig
s/(AKIA|ASIA)[0-9A-Z]{16}/\1***REMOVIDO***/g
SEDEOF
find "$DIR" -type f \( -name "*.txt" -o -name "*.log" -o -name "*.json" -o -name "*.tsv" -o -name "*.csv" \
     -o -name "*.ora" -o -name "*.sh" -o -name "*.conf" -o -name "*.cfg" \) -print0 |
while IFS= read -r -d '' f; do sed -i -E -f "$SEDF" "$f"; done
rm -f "$SEDF"

echo "== Verificacao final (ocorrencias remanescentes, revise manualmente) =="
SEG_RX='(password|passwd|senha|secret|token|api_?key|access_?key)["'"'"']?[[:space:]]*[=:][[:space:]]*["'"'"']?[^*[:space:]"'"'"']'
if grep -rniIE "$SEG_RX" "$DIR" | grep -v 'REMOVIDO' | head -20 | grep .; then
  echo "ATENCAO: possivel segredo nao mascarado acima. Corrija antes de enviar."
  read -r -p "Gerar o pacote mesmo assim? (s/N) " R </dev/tty 2>/dev/null || R=N
  [ "${R:-N}" = "s" ] || [ "${R:-N}" = "S" ] || { echo "Pacote NAO gerado."; exit 2; }
else
  echo "Nenhuma ocorrencia suspeita."
fi

PACOTE="${DIR%/}_$(date +%H%M%S).tar.gz"
tar -czf "$PACOTE" "$DIR"
echo
echo "Pacote gerado: $PACOTE"
echo "Envie este arquivo (e os complementos nao estruturados) para a IA gerar a politica."
