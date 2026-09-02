#!/bin/bash
#===============================================================================
# wisedb_coleta_auto.sh - WiseDB | Coleta AUTOMATICA para Politica de Backup
#
# CONCEITO : Automatico first. Um unico comando no servidor alvo:
#
#   bash <(curl -fsSL https://raw.githubusercontent.com/SUAORG/wisedb-kit/main/wisedb_coleta_auto.sh)
#
# FLUXO    : 1) DETECTA o ambiente (Oracle, SQL Server, MySQL/MariaDB,
#               PostgreSQL, Proxmox/PBS, KVM, OCI CLI, Veeam Agent, cron)
#            2) WIZARD de confirmacao: incluir/remover itens e marcar
#               ambientes FORA do escopo da politica (com justificativa)
#            3) BAIXA da mesma origem apenas os modulos necessarios
#               (01, 02, 03, 05, 07b) e executa a coleta read-only
#            4) SANITIZA segredos, mostra o RESUMO e pede o OK final
#            5) GERA: resultado_final.txt (colar na IA junto com o Modelo)
#                     resultado.json     (estruturado p/ integracoes futuras)
#                     pacote .tar.gz
# RISCO    : Zero no ambiente. Somente leitura.
#===============================================================================
set -uo pipefail

BASE_URL="${WISEDB_BASE_URL:-https://raw.githubusercontent.com/SUAORG/wisedb-kit/main/kit_coleta_backup}"
VERSAO="2.0"
HOSTN=$(hostname -s 2>/dev/null || hostname)
DATA=$(date +%Y%m%d)
ORIG_DIR="$(pwd)"
WORK="$ORIG_DIR/wisedb_coleta_${HOSTN}_${DATA}"
TMP="$WORK/.modulos"
mkdir -p "$TMP"

# Entrada interativa funciona mesmo em "curl | bash" lendo de /dev/tty.
if [ -e /dev/tty ]; then TTY=/dev/tty; INTERATIVO=1; else TTY=/dev/null; INTERATIVO=0; fi
ask(){ local msg="$1"; local var="$2"; local pad="${3:-}"
  if [ "$INTERATIVO" = "1" ]; then
    printf "%s" "$msg" > "$TTY"; IFS= read -r "$var" < "$TTY"
    [ -z "${!var}" ] && printf -v "$var" '%s' "$pad"
  else printf -v "$var" '%s' "$pad"; fi
}

echo "==============================================================="
echo " WiseDB - Coleta Automatica de Backup v$VERSAO | $HOSTN | $(date '+%d/%m/%Y %H:%M')"
echo "==============================================================="

# Teste de conectividade com a origem dos modulos (evita falhas silenciosas depois)
if ! curl -fsSL "$BASE_URL/01_coleta_linux_geral.sh" -o /dev/null 2>/dev/null; then
  echo "[AVISO] Nao foi possivel baixar de: $BASE_URL"
  echo "        Verifique se WISEDB_BASE_URL aponta para a pasta correta (com ou sem /kit_coleta_backup)"
  echo "        e se o servidor tem saida HTTPS para raw.githubusercontent.com."
fi

#=========================== 1. DETECCAO ========================================
declare -A DET DESC
tem(){ command -v "$1" >/dev/null 2>&1; }

DET[linux]=1;                     DESC[linux]="Servidor Linux (cron, timers, scripts, destinos)"
if [ -s /etc/oratab ] || pgrep -f ora_pmon >/dev/null 2>&1; then DET[oracle]=1; else DET[oracle]=0; fi
DESC[oracle]="Oracle Database ($(grep -Ev '^\s*(#|$)' /etc/oratab 2>/dev/null | cut -d: -f1 | grep -Ev '^\+ASM' | tr '\n' ' ' 2>/dev/null))"
if pgrep -x sqlservr >/dev/null 2>&1 || systemctl is-active mssql-server >/dev/null 2>&1; then DET[sqlserver]=1; else DET[sqlserver]=0; fi
DESC[sqlserver]="Microsoft SQL Server (processo/servico ativo)"
if pgrep -x mysqld >/dev/null 2>&1 || pgrep -x mariadbd >/dev/null 2>&1; then DET[mysql]=1; else DET[mysql]=0; fi
DESC[mysql]="MySQL/MariaDB (registro de presenca; coleta detalhada sob demanda)"
if pgrep -f 'postgres.*checkpointer|postmaster' >/dev/null 2>&1; then DET[postgres]=1; else DET[postgres]=0; fi
DESC[postgres]="PostgreSQL (registro de presenca; coleta detalhada sob demanda)"
if tem pvesh || tem proxmox-backup-manager || { tem virsh && ! tem pvesh; }; then DET[hypervisor]=1; else DET[hypervisor]=0; fi
DESC[hypervisor]="Hypervisor Linux (Proxmox/PBS/KVM: jobs vzdump, prune, VMs sem backup)"
if tem oci && [ -f "$HOME/.oci/config" ]; then DET[oci]=1; else DET[oci]=0; fi
DESC[oci]="OCI CLI configurado (profiles: $(grep -oP '^\[\K[^]]+' "$HOME/.oci/config" 2>/dev/null | tr '\n' ' '))"
if tem veeamconfig; then DET[veeamagent]=1; else DET[veeamagent]=0; fi
DESC[veeamagent]="Veeam Agent for Linux"

CRON_HINT=$( { crontab -l 2>/dev/null; cat /etc/crontab 2>/dev/null; } | grep -Eic 'backup|rman|expdp|dump|vzdump' || true)

echo
echo "Componentes detectados automaticamente:"
i=0; ORDEM=()
for k in linux oracle sqlserver mysql postgres hypervisor oci veeamagent; do
  i=$((i+1)); ORDEM+=("$k")
  [ "${DET[$k]}" = "1" ] && M="[X]" || M="[ ]"
  echo "  $i) $M ${DESC[$k]}"
done
echo "  Indicios de backup no cron: $CRON_HINT linha(s)"

#=========================== 2. WIZARD ==========================================
EXCLUIDOS=()
if [ "$INTERATIVO" = "1" ]; then
  echo
  echo "--- WIZARD -------------------------------------------------------------"
  echo "Digite numeros para ligar/desligar itens (ex.: '4 5'), ENTER para aceitar."
  ask "> " TOGGLE ""
  for n in $TOGGLE; do
    k="${ORDEM[$((n-1))]:-}"; [ -n "$k" ] && DET[$k]=$((1-${DET[$k]}))
  done
  while :; do
    ask "Marcar algum ambiente/base como FORA do escopo da politica? (nome ou ENTER p/ seguir): " ITEM ""
    [ -z "$ITEM" ] && break
    ask "  Justificativa para '$ITEM': " JUST "Nao informado"
    EXCLUIDOS+=("$ITEM|$JUST")
  done
fi
ask "Nome do cliente: " CLIENTE "NAO_INFORMADO"
ask "RPO acordado (ENTER se nao definido): " RPO "A combinar com o cliente"
ask "RTO acordado (ENTER se nao definido): " RTO "A combinar com o cliente"

# Parametros condicionais
SQL_USER=""; OCI_PROFILE=""; OCI_TENANCY=""; OCI_REGION=""
[ "${DET[sqlserver]}" = "1" ] && ask "Usuario de LEITURA do SQL Server (senha sera pedida na hora): " SQL_USER "wisedb_ro"
if [ "${DET[oci]}" = "1" ]; then
  P1=$(grep -oP '^\[\K[^]]+' "$HOME/.oci/config" 2>/dev/null | head -1)
  ask "Profile OCI [$P1]: " OCI_PROFILE "$P1"
  OCI_TENANCY=$(awk -v p="[$OCI_PROFILE]" '$0==p{f=1;next} /^\[/{f=0} f&&/^tenancy/{print $NF}' "$HOME/.oci/config" | tr -d ' =' | sed 's/tenancy//')
  OCI_REGION=$(awk -v p="[$OCI_PROFILE]" '$0==p{f=1;next} /^\[/{f=0} f&&/^region/{print $NF}' "$HOME/.oci/config" | tr -d ' =' | sed 's/region//')
  echo "  Tenancy detectada: ${OCI_TENANCY:-nao encontrada} | Regiao: ${OCI_REGION:-padrao}"
fi

#=========================== 3. MODULOS + COLETA ================================
dl(){ # baixa modulo do repo; se existir localmente ao lado, usa o local
  local m="$1"
  if [ -f "$ORIG_DIR/kit_coleta_backup/$m" ]; then cp "$ORIG_DIR/kit_coleta_backup/$m" "$TMP/$m"
  elif [ -f "$ORIG_DIR/$m" ]; then cp "$ORIG_DIR/$m" "$TMP/$m"
  else
    curl -fsSL "$BASE_URL/$m" -o "$TMP/$m" || { echo "[ERRO] Falha ao baixar $m de $BASE_URL"; return 1; }
    if [ ! -s "$TMP/$m" ]; then echo "[ERRO] $m baixado vazio (verifique BASE_URL)"; return 1; fi
  fi
  chmod +x "$TMP/$m"
}

cd "$WORK"
echo
echo "--- COLETA (somente leitura) -------------------------------------------"
dl 01_coleta_linux_geral.sh   && bash "$TMP/01_coleta_linux_geral.sh"
[ "${DET[oracle]}"     = "1" ] && dl 02_coleta_oracle.sh           && bash "$TMP/02_coleta_oracle.sh"
[ "${DET[sqlserver]}"  = "1" ] && dl 03_coleta_sqlserver_linux.sh  && bash "$TMP/03_coleta_sqlserver_linux.sh" "localhost,1433" "$SQL_USER"
[ "${DET[hypervisor]}" = "1" ] && dl 07_coleta_hypervisor_linux.sh && bash "$TMP/07_coleta_hypervisor_linux.sh"
if [ "${DET[oci]}" = "1" ] && [ -n "$OCI_TENANCY" ]; then
  dl 05_coleta_oci.sh && bash "$TMP/05_coleta_oci.sh" --profile "$OCI_PROFILE" ${OCI_REGION:+--region "$OCI_REGION"} --tenancy "$OCI_TENANCY"
fi
[ "${DET[veeamagent]}" = "1" ] && { echo "## Veeam Agent Linux"; veeamconfig job list 2>&1; veeamconfig session list 2>&1 | tail -30; } > veeam_agent_linux.txt
cd - >/dev/null

#=========================== 4. SANITIZACAO =====================================
find "$WORK" -type f \( -name "*.txt" -o -name "*.log" -o -name "*.json" \) -print0 |
while IFS= read -r -d '' f; do
  sed -i -E \
    -e 's/((password|passwd|pwd|secret|token|apikey|api_key|client_secret)[[:space:]]*[=:][[:space:]]*)[^[:space:]",]+/\1***REMOVIDO***/Ig' \
    -e 's/(identified[[:space:]]+by[[:space:]]+)[^[:space:];]+/\1***REMOVIDO***/Ig' \
    -e 's#(//[^/:@[:space:]]+:)[^@[:space:]]+(@)#\1***REMOVIDO***\2#g' "$f"
done

#=========================== 5. CONSOLIDACAO ====================================
FINAL_TXT="$WORK/resultado_final.txt"
{
  echo "================================================================"
  echo " WISEDB - COLETA AUTOMATICA | Cliente: $CLIENTE | Host: $HOSTN"
  echo " Data da coleta: $(date '+%d/%m/%Y %H:%M %Z') | Script v$VERSAO"
  echo " RPO informado: $RPO | RTO informado: $RTO"
  echo " Itens fora do escopo declarados no wizard:"
  if [ ${#EXCLUIDOS[@]} -eq 0 ]; then echo "   (nenhum)"; else
    for e in "${EXCLUIDOS[@]}"; do echo "   - ${e%%|*} | Justificativa: ${e##*|}"; done; fi
  echo "================================================================"
  find "$WORK" -type f -name "*.txt" ! -name "resultado_final.txt" | sort | while read -r f; do
    echo; echo "########## ARQUIVO: ${f#$WORK/} ##########"; cat "$f"
  done
} > "$FINAL_TXT"

python3 - "$WORK" <<PYEOF 2>/dev/null || echo "[AVISO] python3 ausente; resultado.json nao gerado (txt permanece completo)"
import json, os, sys, datetime
w = sys.argv[1]
det = { "linux": ${DET[linux]}, "oracle": ${DET[oracle]}, "sqlserver": ${DET[sqlserver]},
        "mysql_mariadb": ${DET[mysql]}, "postgresql": ${DET[postgres]},
        "hypervisor_linux": ${DET[hypervisor]}, "oci_cli": ${DET[oci]}, "veeam_agent": ${DET[veeamagent]} }
exc = [dict(zip(("item","justificativa"), e.split("|",1))) for e in """${EXCLUIDOS[@]:-}""".split() if "|" in e]
doc = {
  "schema": "wisedb.coleta.backup/v1",
  "cliente": "$CLIENTE",
  "coleta": {"host": "$HOSTN", "data": datetime.datetime.now().isoformat(timespec="minutes"),
             "script_versao": "$VERSAO", "modo": "automatico"},
  "deteccao": det,
  "escopo": {"fora_do_escopo": exc},
  "rpo_informado": "$RPO", "rto_informado": "$RTO",
  "evidencias_arquivos": sorted(os.path.relpath(os.path.join(r,f), w)
      for r,_,fs in os.walk(w) for f in fs if f.endswith((".txt",".log",".json")) and f!="resultado.json"),
  "pendencias": [p for c,p in [
      (det["mysql_mariadb"]==1, "MySQL/MariaDB detectado: coletar rotina de dump/binlog"),
      (det["postgresql"]==1, "PostgreSQL detectado: coletar pg_dump/archive_mode"),
      ("$RPO"=="A combinar com o cliente", "RPO nao definido formalmente"),
      ("$RTO"=="A combinar com o cliente", "RTO nao definido formalmente")] if c]
}
open(os.path.join(w,"resultado.json"),"w",encoding="utf-8").write(json.dumps(doc, ensure_ascii=False, indent=2))
print("resultado.json gerado")
PYEOF

#=========================== 6. RESUMO + OK =====================================
echo
echo "=============================== RESUMO ================================"
echo " Cliente: $CLIENTE | Host: $HOSTN"
echo " Arquivos de evidencia: $(find "$WORK" -name '*.txt' | wc -l)"
echo " Fora do escopo: ${#EXCLUIDOS[@]} item(ns) | RPO: $RPO | RTO: $RTO"
echo " Verificacao de segredos remanescentes:"
grep -rniE 'password|passwd|secret|token' "$WORK" 2>/dev/null | grep -v 'REMOVIDO' | head -5 || echo "   nenhum encontrado"
echo "========================================================================"
ask "Gerar pacote final? (S/n): " OK "S"
if [ "${OK^^}" != "N" ]; then
  PACOTE="wisedb_coleta_${CLIENTE// /_}_${HOSTN}_${DATA}.tar.gz"
  tar -czf "$PACOTE" "$WORK"
  echo
  echo "PRONTO."
  echo "  1) Pacote completo : $PACOTE"
  echo "  2) Para a IA       : $FINAL_TXT (+ resultado.json)"
  echo "  Cole o conteudo na IA junto com o Modelo_Politica_de_Backup_WiseDB.md"
  echo "  e o prompt Backup Policy Engineer para gerar a politica e o PDF."
else
  echo "Pacote nao gerado. Os arquivos permanecem em $WORK para revisao."
fi
