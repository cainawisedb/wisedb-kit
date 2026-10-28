#!/bin/bash
#===============================================================================
# gerar_colagem_senhasegura.sh - WiseDB | wisedb-kit
# v1.0 (outubro/2026)
#
# Gera um TEXTO para colar no terminal do servidor quando nao ha internet nem
# transferencia de arquivo (senhasegura/PAM, que cola ~1 linha por segundo).
# O kit vai compactado em base64, em POUCAS linhas LONGAS:
#   linha 1      : prepara a pasta (padrao ~/wisedb-kit; outra: WK=/pasta antes)
#   linhas 2..N  : partes do kit
#   ultima linha : confere md5, extrai e informa KIT OK ou ERRO
# Nenhuma linha executa a coleta: depois de "KIT OK", rode a linha de execucao.
#
# USO (num Linux com a pasta do kit, ex.: wisedb-bastion ou WSL):
#   bash gerar_colagem_senhasegura.sh                 # kit Linux completo
#   bash gerar_colagem_senhasegura.sh -p arq1 arq2    # so os arquivos citados
#                                                     # (atualiza kit ja instalado)
#   -l 15000  tamanho maximo de cada linha (padrao 15000 caracteres)
#   -o arquivo.txt  nome da saida
#===============================================================================
set -euo pipefail
cd "$(dirname "$0")"
L=15000; PARCIAL=0; OUT=""
while getopts "l:o:p" o; do
  case "$o" in l) L="$OPTARG";; o) OUT="$OPTARG";; p) PARCIAL=1;; *) exit 1;; esac
done
shift $((OPTIND-1))
VER=$(sed -n 's/^VERSAO="\(.*\)"/\1/p' wisedb_coleta_auto.sh | head -1)
if [ "$PARCIAL" = "1" ]; then
  [ $# -gt 0 ] || { echo "Informe os arquivos: -p arq1 arq2"; exit 1; }
  ARQS=("$@"); TIPO="atualizacao"
else
  ARQS=(wisedb_coleta_auto.sh wisedb_coleta_bootstrap.sh wisedb_digest.py 99_sanitizar_e_empacotar.sh)
  for f in [01][0-9]_*.sh; do ARQS+=("$f"); done
  TIPO="completo"
fi
for f in "${ARQS[@]}"; do [ -f "$f" ] || { echo "Arquivo ausente: $f"; exit 1; }; done
OUT="${OUT:-colagem_senhasegura_v${VER}_${TIPO}.txt}"
B64=$(tar -czf - "${ARQS[@]}" | base64 -w0)
MD5=$(printf %s "$B64" | md5sum | cut -c1-32)
mapfile -t PARTES < <(printf %s "$B64" | fold -w "$L")
N=${#PARTES[@]}
D='${WK:-$HOME/wisedb-kit}'
{
  if [ "$PARCIAL" = "1" ]; then
    echo "set +o history; cd $D && [ -f 01_coleta_linux_geral.sh ] && rm -f .wk.b64 && echo \"[WiseDB] atualizando kit em \$PWD para v$VER ($N partes)\" || echo \"[WiseDB] ERRO: kit nao encontrado em $D. Use o texto do kit completo.\""
  else
    echo "set +o history; mkdir -p $D && cd $D && rm -f .wk.b64 && echo \"[WiseDB] recebendo kit v$VER em \$PWD ($N partes)\""
  fi
  i=0
  for p in "${PARTES[@]}"; do
    i=$((i+1))
    echo "printf %s '$p' >> $D/.wk.b64 && echo '[WiseDB] parte $i/$N'"
  done
  echo "cd $D && [ \"\$(md5sum < .wk.b64 | cut -c1-32)\" = \"$MD5\" ] && base64 -d .wk.b64 | tar -xzf - && rm -f .wk.b64 && chmod +x *.sh && echo \"[WiseDB] KIT OK v$VER em \$PWD\" || echo \"[WiseDB] ERRO: colagem incompleta (md5). Cole o texto inteiro de novo.\"; set -o history"
} > "$OUT"
echo "Gerado: $OUT ($((N+2)) linhas, maior linha $(awk '{ if (length>m) m=length } END {print m}' "$OUT") caracteres)"
echo "Depois de \"KIT OK\", rode no servidor:"
echo "  cd $D && WISEDB_OFFLINE=1 bash wisedb_coleta_auto.sh"
