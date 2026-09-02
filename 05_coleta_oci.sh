#!/bin/bash
#===============================================================================
# 05_coleta_oci.sh - WiseDB | Kit de Coleta para Politica de Backup (OCI CLI)
#
# OBJETIVO : Coletar, no servidor central com OCI CLI, tudo que a OCI sabe
#            sobre backup do cliente: instancias e politicas de boot/block
#            volume, historico de volume backups, buckets (lifecycle e
#            retention rules = imutabilidade), Database Systems, Autonomous e
#            respectivos backups.
# RISCO    : Zero. Somente list/get. Nenhum create/update/delete.
# EXECUCAO : bash 05_coleta_oci.sh --profile <PROFILE> --region <REGIAO> \
#                 --tenancy <ocid1.tenancy...> [--bucket <nome_bucket_backup>]
#            O profile ~/.oci/config do cliente ja deve existir no servidor.
# SAIDA    : ./coleta_oci_<profile>_<data>/
#===============================================================================
set -uo pipefail

PROFILE="DEFAULT"; REGION=""; TENANCY=""; BUCKET=""
while [ $# -gt 0 ]; do
  case "$1" in
    --profile) PROFILE="$2"; shift 2;;
    --region)  REGION="$2";  shift 2;;
    --tenancy) TENANCY="$2"; shift 2;;
    --bucket)  BUCKET="$2";  shift 2;;
    *) echo "Parametro desconhecido: $1"; exit 1;;
  esac
done
[ -z "$TENANCY" ] && { echo "Informe --tenancy <ocid>"; exit 1; }

export PYTHONWARNINGS="ignore"
OCI="oci --profile $PROFILE"
[ -n "$REGION" ] && OCI="$OCI --region $REGION"
OUT="./coleta_oci_${PROFILE}_$(date +%Y%m%d)"
mkdir -p "$OUT"

run(){ # run arquivo "titulo" comando completo (string)
  local f="$OUT/$1"; local t="$2"; shift 2
  {
    echo "################################################################"
    echo "## $t"
    echo "## $*"
    echo "## Coletado em: $(date '+%d/%m/%Y %H:%M:%S') | Profile: $PROFILE"
    echo "################################################################"
    eval "$@" 2>&1 || echo "[AVISO] comando falhou ou servico nao usado neste cliente"
    echo
  } >> "$f"
}

#--- 1. Descoberta de compartments ---------------------------------------------
run 10_compartments.txt "Compartments da tenancy" \
  "$OCI iam compartment list --compartment-id $TENANCY --compartment-id-in-subtree true --all \
   --query 'data[].{nome:name, ocid:id, estado:\"lifecycle-state\"}' --output table"

mapfile -t COMPS < <(eval "$OCI iam compartment list --compartment-id $TENANCY \
  --compartment-id-in-subtree true --all \
  --query 'data[?\"lifecycle-state\"==\`ACTIVE\`].id' --raw-output" 2>/dev/null | tr -d '",[] ' | grep -v '^$')
COMPS+=("$TENANCY")
echo "Compartments ativos encontrados: ${#COMPS[@]}"

#--- 2. Compute + politicas de backup de boot/block volumes ---------------------
for C in "${COMPS[@]}"; do
  run 20_compute_instances.txt "Instancias no compartment $C" \
    "$OCI compute instance list --compartment-id $C --all \
     --query 'data[].{nome:\"display-name\", estado:\"lifecycle-state\", shape:shape, ocid:id}' --output table"

  run 21_boot_volumes_politicas.txt "Boot volumes e politica de backup atribuida ($C)" \
    "for AD in \$($OCI iam availability-domain list --compartment-id $TENANCY --query 'data[].name' --raw-output | tr -d '\",[]' ); do \
       $OCI bv boot-volume list --compartment-id $C --availability-domain \$AD --all \
         --query 'data[].{nome:\"display-name\", ocid:id, gb:\"size-in-gbs\"}' --output table; \
       for BV in \$($OCI bv boot-volume list --compartment-id $C --availability-domain \$AD --all --query 'data[].id' --raw-output | tr -d '\",[]' ); do \
         echo \"-- Politica do boot volume \$BV:\"; \
         $OCI bv volume-backup-policy-assignment get-volume-backup-policy-asset-assignment --asset-id \$BV \
           --query 'data[].{policy_ocid:\"policy-id\"}' --output table; \
       done; \
     done"

  run 22_volume_backups_30d.txt "Boot volume backups (amostra recente, $C)" \
    "$OCI bv boot-volume-backup list --compartment-id $C --all --sort-by TIMECREATED --sort-order DESC \
     --query 'data[0:25].{nome:\"display-name\", tipo:type, origem:\"source-type\", criado:\"time-created\", estado:\"lifecycle-state\", gb:\"unique-size-in-gbs\"}' --output table"

  run 23_block_volume_backups_30d.txt "Block volume backups (amostra recente, $C)" \
    "$OCI bv backup list --compartment-id $C --all --sort-by TIMECREATED --sort-order DESC \
     --query 'data[0:25].{nome:\"display-name\", tipo:type, criado:\"time-created\", estado:\"lifecycle-state\"}' --output table"
done

run 24_politicas_backup_definidas.txt "Politicas de volume backup (Gold/Silver/Bronze e customizadas)" \
  "$OCI bv volume-backup-policy list --all \
   --query 'data[].{nome:\"display-name\", ocid:id}' --output table; \
   for C in ${COMPS[*]}; do $OCI bv volume-backup-policy list --compartment-id \$C --all \
   --query 'data[].{nome:\"display-name\", ocid:id, schedules:schedules}' --output json; done"

#--- 3. Object Storage: buckets, lifecycle e IMUTABILIDADE ----------------------
NS=$(eval "$OCI os ns get --query data --raw-output" 2>/dev/null)
run 30_buckets.txt "Namespace e buckets por compartment" \
  "echo Namespace: $NS; for C in ${COMPS[*]}; do $OCI os bucket list --compartment-id \$C --all \
   --query 'data[].{bucket:name, criado:\"time-created\"}' --output table; done"

# Bucket especifico de backup (se informado) ou todos os buckets encontrados
if [ -n "$BUCKET" ]; then BUCKETS=("$BUCKET"); else
  mapfile -t BUCKETS < <(for C in "${COMPS[@]}"; do
    eval "$OCI os bucket list --compartment-id $C --all --query 'data[].name' --raw-output" 2>/dev/null
  done | tr -d '",[] ' | grep -v '^$' | sort -u)
fi
for B in "${BUCKETS[@]}"; do
  run 31_bucket_${B}_detalhe.txt "Detalhe do bucket $B (versionamento, tier)" \
    "$OCI os bucket get --bucket-name $B --namespace $NS \
     --query 'data.{nome:name, versionamento:versioning, tier:\"storage-tier\", publico:\"public-access-type\"}' --output table"
  run 31_bucket_${B}_lifecycle.txt "Lifecycle policy do bucket $B (expurgo automatico)" \
    "$OCI os object-lifecycle-policy get --bucket-name $B --namespace $NS --output json"
  run 31_bucket_${B}_retention.txt "Retention rules do bucket $B (IMUTABILIDADE)" \
    "$OCI os retention-rule list --bucket-name $B --namespace $NS --output json"
  run 31_bucket_${B}_objetos.txt "Amostra de objetos recentes do bucket $B" \
    "$OCI os object list --bucket-name $B --namespace $NS --limit 25 \
     --fields name,size,timeCreated --query 'data[].{objeto:name, bytes:size, criado:\"time-created\"}' --output table"
done

#--- 4. Bancos gerenciados pela OCI (DB Systems / Autonomous) -------------------
for C in "${COMPS[@]}"; do
  run 40_db_systems.txt "DB Systems ($C)" \
    "$OCI db system list --compartment-id $C --all \
     --query 'data[].{nome:\"display-name\", estado:\"lifecycle-state\", edicao:\"database-edition\", ocid:id}' --output table"
  run 41_db_backups.txt "Backups de databases OCI-managed ($C)" \
    "$OCI db backup list --compartment-id $C --all \
     --query 'data[0:25].{nome:\"display-name\", tipo:type, inicio:\"time-started\", fim:\"time-ended\", estado:\"lifecycle-state\"}' --output table"
  run 42_autonomous.txt "Autonomous Databases e retencao ($C)" \
    "$OCI db autonomous-database list --compartment-id $C --all \
     --query 'data[].{nome:\"display-name\", estado:\"lifecycle-state\", retencao_dias:\"backup-retention-period-in-days\"}' --output table"
done

echo "Coleta OCI concluida em $OUT. Revise os arquivos antes de enviar."
echo "Nota: sintaxe de subcomandos pode variar entre versoes do OCI CLI; se um bloco falhar, envie o erro junto."
