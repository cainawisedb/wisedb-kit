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
#
# Versao 1.3 (outubro/2026) - validado contra OCI CLI 3.95
#   [CRITICO]   "oci db database list --all" nao existe (No such option '--all'):
#               o backup config dos DB Systems (auto-backup, janela, retencao)
#               NUNCA foi coletado. Corrigido, e incluidos ultimo backup e
#               ultima falha de cada database e o destino (sem vpc-password).
#   [CRITICO]   Recovery Service usava "recovery protected-database list" e
#               "recovery protection-policy list", que nao existem. Corrigido
#               para *-collection list-*; sem o grupo "recovery" no CLI (bastion
#               antigo) a consulta vai por "oci raw-request".
#   [CRITICO]   Replicacao de bucket usava "os replication-policy list", que nao
#               existe. Corrigido para "os replication list-replication-policies"
#               com fallback raw-request. Antes, nenhum bucket aparecia com
#               replicacao, mesmo quando havia.
#   [NOVO]      Data Guard associations dos DB Systems (prova de DR do banco).
#   [NOVO]      Volume backups com expiracao e retention lock (imutabilidade).
#   [NOVO]      Bucket: chave KMS e flag de replicacao no detalhe (JSON).
#   [NOVO]      File Storage (FSS): file systems, politicas de snapshot,
#               snapshots e replicacoes. Backups de Autonomous, MySQL HeatWave
#               (politica, PITR, copia cross-region) e OCI PostgreSQL.
#   [NOVO]      Sem namespace (profile nao autentica) o modulo retorna erro,
#               para o orquestrador marcar a coleta como incompleta.
#
# Versao 1.2 (outubro/2026)
#   [CORRIGIDO] bash 4.2 (OL/RHEL 7): tenancy sem bucket abortava o modulo em
#               BUCKETS[@] unbound; DB Systems, Recovery Service e cross-region
#               nao eram coletados.
#   [CORRIGIDO] Cross-region consultado tambem nas regioes de DESTINO assinadas.
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
REG_PRIM="${REGION:-$(awk -v p="[$PROFILE]" '$0==p{f=1;next} /^\[/{f=0} f&&/^region/{sub(/.*=[[:space:]]*/,"");print;exit}' "${OCI_CLI_CONFIG_FILE:-$HOME/.oci/config}" 2>/dev/null)}"
# Grupos de comando ausentes em CLI antigo (bastion com Python 3.6): detecta uma vez.
tem_grupo(){ oci "$@" --help >/dev/null 2>&1; }
TEM_RECOVERY=0; tem_grupo recovery protected-database-collection list-protected-databases && TEM_RECOVERY=1
TEM_REPLIC=0;   tem_grupo os replication list-replication-policies && TEM_REPLIC=1
TEM_RAW=0;      tem_grupo raw-request && TEM_RAW=1

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
     --query 'data[0:25].{nome:\"display-name\", tipo:type, origem:\"source-type\", criado:\"time-created\", estado:\"lifecycle-state\", gb:\"unique-size-in-gbs\"}' --output table; \
     echo '-- Expiracao e retention lock (imutabilidade) dos 25 mais recentes:'; \
     $OCI bv boot-volume-backup list --compartment-id $C --all --sort-by TIMECREATED --sort-order DESC \
     --query 'data[0:25].{nome:\"display-name\", criado:\"time-created\", expira:\"expiration-time\", retention_lock:\"is-retention-lock-enabled\"}' --output table"

  run 23_block_volume_backups_30d.txt "Block volume backups (amostra recente, $C)" \
    "$OCI bv backup list --compartment-id $C --all --sort-by TIMECREATED --sort-order DESC \
     --query 'data[0:25].{nome:\"display-name\", tipo:type, criado:\"time-created\", estado:\"lifecycle-state\"}' --output table; \
     echo '-- Expiracao, origem e retention lock (imutabilidade) dos 25 mais recentes:'; \
     $OCI bv backup list --compartment-id $C --all --sort-by TIMECREATED --sort-order DESC \
     --query 'data[0:25].{nome:\"display-name\", criado:\"time-created\", origem:\"source-type\", expira:\"expiration-time\", retention_lock:\"is-retention-lock-enabled\"}' --output table"
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
  BUCKETS=()
  mapfile -t BUCKETS < <(for C in "${COMPS[@]}"; do
    eval "$OCI os bucket list --compartment-id $C --all --query 'data[].name' --raw-output" 2>/dev/null
  done | tr -d '",[] ' | grep -v '^$' | sort -u)
fi
for B in ${BUCKETS[@]+"${BUCKETS[@]}"}; do
  run 31_bucket_${B}_detalhe.txt "Detalhe do bucket $B (versionamento, tier, KMS, replicacao)" \
    "$OCI os bucket get --bucket-name $B --namespace $NS --fields approximateCount --fields approximateSize \
     --query 'data.{nome:name, versionamento:versioning, tier:\"storage-tier\", publico:\"public-access-type\", kms:\"kms-key-id\", replicacao:\"replication-enabled\", objetos:\"approximate-count\", bytes:\"approximate-size\"}' --output json"
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
  if [ "$TEM_REPLIC" = "1" ]; then
    run 31_bucket_${B}_replicacao.txt "Politica de replicacao do bucket $B (copia cross-region)" \
      "$OCI os replication list-replication-policies --bucket-name $B --namespace $NS --all --output json"
  elif [ "$TEM_RAW" = "1" ] && [ -n "$REG_PRIM" ]; then
    run 31_bucket_${B}_replicacao.txt "Politica de replicacao do bucket $B (raw-request: CLI sem 'os replication')" \
      "oci --profile $PROFILE raw-request --http-method GET --target-uri https://objectstorage.$REG_PRIM.oraclecloud.com/n/$NS/b/$B/replicationPolicies"
  else
    run 31_bucket_${B}_replicacao.txt "Politica de replicacao do bucket $B" \
      "echo '[CLI DESATUALIZADO] sem os replication e sem raw-request: replicacao NAO evidenciada'"
  fi
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
  # "db database list" e um comando customizado do CLI: percorre os DB Homes do
  # compartment e NAO aceita --all (com --all ele falha e nada era coletado).
  run 43_db_backup_config.txt "Backup config das databases dos DB Systems ($C)" \
    "$OCI db database list --compartment-id $C \
       --query 'data[].{nome:\"db-name\", unique:\"db-unique-name\", estado:\"lifecycle-state\", \
                        auto:\"db-backup-config\".\"auto-backup-enabled\", \
                        janela:\"db-backup-config\".\"auto-backup-window\", \
                        retencao_dias:\"db-backup-config\".\"recovery-window-in-days\", \
                        ultimo_backup:\"last-backup-timestamp\", ultima_falha:\"last-failed-backup-timestamp\", \
                        destino:\"db-backup-config\".\"backup-destination-details\"[].{tipo:type, remoto:\"is-remote\", regiao_remota:\"remote-region\", retention_lock:\"is-retention-lock-enabled\"}}' --output json"
  run 44_data_guard.txt "Data Guard associations das databases dos DB Systems ($C)" \
    "for D in \$($OCI db database list --compartment-id $C --query 'data[].id' --raw-output 2>/dev/null | tr -d '\",[]' ); do \
       echo \"-- database \$D\"; \
       $OCI db data-guard-association list --database-id \$D --all \
         --query 'data[].{papel:role, papel_par:\"peer-role\", modo:\"protection-mode\", transporte:\"transport-type\", lag_aplicacao:\"apply-lag\", estado:\"lifecycle-state\", par:\"peer-database-id\"}' --output table; \
     done"

  # Recovery Service (DBRS): quando o RMAN esta com RETENTION POLICY TO NONE, a
  # janela de recuperacao real vive aqui. Sem este bloco a retencao do backup
  # fisico fica indeterminada.
  if [ "$TEM_RECOVERY" = "1" ]; then
    run 45_recovery_service.txt "Recovery Service: bancos protegidos e politicas ($C)" \
      "echo '-- Protected databases:'; \
       $OCI recovery protected-database-collection list-protected-databases --compartment-id $C --all \
         --query 'data.items[].{nome:\"display-name\", estado:\"lifecycle-state\", saude:health, \
                                politica:\"protection-policy-id\", tamanho_gb:\"database-size\", \
                                retencao_atual:\"metrics\".\"retention-period-in-days\", \
                                janela_recuperavel:\"metrics\".\"current-retention-period-in-seconds\", \
                                janela_desprotegida_seg:\"metrics\".\"unprotected-window-in-seconds\", \
                                redo_habilitado:\"metrics\".\"is-redo-logs-enabled\"}' --output json; \
       echo '-- Protection policies:'; \
       $OCI recovery protection-policy-collection list-protection-policies --compartment-id $C --all \
         --query 'data.items[].{nome:\"display-name\", dias:\"backup-retention-period-in-days\", \
                                predefinida:\"is-predefined-policy\", travada_em:\"policy-locked-date-time\", estado:\"lifecycle-state\"}' --output json"
  elif [ "$TEM_RAW" = "1" ] && [ -n "$REG_PRIM" ]; then
    run 45_recovery_service.txt "Recovery Service via raw-request (CLI sem o grupo 'recovery') ($C)" \
      "echo '-- Protected databases (JSON da API, camelCase):'; \
       oci --profile $PROFILE raw-request --http-method GET --target-uri 'https://recovery.$REG_PRIM.oci.oraclecloud.com/20210216/protectedDatabases?compartmentId=$C'; \
       echo '-- Protection policies (JSON da API, camelCase):'; \
       oci --profile $PROFILE raw-request --http-method GET --target-uri 'https://recovery.$REG_PRIM.oci.oraclecloud.com/20210216/protectionPolicies?compartmentId=$C'"
  else
    run 45_recovery_service.txt "Recovery Service ($C)" \
      "echo '[CLI DESATUALIZADO] sem o grupo recovery e sem raw-request: Recovery Service NAO evidenciado'"
  fi
done

#--- 4b. Outros servicos de banco gerenciado e File Storage --------------------
for C in "${COMPS[@]}"; do
  run 42b_autonomous_backups.txt "Backups de Autonomous Database ($C)" \
    "$OCI db autonomous-database-backup list --compartment-id $C --all \
     --query 'data[0:25].{nome:\"display-name\", tipo:type, automatico:\"is-automatic\", inicio:\"time-started\", estado:\"lifecycle-state\", retencao_dias:\"retention-period-in-days\", restauravel:\"is-restorable\"}' --output table"
  # MySQL HeatWave: a politica de backup vem no proprio resumo do DB System
  # (habilitado, retencao, janela, PITR e copia para outra regiao).
  run 46_mysql_heatwave.txt "MySQL HeatWave: DB Systems, politica de backup e backups ($C)" \
    "$OCI mysql db-system list --compartment-id $C --all \
       --query 'data[].{nome:\"display-name\", estado:\"lifecycle-state\", versao:\"mysql-version\", ha:\"is-highly-available\", \
                        backup_habilitado:\"backup-policy\".\"is-enabled\", retencao_dias:\"backup-policy\".\"retention-in-days\", \
                        janela:\"backup-policy\".\"window-start-time\", pitr:\"backup-policy\".\"pitr-policy\".\"is-enabled\", \
                        copia_regiao:\"backup-policy\".\"copy-policies\"[].\"copy-to-region\"}' --output json; \
     echo '-- Backups (25 mais recentes):'; \
     $OCI mysql backup list --compartment-id $C --all --sort-by timeCreated --sort-order DESC \
       --query 'data[0:25].{nome:\"display-name\", tipo:\"backup-type\", criacao:\"creation-type\", criado:\"time-created\", estado:\"lifecycle-state\", retencao_dias:\"retention-in-days\", validacao:\"validation-status\"}' --output table"
  if tem_grupo psql db-system-collection list-db-systems; then
    run 47_oci_postgresql.txt "OCI Database with PostgreSQL: DB Systems e backups ($C)" \
      "$OCI psql db-system-collection list-db-systems --compartment-id $C --all \
         --query 'data.items[].{nome:\"display-name\", estado:\"lifecycle-state\", versao:\"db-version\", instancias:\"instance-count\"}' --output table; \
       echo '-- Backups:'; \
       $OCI psql backup-collection list-backups --compartment-id $C --all \
         --query 'data.items[0:25].{nome:\"display-name\", origem:\"source-type\", criado:\"time-created\", estado:\"lifecycle-state\", retencao:\"retention-period\", copia:\"copy-status\"}' --output table"
  fi
  # File Storage: destino comum de dumps e archives (ex.: /Standby/ARCHIVELOGS).
  # Snapshot de FSS nao e backup off-site, mas e a copia local mais comum.
  run 60_fss.txt "File Storage (FSS): file systems, politicas de snapshot, snapshots e replicacoes ($C)" \
    "for AD in \$($OCI iam availability-domain list --compartment-id $TENANCY --query 'data[].name' --raw-output | tr -d '\",[]' ); do \
       echo \"-- AD \$AD | file systems:\"; \
       $OCI fs file-system list --compartment-id $C --availability-domain \$AD --all \
         --query 'data[].{nome:\"display-name\", ocid:id, gb:\"metered-bytes\", estado:\"lifecycle-state\", kms:\"kms-key-id\", replicacoes_origem:\"replication-source-count\"}' --output table; \
       echo \"-- AD \$AD | politicas de snapshot:\"; \
       $OCI fs filesystem-snapshot-policy list --compartment-id $C --availability-domain \$AD --all \
         --query 'data[].{nome:\"display-name\", ocid:id, estado:\"lifecycle-state\", prefixo:\"policy-prefix\"}' --output table; \
       for P in \$($OCI fs filesystem-snapshot-policy list --compartment-id $C --availability-domain \$AD --all --query 'data[].id' --raw-output 2>/dev/null | tr -d '\",[]' ); do \
         echo \"-- schedules da politica \$P:\"; \
         $OCI fs filesystem-snapshot-policy get --filesystem-snapshot-policy-id \$P \
           --query 'data.schedules[].{periodo:period, hora:\"hour-of-day\", retencao_seg:\"retention-duration-in-seconds\"}' --output table; \
       done; \
       for FS in \$($OCI fs file-system list --compartment-id $C --availability-domain \$AD --all --query 'data[].id' --raw-output 2>/dev/null | tr -d '\",[]' ); do \
         echo \"-- snapshots do file system \$FS (contagem, mais antigo, mais recente):\"; \
         $OCI fs snapshot list --file-system-id \$FS --all \
           --query '{total:length(data), mais_antigo:min_by(data,&\"time-created\").\"time-created\", mais_recente:max_by(data,&\"time-created\").\"time-created\", por_politica:length(data[?\"snapshot-type\"==\`POLICY_BASED\`])}' --output table; \
       done; \
       echo \"-- AD \$AD | replicacoes de file system (copia para outro AD/regiao):\"; \
       $OCI fs replication list --compartment-id $C --availability-domain \$AD --all \
         --query 'data[].{nome:\"display-name\", estado:\"lifecycle-state\", intervalo_min:\"replication-interval\", ponto_recuperacao:\"recovery-point-time\"}' --output table; \
     done"
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
   echo; echo '-- Se as duas listas acima estiverem vazias, nao ha copia cross-region de volume RECEBIDA nesta regiao.'"

# A copia cross-region aparece na regiao de DESTINO, nao na de origem (licao do
# Parecer R-001 Interne, sa-vinhedo-1). Consultar so a regiao primaria dava
# falso negativo. Aqui cada regiao assinada alem da primaria e consultada.
mapfile -t REGS_SUB < <(eval "oci --profile $PROFILE iam region-subscription list --query 'data[].\"region-name\"' --raw-output" 2>/dev/null | tr -d '",[] ' | grep -v '^$')
for RG in ${REGS_SUB[@]+"${REGS_SUB[@]}"}; do
  [ "$RG" = "$REG_PRIM" ] && continue
  run 51_cross_region_destino_${RG}.txt "Copias cross-region RECEBIDAS na regiao $RG (origem em outra regiao)" \
    "for C in ${COMPS[*]}; do \
       oci --profile $PROFILE --region $RG bv backup list --compartment-id \$C --all \
         --query 'data[?\"source-volume-backup-id\"!=null].{nome:\"display-name\", origem:\"source-volume-backup-id\", criado:\"time-created\"}' --output table; \
       oci --profile $PROFILE --region $RG bv boot-volume-backup list --compartment-id \$C --all \
         --query 'data[?\"source-boot-volume-backup-id\"!=null].{nome:\"display-name\", origem:\"source-boot-volume-backup-id\", criado:\"time-created\"}' --output table; \
     done; echo '-- Lista vazia: nenhuma copia de volume desta tenancy chegou em $RG.'"
done

{ echo "## CAPACIDADES DO OCI CLI NESTE HOST"
  echo "versao: $(oci --version 2>/dev/null | head -1)"
  echo "grupo recovery: $([ "$TEM_RECOVERY" = "1" ] && echo SIM || echo NAO) | os replication: $([ "$TEM_REPLIC" = "1" ] && echo SIM || echo NAO) | raw-request: $([ "$TEM_RAW" = "1" ] && echo SIM || echo NAO)"
  echo "regiao primaria: ${REG_PRIM:-nao identificada}"
} > "$OUT/00_cli_capacidades.txt"
echo "Coleta OCI concluida em $OUT. Revise os arquivos antes de enviar."
echo "Nota: sintaxe de subcomandos pode variar entre versoes do OCI CLI; se um bloco falhar, envie o erro junto."
if [ -z "$NS" ]; then
  echo "[ERRO] Namespace do Object Storage nao obtido: o profile $PROFILE nao autenticou ou sem permissao." >&2
  exit 2
fi
exit 0
