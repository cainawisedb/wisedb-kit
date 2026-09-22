#!/bin/bash
#===============================================================================
# 08_coleta_cloud_outras.sh - WiseDB | Kit de Coleta para Politica de Backup
# v2.0 - AWS multi-regiao, GCP (Compute/Cloud SQL/GCS/Backup-DR) e Azure
#
# OBJETIVO : Coletar backup de recursos em nuvens alem da OCI:
#            - AWS  : AWS Backup (vaults, lock, planos, selecoes, jobs), EBS,
#                     DLM, RDS/Aurora (retencao e PITR), S3 (versionamento,
#                     Object Lock, lifecycle, replicacao), EFS e FSx
#            - GCP  : resource policies de snapshot, discos sem politica,
#                     Cloud SQL (backup automatico e PITR), GCS (lifecycle,
#                     bucket lock, versionamento), Backup and DR, Filestore
#            - Azure: Recovery Services Vaults, politicas, itens protegidos,
#                     jobs recentes e VMs sem protecao
# RISCO    : Zero. Somente list/get/describe/show.
#
# EXECUCAO : normalmente NAO e chamado a mao. O wisedb_coleta_auto.sh (v3.4+)
#            descobre as contas configuradas no host e executa este modulo.
#            Uso manual:
#              bash 08_coleta_cloud_outras.sh aws   --profile NETCON [--regions "us-east-1 sa-east-1"]
#              bash 08_coleta_cloud_outras.sh gcp   --configuration cliente01 [--project ID]
#              bash 08_coleta_cloud_outras.sh azure --subscription <id>
#            Forma posicional antiga continua aceita:
#              bash 08_coleta_cloud_outras.sh aws PERFIL sa-east-1
#              bash 08_coleta_cloud_outras.sh azure <subscription_id>
# SAIDA    : ./coleta_cloud_<provedor>_<identificador>_<data>/
#===============================================================================
set -uo pipefail

MODO="${1:?Uso: $0 <aws|gcp|azure|tudo> [--profile|--configuration|--subscription <id>] [--regions \"r1 r2\"] [--project ID]}"
shift

PROFILE=""; REGIONS=""; CONFIG=""; PROJECT=""; SUB=""
while [ $# -gt 0 ]; do
  case "$1" in
    --profile)       PROFILE="$2"; shift 2;;
    --regions)       REGIONS="$2"; shift 2;;
    --region)        REGIONS="$2"; shift 2;;
    --configuration) CONFIG="$2";  shift 2;;
    --project)       PROJECT="$2"; shift 2;;
    --subscription)  SUB="$2";     shift 2;;
    --*) echo "Parametro desconhecido: $1"; exit 1;;
    *) # compatibilidade com a chamada posicional da v1
       case "$MODO" in
         aws)   if [ -z "$PROFILE" ]; then PROFILE="$1"; else REGIONS="${REGIONS:+$REGIONS }$1"; fi;;
         gcp)   if [ -z "$CONFIG" ];  then CONFIG="$1";  else PROJECT="$1"; fi;;
         azure) [ -z "$SUB" ] && SUB="$1";;
       esac; shift;;
  esac
done

SLUG=$(echo "${PROFILE:-${CONFIG:-${SUB:-default}}}" | tr -cd '[:alnum:]_-' | cut -c1-24)
OUT="./coleta_cloud_${MODO}_${SLUG}_$(date +%Y%m%d)"
mkdir -p "$OUT"

run(){ local f="$OUT/$1"; local t="$2"; shift 2
  { echo "################################################################"
    echo "## $t"
    echo "## $*"
    echo "## Coletado em: $(date '+%d/%m/%Y %H:%M:%S')"
    echo "################################################################"
    eval "$@" 2>&1 || echo "[AVISO] comando falhou, sem permissao ou servico nao usado neste cliente"
    echo
  } >> "$f"
}

#=============================== AWS ============================================
coleta_aws(){
  local P="${PROFILE:-default}"
  local D14; D14=$(date -u -d '14 days ago' +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)
  local A="aws --profile $P --no-cli-pager --output table"
  local base n b d r

  # Recurso da AWS so aparece na regiao onde existe. Assumir a regiao do
  # ~/.aws/config gera coleta vazia e a politica sai afirmando que o cliente
  # nao tem backup quando a conta inteira esta em outra regiao.
  if [ -z "$REGIONS" ]; then
    base=$(aws configure get region --profile "$P" 2>/dev/null || echo us-east-1)
    for r in $(aws ec2 describe-regions --profile "$P" --region "${base:-us-east-1}" \
                 --query 'Regions[].RegionName' --output text 2>/dev/null | tr '\t' '\n'); do
      n=$(aws ec2    describe-instances    --profile "$P" --region "$r" --query 'length(Reservations[].Instances[])' --output text 2>/dev/null)
      b=$(aws backup list-backup-plans     --profile "$P" --region "$r" --query 'length(BackupPlansList)'            --output text 2>/dev/null)
      d=$(aws rds    describe-db-instances --profile "$P" --region "$r" --query 'length(DBInstances)'                --output text 2>/dev/null)
      case "$n" in ''|*[!0-9]*) n=0;; esac
      case "$b" in ''|*[!0-9]*) b=0;; esac
      case "$d" in ''|*[!0-9]*) d=0;; esac
      [ $((n+b+d)) -gt 0 ] && REGIONS="${REGIONS:+$REGIONS }$r"
    done
    [ -z "$REGIONS" ] && REGIONS="${base:-us-east-1}"
  fi
  local R1="${REGIONS%% *}"

  run aws_00_contexto.txt "Identidade, conta e regioes no escopo" \
      "$A --region $R1 sts get-caller-identity; echo; echo 'Regioes coletadas: $REGIONS'"

  # S3 e global: listado uma unica vez, fora do laco de regiao.
  run aws_90_s3_buckets.txt "S3: buckets da conta" \
      "$A --region $R1 s3api list-buckets --query 'Buckets[].{bucket:Name, criado:CreationDate}'"
  for B in $(aws --profile "$P" --region "$R1" s3api list-buckets --query 'Buckets[].Name' --output text 2>/dev/null); do
    run "aws_91_s3_${B}.txt" "S3 $B: versionamento, Object Lock (imutabilidade), lifecycle e replicacao" \
        "echo '--- regiao ---';         $A --region $R1 s3api get-bucket-location --bucket $B; \
         echo '--- versionamento ---';  $A --region $R1 s3api get-bucket-versioning --bucket $B; \
         echo '--- object lock ---';    $A --region $R1 s3api get-object-lock-configuration --bucket $B; \
         echo '--- lifecycle ---';      $A --region $R1 s3api get-bucket-lifecycle-configuration --bucket $B --output json; \
         echo '--- replicacao ---';     $A --region $R1 s3api get-bucket-replication --bucket $B --output json"
  done

  for R in $REGIONS; do
    local AR="$A --region $R"
    run "aws_10_${R}_instancias.txt" "EC2 em $R (base para cruzar cobertura)" \
        "$AR ec2 describe-instances \
         --query 'Reservations[].Instances[].{id:InstanceId, nome:Tags[?Key==\`Name\`]|[0].Value, tipo:InstanceType, estado:State.Name}'"
    run "aws_11_${R}_volumes.txt" "EBS em $R (volume sem snapshot recente = gap)" \
        "$AR ec2 describe-volumes \
         --query 'Volumes[].{volume:VolumeId, tamanhoGB:Size, tipo:VolumeType, estado:State, anexadoA:Attachments[0].InstanceId}'"
    run "aws_20_${R}_backup_vaults.txt" "AWS Backup em $R: vaults (Locked = imutabilidade)" \
        "$AR backup list-backup-vaults \
         --query 'BackupVaultList[].{vault:BackupVaultName, pontos:NumberOfRecoveryPoints, lockImutavel:Locked, lockMinDias:MinRetentionDays, lockMaxDias:MaxRetentionDays}'"
    run "aws_21_${R}_backup_planos.txt" "AWS Backup em $R: planos" \
        "$AR backup list-backup-plans --query 'BackupPlansList[].{plano:BackupPlanName, id:BackupPlanId, ultimaExec:LastExecutionDate}'"
    for PID in $(aws --profile "$P" --region "$R" backup list-backup-plans --output text --query 'BackupPlansList[].BackupPlanId' 2>/dev/null); do
      run "aws_22_${R}_plano_${PID}.txt" "Regras do plano $PID (agenda, retencao, copia cross-region)" \
          "$AR backup get-backup-plan --backup-plan-id $PID \
           --query 'BackupPlan.Rules[].{regra:RuleName, vault:TargetBackupVaultName, agenda:ScheduleExpression, janelaMin:StartWindowMinutes, frioApos:Lifecycle.MoveToColdStorageAfterDays, retencaoDias:Lifecycle.DeleteAfterDays, copiaDestino:CopyActions[].DestinationBackupVaultArn}'"
      run "aws_23_${R}_plano_${PID}_selecoes.txt" "Recursos atribuidos ao plano $PID" \
          "$AR backup list-backup-selections --backup-plan-id $PID --output json"
    done
    run "aws_24_${R}_jobs14d.txt" "AWS Backup em $R: jobs dos ultimos 14 dias (falha aqui vira risco)" \
        "$AR backup list-backup-jobs --by-created-after $D14 \
         --query 'BackupJobs[].{recurso:ResourceArn, tipo:ResourceType, estado:State, inicio:CreationDate, fim:CompletionDate, vault:BackupVaultName, mensagem:StatusMessage}'"
    run "aws_25_${R}_jobs_copia.txt" "AWS Backup em $R: copy jobs (off-site / cross-region)" \
        "$AR backup list-copy-jobs --by-created-after $D14 \
         --query 'CopyJobs[].{origem:SourceBackupVaultArn, destino:DestinationBackupVaultArn, estado:State, inicio:CreationDate}'"
    run "aws_26_${R}_snapshots_ebs.txt" "Snapshots EBS proprios em $R (amostra recente)" \
        "$AR ec2 describe-snapshots --owner-ids self --max-items 60 \
         --query 'Snapshots[].{id:SnapshotId, volume:VolumeId, criado:StartTime, estado:State, descricao:Description}'"
    run "aws_27_${R}_dlm.txt" "Data Lifecycle Manager em $R (snapshot automatizado fora do AWS Backup)" \
        "$AR dlm get-lifecycle-policies --output json"
    run "aws_30_${R}_rds.txt" "RDS/Aurora em $R: retencao do backup automatico, janela e multi-AZ" \
        "$AR rds describe-db-instances \
         --query 'DBInstances[].{db:DBInstanceIdentifier, engine:Engine, retencaoDias:BackupRetentionPeriod, janela:PreferredBackupWindow, multiAZ:MultiAZ, ultimoRestauravel:LatestRestorableTime, protecaoDelecao:DeletionProtection}'"
    run "aws_31_${R}_rds_clusters.txt" "Clusters Aurora em $R" \
        "$AR rds describe-db-clusters \
         --query 'DBClusters[].{cluster:DBClusterIdentifier, engine:Engine, retencaoDias:BackupRetentionPeriod, janela:PreferredBackupWindow, backtrack:BacktrackWindow}'"
    run "aws_32_${R}_rds_snapshots.txt" "Snapshots RDS manuais e automaticos em $R" \
        "$AR rds describe-db-snapshots --max-items 40 \
         --query 'DBSnapshots[].{snapshot:DBSnapshotIdentifier, db:DBInstanceIdentifier, tipo:SnapshotType, criado:SnapshotCreateTime, status:Status}'"
    run "aws_40_${R}_efs_fsx.txt" "EFS e FSx em $R (backup automatico proprio)" \
        "$AR efs describe-file-systems --query 'FileSystems[].{fs:FileSystemId, nome:Name, tamanhoBytes:SizeInBytes.Value}'; echo; \
         $AR fsx describe-file-systems --query 'FileSystems[].{fs:FileSystemId, tipo:FileSystemType, retencaoDias:WindowsConfiguration.AutomaticBackupRetentionDays}'"
  done
}

#=============================== GCP ============================================
coleta_gcp(){
  local C="${CONFIG:-default}"
  local G="gcloud --configuration=$C"
  local PJ="$PROJECT"
  [ -z "$PJ" ] && PJ=$($G config get-value project 2>/dev/null | grep -v '^(unset)$' || true)
  [ -z "$PJ" ] && { echo "Projeto GCP nao definido (use --project)"; return 1; }
  G="$G --project=$PJ"

  run gcp_00_contexto.txt "Conta ativa, projeto e APIs de backup habilitadas" \
      "$G auth list --format='table(account,status)'; echo; \
       $G config list --format='table(section,property,value)'; echo; \
       $G services list --enabled --filter='config.name:(compute.googleapis.com OR sqladmin.googleapis.com OR backupdr.googleapis.com OR file.googleapis.com)' --format='value(config.name)'"

  run gcp_10_instancias.txt "Compute Engine: instancias (base para cruzar cobertura)" \
      "$G compute instances list --format='table(name, zone.basename(), status, machineType.basename())'"
  run gcp_11_discos.txt "Discos e snapshot schedules vinculados (disco sem resourcePolicies = gap)" \
      "$G compute disks list --format='table(name, zone.basename(), sizeGb, type.basename(), resourcePolicies.list())'"
  run gcp_12_resource_policies.txt "Snapshot schedules: agenda, retencao e local de armazenamento" \
      "$G compute resource-policies list --format=json"
  run gcp_13_snapshots.txt "Snapshots existentes (amostra recente)" \
      "$G compute snapshots list --sort-by=~creationTimestamp --limit=60 \
       --format='table(name, sourceDisk.basename(), creationTimestamp, storageBytes, storageLocations.list())'"
  run gcp_14_imagens.txt "Imagens customizadas do projeto" \
      "$G compute images list --no-standard-images --format='table(name, creationTimestamp, diskSizeGb, status)'"

  run gcp_20_cloudsql.txt "Cloud SQL: instancias" \
      "$G sql instances list --format='table(name, databaseVersion, region, settings.availabilityType, state)'"
  for I in $($G sql instances list --format='value(name)' 2>/dev/null); do
    run "gcp_21_cloudsql_${I}.txt" "Cloud SQL $I: backup automatico, PITR, retencao e replicas" \
        "$G sql instances describe $I \
         --format='yaml(name, region, settings.backupConfiguration, settings.availabilityType, replicaNames, failoverReplica)'"
    run "gcp_22_cloudsql_${I}_backups.txt" "Cloud SQL $I: backups existentes" \
        "$G sql backups list --instance=$I --limit=30 --format='table(id, windowStartTime, type, status, location)'"
  done

  run gcp_30_gcs.txt "Cloud Storage: buckets com lifecycle, retention policy (bucket lock) e versionamento" \
      "$G storage buckets list --format=json"

  run gcp_40_backupdr.txt "Backup and DR Service: vaults e planos (retencao imutavel)" \
      "$G backup-dr backup-vaults list --location=- --format=json; echo; \
       $G backup-dr backup-plans  list --location=- --format=json"
  run gcp_41_filestore.txt "Filestore: instancias e backups" \
      "$G filestore instances list --format='table(name, tier, fileShares[0].capacityGb, state)'; echo; \
       $G filestore backups list --format='table(name, sourceInstance, createTime, state)'"
  run gcp_50_privilegio.txt "Roles da conta usada nesta coleta (declarar privilegio na politica)" \
      "$G projects get-iam-policy $PJ --flatten='bindings[].members' \
       --filter=\"bindings.members:\$($G config get-value account 2>/dev/null)\" \
       --format='table(bindings.role)'"
}

#=============================== AZURE ==========================================
coleta_azure(){
  local AZ="az"
  [ -n "$SUB" ] && AZ="az --subscription $SUB"

  run azure_00_contexto.txt "Assinatura em uso" "$AZ account show --query '{nome:name, id:id}' -o table"
  run azure_10_vms.txt "Todas as VMs (para cruzar cobertura)" \
      "$AZ vm list --query '[].{vm:name, rg:resourceGroup, local:location, so:storageProfile.osDisk.osType}' -o table"
  run azure_20_vaults.txt "Recovery Services Vaults" \
      "$AZ backup vault list --query '[].{vault:name, rg:resourceGroup, local:location}' -o table"
  for linha in $($AZ backup vault list --query '[].[name,resourceGroup]' -o tsv 2>/dev/null | tr '\t' '|'); do
    V="${linha%%|*}"; RG="${linha##*|}"
    run "azure_21_${V}_politicas.txt" "Politicas do vault $V (agendamento e retencao)" \
        "$AZ backup policy list --vault-name $V --resource-group $RG \
         --query '[].{politica:name, tipo:properties.backupManagementType, agenda:properties.schedulePolicy, retencao:properties.retentionPolicy}' -o json"
    run "azure_22_${V}_itens.txt" "Itens protegidos no vault $V" \
        "$AZ backup item list --vault-name $V --resource-group $RG \
         --query '[].{item:properties.friendlyName, tipo:properties.workloadType, saude:properties.protectionStatus, ultimoBackup:properties.lastBackupTime, politica:properties.policyName}' -o table"
    run "azure_23_${V}_jobs14d.txt" "Jobs dos ultimos 14 dias no vault $V" \
        "$AZ backup job list --vault-name $V --resource-group $RG \
         --start-date \$(date -u -d '14 days ago' +%d-%m-%Y) \
         --query '[].{job:properties.entityFriendlyName, operacao:properties.operation, status:properties.status, inicio:properties.startTime, fim:properties.endTime}' -o table"
  done
  run azure_30_vms_sem_backup.txt "VMs SEM protecao (gap de cobertura)" \
      "$AZ backup protectable-vm list 2>/dev/null -o table; echo; \
       echo 'Alternativa: comparar azure_10_vms.txt com azure_22_*_itens.txt'"
}

case "$MODO" in
  aws)   coleta_aws;;
  gcp)   coleta_gcp;;
  azure) coleta_azure;;
  tudo)  coleta_aws; coleta_gcp; coleta_azure;;
  *) echo "Modo invalido: $MODO (use aws, gcp, azure ou tudo)"; exit 1;;
esac

echo "Coleta de nuvem concluida em $OUT. Revise antes de enviar."
