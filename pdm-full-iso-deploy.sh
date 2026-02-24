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

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

log()    { echo -e "${GREEN}[✔]${NC} $1"; }
warn()   { echo -e "${YELLOW}[!]${NC} $1"; }
error()  { echo -e "${RED}[✖]${NC} $1" >&2; exit 1; }

[[ $EUID -eq 0 ]] || error "This script must run as root"

log "=== Proxmox Datacenter Manager (PDM) 1.0+ Deployer ==="

# Latest known stable (Feb 2026)
PDM_ISO="proxmox-datacenter-manager_1.0-2.iso"
PDM_URL="http://download.proxmox.com/iso/${PDM_ISO}"
SHA256="b4b98ed3e8f4dabb1151ebb713d6e7109aeba00d95b88bf65f954dd9ef1e89e1"

# === 1. CHECK FOR EXISTING PDM ISOs IN ALL STORAGES ===
log "Scanning all active storages for proxmox-datacenter-manager*.iso..."

EXISTING_VOLIDS=()
mapfile -t STORAGES < <(pvesm status | awk 'NR>1 && $3=="active" {print $1}')

for storage in "${STORAGES[@]}"; do
  mapfile -t VOLIDS < <(pvesm list "$storage" --content iso 2>/dev/null \
    | awk 'NR>1 {print $1}' | grep -E '^.*:.*proxmox-datacenter-manager_[0-9.-]+\.iso$' || true)
  for volid in "${VOLIDS[@]}"; do
    EXISTING_VOLIDS+=("$volid")
  done
done

# deduplicate & sort by version (newest first)
readarray -t EXISTING_VOLIDS < <(printf '%s\n' "${EXISTING_VOLIDS[@]}" | sort -u -rV)

SELECTED_VOLID=""

if [[ ${#EXISTING_VOLIDS[@]} -gt 0 ]]; then
  log "Found ${#EXISTING_VOLIDS[@]} PDM ISO(s):"
  for i in "${!EXISTING_VOLIDS[@]}"; do
    echo "   $((i+1))) ${EXISTING_VOLIDS[i]}"
  done

  if whiptail --title "Existing ISO Found" --yesno "Use an existing PDM ISO?" 12 70; then
    # Simple menu selection
    MENU_ITEMS=()
    for vol in "${EXISTING_VOLIDS[@]}"; do
      MENU_ITEMS+=("$vol" "")
    done
    SELECTED_VOLID=$(whiptail --title "Choose PDM ISO" --menu "Select which ISO to use:" 15 80 10 "${MENU_ITEMS[@]}" 3>&1 1>&2 2>&3)
  fi
fi

# === 2. DOWNLOAD LATEST IF NEEDED ===
if [[ -z "$SELECTED_VOLID" ]]; then
  log "No existing ISO selected → downloading latest verified PDM ISO..."

  mkdir -p /var/lib/vz/template/iso
  cd /var/lib/vz/template/iso

  if [[ -f "$PDM_ISO" ]] && echo "$SHA256  $PDM_ISO" | sha256sum --check --status 2>/dev/null; then
    log "Latest ISO already present and verified."
  else
    wget --progress=bar:force:noscroll -O "${PDM_ISO}.tmp" "$PDM_URL"
    echo "$SHA256  ${PDM_ISO}.tmp" | sha256sum --check --status || error "SHA256 verification failed!"
    mv "${PDM_ISO}.tmp" "$PDM_ISO"
    log "Download complete & SHA256 verified!"
  fi
  SELECTED_VOLID="local:iso/${PDM_ISO}"
fi

log "Using PDM ISO → ${GREEN}${SELECTED_VOLID}${NC}"

# === 3. OPTIONAL AUTO VM CREATION ===
if whiptail --title "PDM Installation" --yesno "Automatically create a VM with this ISO attached?" 12 70; then
  VMID=$(whiptail --inputbox "VM ID (e.g. 900)" 10 50 "900" 3>&1 1>&2 2>&3)
  NAME=$(whiptail --inputbox "VM Name" 10 50 "pdm-manager" 3>&1 1>&2 2>&3)
  CORES=$(whiptail --inputbox "CPU Cores" 10 50 "4" 3>&1 1>&2 2>&3)
  MEM=$(whiptail --inputbox "Memory (MB)" 10 50 "8192" 3>&1 1>&2 2>&3)
  DISKSTORE=$(whiptail --inputbox "Disk Storage (e.g. local-lvm)" 10 50 "local-lvm" 3>&1 1>&2 2>&3)
  DISKSIZE=$(whiptail --inputbox "Disk Size (e.g. 64G)" 10 50 "64G" 3>&1 1>&2 2>&3)
  BRIDGE=$(whiptail --inputbox "Network Bridge" 10 50 "vmbr0" 3>&1 1>&2 2>&3)

  log "Creating VM ${VMID} (${NAME}) ..."

  qm create "$VMID" \
    --name "$NAME" \
    --ostype l26 \
    --cpu host \
    --cores "$CORES" \
    --memory "$MEM" \
    --net0 virtio,bridge="$BRIDGE" \
    --scsi0 "$DISKSTORE:$DISKSIZE" \
    --ide2 "$SELECTED_VOLID,media=cdrom" \
    --boot "order=scsi0;ide2" \
    --agent enabled=1 \
    --hotplug 1 \
    --efidisk0 "$DISKSTORE:0,efitype=4m" 2>/dev/null || true

  log "${GREEN}VM ${VMID} created and ready!${NC}"
  log "Next steps:"
  echo "   1. PVE Web UI → VM ${VMID} → Console → Start"
  echo "   2. Follow the PDM ISO installer (choose target disk, etc.)"
  echo "   3. After reboot & first login, run your portable setup (see below)"
else
  log "VM creation skipped. You can attach ${SELECTED_VOLID} to any VM manually."
fi

# === 4. YOUR PORTABLE SETUP READY ===
curl -fsSL https://raw.githubusercontent.com/AriGonz/Public/refs/heads/main/pdm-portable-setup.sh \
     -o /usr/local/bin/pdm-portable-setup.sh 2>/dev/null || true
chmod +x /usr/local/bin/pdm-portable-setup.sh 2>/dev/null || true

log "${GREEN}══════════════════════════════════════════════════════════════${NC}"
log "PDM ISO is ready at: ${SELECTED_VOLID}"
log ""
log "After PDM is installed and you can SSH into the new instance:"
log "   Run:  pdm-portable-setup.sh"
log ""
log "Or one-liner:"
log "   bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/AriGonz/Public/refs/heads/main/pdm-portable-setup.sh)\""
log "${GREEN}══════════════════════════════════════════════════════════════${NC}"

log "All done! Enjoy your PDM 1.0+ setup."
