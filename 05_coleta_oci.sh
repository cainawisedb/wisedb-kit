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

PROFILE="DEFAULT"; REGION=""; TENANCY=""; BUCKET=""; OBJ_LIMIT="${WISEDB_OBJ_LIMIT:-50}"
while [ $# -gt 0 ]; do
  case "$1" in
    --profile) PROFILE="$2"; shift 2;;
    --region)  REGION="$2";  shift 2;;
    --tenancy) TENANCY="$2"; shift 2;;
    --bucket)  BUCKET="$2";  shift 2;;
    --obj-limit) OBJ_LIMIT="$2"; shift 2;;
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

  # IPs das instancias. Sem isto a ficha tecnica da politica fica sem endereco,
  # e o cruzamento com os hosts coletados localmente depende de adivinhacao.
  run 20b_compute_ips.txt "IPs privados e publicos das instancias ($C)" \
    "for I in \$($OCI compute instance list --compartment-id $C --all --query 'data[].id' --raw-output | tr -d '\",[]' ); do \
       NOME=\$($OCI compute instance get --instance-id \$I --query 'data.\"display-name\"' --raw-output 2>/dev/null); \
       echo \"-- \$NOME (\$I)\"; \
       $OCI compute instance list-vnics --instance-id \$I \
         --query 'data[].{privado:\"private-ip\", publico:\"public-ip\", hostname:\"hostname-label\", subnet:\"subnet-id\"}' --output table; \
     done"

  # Volume groups: quando a politica de backup e atribuida ao grupo e nao ao
  # volume, a consulta de assignment por volume retorna vazio e o volume parece
  # desprotegido, mesmo havendo backup agendado. Este bloco desfaz esse engano.
  run 25_volume_groups.txt "Volume groups e politica atribuida ($C)" \
    "for AD in \$($OCI iam availability-domain list --compartment-id $TENANCY --query 'data[].name' --raw-output | tr -d '\",[]' ); do \
       $OCI bv volume-group list --compartment-id $C --availability-domain \$AD --all \
         --query 'data[].{nome:\"display-name\", ocid:id, volumes:\"volume-ids\"}' --output json; \
       for VG in \$($OCI bv volume-group list --compartment-id $C --availability-domain \$AD --all --query 'data[].id' --raw-output | tr -d '\",[]' ); do \
         echo \"-- Politica do volume group \$VG:\"; \
         $OCI bv volume-backup-policy-assignment get-volume-backup-policy-asset-assignment --asset-id \$VG \
           --query 'data[].{policy_ocid:\"policy-id\"}' --output table; \
       done; \
     done"

  # Block volumes (dados) e sua politica. Antes so o boot volume era consultado,
  # deixando os volumes de dados, onde ficam dumps e datafiles, sem evidencia.
  run 26_block_volumes_politicas.txt "Block volumes e politica de backup atribuida ($C)" \
    "for AD in \$($OCI iam availability-domain list --compartment-id $TENANCY --query 'data[].name' --raw-output | tr -d '\",[]' ); do \
       $OCI bv volume list --compartment-id $C --availability-domain \$AD --all \
         --query 'data[].{nome:\"display-name\", ocid:id, gb:\"size-in-gbs\", estado:\"lifecycle-state\"}' --output table; \
       for V in \$($OCI bv volume list --compartment-id $C --availability-domain \$AD --all --query 'data[].id' --raw-output | tr -d '\",[]' ); do \
         echo \"-- Politica do block volume \$V:\"; \
         $OCI bv volume-backup-policy-assignment get-volume-backup-policy-asset-assignment --asset-id \$V \
           --query 'data[].{policy_ocid:\"policy-id\"}' --output table; \
       done; \
     done"

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
    "$OCI os object list --bucket-name $B --namespace $NS --limit $OBJ_LIMIT \
     --fields name,size,timeCreated --query 'data[].{objeto:name, bytes:size, criado:\"time-created\"}' --output table"

  # Inventario completo em JSON. A amostra acima e truncada (next-start-with) e
  # nao permite afirmar retencao real nem contagem de copias no bucket.
  run 31_bucket_${B}_objetos_inventario.txt "Inventario agregado do bucket $B (contagem, bytes, datas)" \
    "$OCI os object list --bucket-name $B --namespace $NS --all --fields name,size,timeCreated \
       --output json 2>/dev/null | python3 -c \"
import json,sys,collections
try: d=json.load(sys.stdin)
except Exception as e: print('[AVISO] inventario nao parseavel:', e); raise SystemExit
objs=d.get('data') or []
print('Total de objetos:', len(objs))
tot=sum(o.get('size') or 0 for o in objs)
print('Bytes totais: %d (%.2f GB)' % (tot, tot/1024**3))
g=collections.defaultdict(lambda:[0,0,'9999','0000'])
import re
for o in objs:
    p=re.sub(r'[0-9]{8}.*','',o.get('name') or '')[:60] or (o.get('name') or '')[:60]
    t=(o.get('time-created') or '')[:10]
    e=g[p]; e[0]+=1; e[1]+=o.get('size') or 0
    if t: e[2]=min(e[2],t); e[3]=max(e[3],t)
print()
print('%-62s %6s %12s %11s %11s' % ('PREFIXO','ARQ','GB','MAIS_ANTIGO','MAIS_NOVO'))
for p in sorted(g):
    c,b,mn,mx=g[p]
    print('%-62s %6d %12.2f %11s %11s' % (p,c,b/1024**3,mn,mx))
\" || echo '[AVISO] inventario completo falhou (bucket muito grande ou python3 ausente)'"

  # Replicacao: e a unica prova de copia cross-region no Object Storage.
  run 31_bucket_${B}_replicacao.txt "Politica de replicacao do bucket $B (copia cross-region)" \
    "$OCI os replication-policy list --bucket-name $B --namespace $NS --output json 2>/dev/null \
     || echo 'Sem politica de replicacao neste bucket'"
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

  # Backup config de cada database do DB System: revela se o backup automatico
  # gerenciado esta habilitado, a janela e a retencao em dias. Sem isto nao se
  # distingue "banco sem backup gerenciado" de "banco com backup via RMAN proprio".
  run 43_db_backup_config.txt "Backup config das databases dos DB Systems ($C)" \
    "$OCI db database list --compartment-id $C --all \
       --query 'data[].{nome:\"db-name\", unique:\"db-unique-name\", estado:\"lifecycle-state\", \
                        auto:\"db-backup-config\".\"auto-backup-enabled\", \
                        janela:\"db-backup-config\".\"auto-backup-window\", \
                        retencao_dias:\"db-backup-config\".\"recovery-window-in-days\", \
                        destino:\"db-backup-config\".\"backup-destination-details\"}' --output json"

  # Recovery Service (DBRS): quando o RMAN esta com RETENTION POLICY TO NONE, a
  # janela de recuperacao real vive aqui. Sem este bloco a retencao do backup
  # fisico fica indeterminada.
  run 45_recovery_service.txt "Recovery Service: bancos protegidos e politicas ($C)" \
    "echo '-- Protected databases:'; \
     $OCI recovery protected-database list --compartment-id $C --all \
       --query 'data.items[].{nome:\"display-name\", estado:\"lifecycle-state\", saude:health, \
                              politica:\"protection-policy-id\", tamanho_gb:\"database-size-in-gbs\", \
                              retencao_atual:\"metrics\".\"retention-period-in-days\", \
                              janela_recuperavel:\"metrics\".\"current-retention-period-in-seconds\"}' --output json; \
     echo '-- Protection policies:'; \
     $OCI recovery protection-policy list --compartment-id $C --all \
       --query 'data.items[].{nome:\"display-name\", dias:\"backup-retention-period-in-days\", \
                              predefinida:\"is-predefined-policy\", estado:\"lifecycle-state\"}' --output table"
done

#--- 5. Copia cross-region: prova do criterio offsite do 3-2-1-1-0 --------------
# O criterio "1 copia offsite" so e atendido de fato se houver copia fora da
# regiao primaria. Backup no Object Storage da mesma regiao nao satisfaz o
# criterio, e sem esta verificacao a politica afirmava offsite por suposicao.
run 50_cross_region.txt "Verificacao de copia cross-region (volume backups e DB backups)" \
  "echo \"Regiao primaria consultada: ${REGION:-default do profile}\"; \
   echo; echo '-- Regioes assinadas pela tenancy:'; \
   $OCI iam region-subscription list --query 'data[].{regiao:\"region-name\", tipo:status}' --output table; \
   echo; echo '-- Volume backups com origem em outra regiao (copia recebida):'; \
   for C in ${COMPS[*]}; do \
     $OCI bv backup list --compartment-id \$C --all \
       --query 'data[?\"source-volume-backup-id\"!=null].{nome:\"display-name\", origem:\"source-volume-backup-id\", criado:\"time-created\"}' --output table; \
     $OCI bv boot-volume-backup list --compartment-id \$C --all \
       --query 'data[?\"source-boot-volume-backup-id\"!=null].{nome:\"display-name\", origem:\"source-boot-volume-backup-id\", criado:\"time-created\"}' --output table; \
   done; \
   echo; echo '-- Se as duas listas acima estiverem vazias, nao ha copia cross-region de volume nesta regiao.'"

echo "Coleta OCI concluida em $OUT. Revise os arquivos antes de enviar."
echo "Nota: sintaxe de subcomandos pode variar entre versoes do OCI CLI; se um bloco falhar, envie o erro junto."
