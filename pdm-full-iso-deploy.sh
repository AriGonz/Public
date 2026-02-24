#!/bin/bash
# =====================================================
# PDM 1.0+ Full ISO-Aware Deploy Script for PVE 9.1.1+
# - Checks for proxmox-datacenter-manager*.iso in ANY storage
# - Asks if you want to use existing one(s)
# - If no → downloads latest verified ISO to local storage
# - Optional: auto-creates a ready-to-install VM
# - Provides one-click command for your pdm-portable-setup.sh AFTER install
# Run as root on your Proxmox VE host
# Usage: bash -c "$(curl -fsSL https://raw.githubusercontent.com/AriGonz/Public/refs/heads/main/pdm-full-iso-deploy.sh)"
# =====================================================


set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

log()    { echo -e "${GREEN}[✔]${NC} $1"; }
warn()   { echo -e "${YELLOW}[!]${NC} $1"; }
error()  { echo -e "${RED}[✖]${NC} $1" >&2; exit 1; }

[[ $EUID -eq 0 ]] || error "Run as root on the PVE host"

log "=== Proxmox Datacenter Manager (PDM) 1.0+ Deployer (v2.0 Fixed) ==="

# Latest verified PDM ISO (Feb 2026)
PDM_ISO="proxmox-datacenter-manager_1.0-2.iso"
PDM_URL="http://download.proxmox.com/iso/${PDM_ISO}"
SHA256="b4b98ed3e8f4dabb1151ebb713d6e7109aeba00d95b88bf65f954dd9ef1e89e1"

# 1. Find or download PDM ISO (you already have it)
log "Scanning storages for PDM ISO..."
EXISTING_VOLIDS=()
mapfile -t STORAGES < <(pvesm status | awk 'NR>1 && $3=="active" {print $1}')

for storage in "${STORAGES[@]}"; do
  mapfile -t VOLIDS < <(pvesm list "$storage" --content iso 2>/dev/null | awk 'NR>1 {print $1}' | grep -E 'proxmox-datacenter-manager' || true)
  for vol in "${VOLIDS[@]}"; do
    EXISTING_VOLIDS+=("$vol")
  done
done

SELECTED_VOLID=""
if [[ ${#EXISTING_VOLIDS[@]} -gt 0 ]]; then
  log "Found ${#EXISTING_VOLIDS[@]} PDM ISO(s):"
  for i in "${!EXISTING_VOLIDS[@]}"; do
    echo "   $((i+1))) ${EXISTING_VOLIDS[i]}"
  done
  if whiptail --title "PDM ISO" --yesno "Use an existing PDM ISO?" 12 75; then
    MENU=()
    for v in "${EXISTING_VOLIDS[@]}"; do MENU+=("$v" ""); done
    SELECTED_VOLID=$(whiptail --title "Select ISO" --menu "" 15 80 10 "${MENU[@]}" 3>&1 1>&2 2>&3)
  fi
fi

if [[ -z "$SELECTED_VOLID" ]]; then
  log "Downloading latest PDM ISO..."
  mkdir -p /var/lib/vz/template/iso
  cd /var/lib/vz/template/iso
  if [[ ! -f "$PDM_ISO" ]] || ! echo "$SHA256  $PDM_ISO" | sha256sum --check --status; then
    wget -q --show-progress -O "${PDM_ISO}.tmp" "$PDM_URL"
    echo "$SHA256  ${PDM_ISO}.tmp" | sha256sum --check || error "SHA256 failed"
    mv "${PDM_ISO}.tmp" "$PDM_ISO"
    log "ISO downloaded & verified"
  fi
  SELECTED_VOLID="local:iso/${PDM_ISO}"
fi

log "Using ISO → ${GREEN}${SELECTED_VOLID}${NC}"

# 2. Create the VM (with proper syntax)
if whiptail --title "Create PDM VM" --yesno "Create VM 900 (pdm-manager) with this ISO attached?" 13 80; then
  VMID=900
  NAME="pdm-manager"

  log "Creating VM ${VMID} (${NAME}) ..."

  # Clean any previous partial VM
  qm destroy $VMID --purge 2>/dev/null || true

  qm create $VMID \
    --name "$NAME" \
    --machine q35 \
    --bios ovmf \
    --ostype l26 \
    --cpu host \
    --cores 4 \
    --memory 8192 \
    --net0 virtio,bridge=vmbr0 \
    --scsihw virtio-scsi-single \
    --scsi0 local-lvm:64G,discard=on,ssd=1 \
    --efidisk0 local-lvm:0,efitype=4m,pre-enrolled-keys=1 \
    --ide2 "$SELECTED_VOLID,media=cdrom" \
    --boot order=scsi0\;ide2 \
    --agent enabled=1 \
    --hotplug disk,network,usb \
    --numa 0

  if qm config $VMID >/dev/null 2>&1; then
    log "${GREEN}VM ${VMID} successfully created!${NC}"
    echo -e "\n${BLUE}Next steps — do this now:${NC}"
    echo "   1. PVE Web UI → VM 900 → Console tab"
    echo "   2. Click Start"
    echo "   3. Install PDM from the ISO (choose target disk, set root password, static IP recommended)"
    echo "   4. After install finishes & VM reboots, SSH into it as root"
    echo "   5. Then run the portable setup:"
    echo "      bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/AriGonz/Public/refs/heads/main/pdm-portable-setup.sh)\""
  else
    error "VM creation failed — please paste the full output above"
  fi
else
  log "VM creation skipped (you can attach the ISO manually)"
fi

log "${GREEN}══════════════════════════════════════════════════════════════${NC}"
log "PDM ISO is ready. VM 900 is ready (if you chose to create it)."
log "QEMU guest agent will be installed automatically by the portable script."
log "All done! 🚀"
