#!/bin/bash
#===============================================================================
# 07_coleta_hypervisor_linux.sh - WiseDB | Kit de Coleta para Politica de Backup
#
# OBJETIVO : Coletar backup de VMs em hypervisors Linux:
#            - Proxmox VE: jobs de vzdump agendados, historico e destino
#            - Proxmox Backup Server (PBS): datastores, retencao e verify
#            - KVM/libvirt puro: inventario de VMs e snapshots
# RISCO    : Zero. Somente leitura.
# EXECUCAO : No host do hypervisor, como root: bash 07_coleta_hypervisor_linux.sh
# SAIDA    : ./coleta_<hostname>_<data>/07_hypervisor/
#===============================================================================
set -uo pipefail
HOSTN=$(hostname -s 2>/dev/null || hostname)
OUT="./coleta_${HOSTN}_$(date +%Y%m%d)/07_hypervisor"
mkdir -p "$OUT"
F="$OUT/hypervisor_evidencias.txt"

run(){ local t="$1"; shift
  { echo "################ $t ################"
    echo "## $* | $(date '+%d/%m/%Y %H:%M')"
    eval "$@" 2>&1 || echo "[AVISO] nao disponivel neste host"
    echo
  } >> "$F"
}

#--------------------------- PROXMOX VE ----------------------------------------
if command -v pvesh >/dev/null 2>&1; then
  run "PROXMOX: versao" "pveversion"
  run "PROXMOX: VMs e CTs do cluster" "pvesh get /cluster/resources --type vm --output-format json-pretty"
  run "PROXMOX: JOBS DE BACKUP AGENDADOS (vzdump)" "pvesh get /cluster/backup --output-format json-pretty"
  run "PROXMOX: configuracao global do vzdump" "cat /etc/vzdump.conf"
  run "PROXMOX: jobs.cfg (agendamentos)" "cat /etc/pve/jobs.cfg"
  run "PROXMOX: storages (destinos, retencao prune-backups)" "cat /etc/pve/storage.cfg"
  run "PROXMOX: historico de tasks vzdump (recente)" \
      "pvesh get /nodes/\$(hostname)/tasks --typefilter vzdump --limit 60 --output-format json-pretty"
  run "PROXMOX: VMs SEM job de backup (gap)" \
      "pvesh get /cluster/backup-info/not-backed-up --output-format json-pretty"
fi

#--------------------------- PROXMOX BACKUP SERVER ------------------------------
if command -v proxmox-backup-manager >/dev/null 2>&1; then
  run "PBS: versao" "proxmox-backup-manager version"
  run "PBS: datastores" "proxmox-backup-manager datastore list"
  run "PBS: jobs de prune (retencao)" "proxmox-backup-manager prune-job list"
  run "PBS: jobs de verify (validacao dos backups)" "proxmox-backup-manager verify-job list"
  run "PBS: jobs de sync (copia off-site)" "proxmox-backup-manager sync-job list"
  run "PBS: tarefas recentes" "proxmox-backup-manager task list --limit 40"
fi

#--------------------------- KVM / LIBVIRT PURO ---------------------------------
if command -v virsh >/dev/null 2>&1 && ! command -v pvesh >/dev/null 2>&1; then
  run "LIBVIRT: VMs (todas)" "virsh list --all"
  for vm in $(virsh list --all --name 2>/dev/null | grep -v '^$'); do
    run "LIBVIRT: snapshots de $vm" "virsh snapshot-list $vm"
  done
  run "LIBVIRT: pools de storage" "virsh pool-list --all --details"
fi

# Cron do hypervisor tambem interessa (scripts caseiros de export/rsync)
run "CRONTAB root do hypervisor" "crontab -l"

echo "Coleta de hypervisor Linux concluida em $OUT."
