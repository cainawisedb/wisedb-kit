#!/bin/bash
#===============================================================================
# 08_coleta_cloud_outras.sh - WiseDB | Kit de Coleta para Politica de Backup
#
# OBJETIVO : Coletar backup de VMs em outras clouds alem da OCI:
#            - Azure: Recovery Services Vaults, itens protegidos, politicas,
#              jobs recentes e VMs SEM protecao
#            - AWS: AWS Backup (vaults, planos, jobs), snapshots EBS e AMIs
# RISCO    : Zero. Somente list/get/describe/show.
# EXECUCAO : No servidor central com az/aws CLI autenticados (leitura):
#              bash 08_coleta_cloud_outras.sh azure [subscription_id]
#              bash 08_coleta_cloud_outras.sh aws   [profile] [region]
#              bash 08_coleta_cloud_outras.sh tudo
# SAIDA    : ./coleta_cloud_<data>/
#===============================================================================
set -uo pipefail
MODO="${1:?Uso: $0 <azure|aws|tudo> [args]}"
OUT="./coleta_cloud_$(date +%Y%m%d)"
mkdir -p "$OUT"

run(){ local f="$OUT/$1"; local t="$2"; shift 2
  { echo "################ $t ################"
    echo "## $* | $(date '+%d/%m/%Y %H:%M')"
    eval "$@" 2>&1 || echo "[AVISO] comando falhou ou servico nao usado"
    echo
  } >> "$f"
}

#=============================== AZURE ==========================================
coleta_azure(){
  local SUB="${1:-}"
  local AZ="az"
  [ -n "$SUB" ] && AZ="az --subscription $SUB"

  run azure_10_contexto.txt "Assinatura em uso" "$AZ account show --query '{nome:name, id:id}' -o table"
  run azure_11_vms.txt "Todas as VMs (para cruzar cobertura)" \
      "$AZ vm list --query '[].{vm:name, rg:resourceGroup, local:location, so:storageProfile.osDisk.osType}' -o table"
  run azure_20_vaults.txt "Recovery Services Vaults" \
      "$AZ backup vault list --query '[].{vault:name, rg:resourceGroup, local:location}' -o table"

  # Para cada vault: politicas, itens protegidos e jobs de 14 dias
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

  run azure_24_vms_sem_backup.txt "VMs SEM protecao (gap de cobertura)" \
      "$AZ backup protectable-vm list 2>/dev/null -o table; echo; \
       echo 'Alternativa: comparar azure_11_vms.txt com azure_22_*_itens.txt'"
}

#=============================== AWS ============================================
coleta_aws(){
  local PROFILE="${1:-default}"; local REGION="${2:-us-east-1}"
  local AWS="aws --profile $PROFILE --region $REGION --output table --no-cli-pager"
  local D14; D14=$(date -u -d '14 days ago' +%Y-%m-%dT%H:%M:%SZ)

  run aws_10_contexto.txt "Identidade em uso" "$AWS sts get-caller-identity"
  run aws_11_instancias.txt "Instancias EC2 (para cruzar cobertura)" \
      "$AWS ec2 describe-instances \
       --query 'Reservations[].Instances[].{id:InstanceId, nome:Tags[?Key==\`Name\`]|[0].Value, estado:State.Name}'"
  run aws_20_backup_vaults.txt "AWS Backup: vaults (checar lock = imutabilidade)" \
      "$AWS backup list-backup-vaults \
       --query 'BackupVaultList[].{vault:BackupVaultName, pontos:NumberOfRecoveryPoints, lockImutavel:Locked, lockMinDias:MinRetentionDays}'"
  run aws_21_backup_planos.txt "AWS Backup: planos" \
      "$AWS backup list-backup-plans --query 'BackupPlansList[].{plano:BackupPlanName, id:BackupPlanId}'"
  for PID in $($AWS backup list-backup-plans --output text --query 'BackupPlansList[].BackupPlanId' 2>/dev/null); do
    run "aws_22_plano_${PID}.txt" "Regras do plano $PID (agenda, retencao, copia p/ outra regiao)" \
        "$AWS backup get-backup-plan --backup-plan-id $PID \
         --query 'BackupPlan.Rules[].{regra:RuleName, agenda:ScheduleExpression, retencaoDias:Lifecycle.DeleteAfterDays, copiaDestino:CopyActions[].DestinationBackupVaultArn}'"
    run "aws_23_plano_${PID}_selecoes.txt" "Recursos atribuidos ao plano $PID" \
        "$AWS backup list-backup-selections --backup-plan-id $PID"
  done
  run aws_24_jobs14d.txt "AWS Backup: jobs dos ultimos 14 dias" \
      "$AWS backup list-backup-jobs --by-created-after $D14 \
       --query 'BackupJobs[].{recurso:ResourceArn, estado:State, inicio:CreationDate, vault:BackupVaultName}'"
  run aws_25_snapshots_ebs.txt "Snapshots EBS proprios (amostra recente)" \
      "$AWS ec2 describe-snapshots --owner-ids self --max-items 60 \
       --query 'Snapshots[].{id:SnapshotId, volume:VolumeId, criado:StartTime, estado:State, descricao:Description}'"
  run aws_26_dlm.txt "Data Lifecycle Manager (snapshots automatizados fora do AWS Backup)" \
      "$AWS dlm get-lifecycle-policies"
}

case "$MODO" in
  azure) coleta_azure "${2:-}";;
  aws)   coleta_aws "${2:-default}" "${3:-us-east-1}";;
  tudo)  coleta_azure ""; coleta_aws "default" "us-east-1";;
  *) echo "Modo invalido: $MODO"; exit 1;;
esac

echo "Coleta cloud concluida em $OUT. Revise antes de enviar."
