#!/usr/bin/env bash

# Copyright (c) 2021-2026 tteck
# Author: tteck (tteckster) - adapted by Grok for PDM
# License: MIT
# https://github.com/community-scripts/ProxmoxVE/raw/main/LICENSE
# Usage: bash -c "$(curl -fsSL https://raw.githubusercontent.com/AriGonz/Public/refs/heads/main/pdm-vm.sh)"

# === VISUAL VERSION .01 + SLEEP 2s (as requested) ===
echo -e "\n${BOLD}${GN}══════════════════════════════════════${CL}"
echo -e "${TAB}${BOLD}${BL}          Script Version${CL} ${GN}.01${CL}"
echo -e "${BOLD}${GN}══════════════════════════════════════${CL}\n"
sleep 2

source /dev/stdin <<<$(curl -fsSL https://raw.githubusercontent.com/community-scripts/ProxmoxVE/main/misc/api.func)

function header_info {
  clear
  cat <<"EOF"
   ____  ____  __  __  ____   ___   ____  _____  __  __ 
  |  _ \|  _ \|  \/  |/ ___| / _ \ / ___|| ____| \ \/ / 
  | |_) | | | | |\/| | |     | | | |\___ \|  _|    \  /  
  |  __/| |_| | |  | | |___  | |_| | ___) | |___   /  \  
  |_|   |____/|_|  |_|\____|  \___/ |____/|_____| /_/\_\ 

         Datacenter Manager 1.0 VM Creator
EOF
}
header_info
echo -e "\n Loading..."

# === VISUAL VERSION .01 + SLEEP 2s (as requested) ===
echo -e "\n${BOLD}${GN}══════════════════════════════════════${CL}"
echo -e "${TAB}${BOLD}${BL}          Script Version${CL} ${GN}.01${CL}"
echo -e "${BOLD}${GN}══════════════════════════════════════${CL}\n"
sleep 2

GEN_MAC=02:$(openssl rand -hex 5 | awk '{print toupper($0)}' | sed 's/\(..\)/\1:/g; s/.$//')
METHOD=""
NSAPP="pdm-vm"
var_os="proxmox"
var_version="datacenter-manager"

YW=$(echo "\033[33m")
BL=$(echo "\033[36m")
RD=$(echo "\033[01;31m")
BGN=$(echo "\033[4;92m")
GN=$(echo "\033[1;92m")
DGN=$(echo "\033[32m")
CL=$(echo "\033[m")
BOLD=$(echo "\033[1m")
BFR="\\r\\033[K"
HOLD=" "
TAB="  "

CM="${TAB}✔️${TAB}${CL}"
CROSS="${TAB}✖️${TAB}${CL}"
INFO="${TAB}💡${TAB}${CL}"
OS="${TAB}🖥️${TAB}${CL}"
DISKSIZE="${TAB}💾${TAB}${CL}"
CPUCORE="${TAB}🧠${TAB}${CL}"
RAMSIZE="${TAB}🛠️${TAB}${CL}"
CONTAINERID="${TAB}🆔${TAB}${CL}"
HOSTNAME="${TAB}🏠${TAB}${CL}"
BRIDGE="${TAB}🌉${TAB}${CL}"
MACADDRESS="${TAB}🔗${TAB}${CL}"
VLANTAG="${TAB}🏷️${TAB}${CL}"
CREATING="${TAB}🚀${TAB}${CL}"
ADVANCED="${TAB}🧩${TAB}${CL}"
DEFAULT="${TAB}⚙️${TAB}${CL}"
GATEWAY="${TAB}🌐${TAB}${CL}"
CONTAINERTYPE="${TAB}📦${TAB}${CL}"

THIN=",discard=on,ssd=1,"
set -e
trap 'error_handler $LINENO "$BASH_COMMAND"' ERR
trap cleanup EXIT
trap 'post_update_to_api "failed" "130"' SIGINT
trap 'post_update_to_api "failed" "143"' SIGTERM
trap 'post_update_to_api "failed" "129"; exit 129' SIGHUP

function error_handler() {
  local exit_code="$?"
  local line_number="$1"
  local command="$2"
  post_update_to_api "failed" "$exit_code"
  local error_message="${RD}[ERROR]${CL} in line ${RD}$line_number${CL}: exit code ${RD}$exit_code${CL}: while executing command ${YW}$command${CL}"
  echo -e "\n$error_message\n"
  cleanup_vmid
}

function get_valid_nextid() {
  local try_id
  try_id=$(pvesh get /cluster/nextid)
  while true; do
    if [ -f "/etc/pve/qemu-server/${try_id}.conf" ] || [ -f "/etc/pve/lxc/${try_id}.conf" ]; then
      try_id=$((try_id + 1))
      continue
    fi
    if lvs --noheadings -o lv_name | grep -qE "(^|[-_])${try_id}($|[-_])"; then
      try_id=$((try_id + 1))
      continue
    fi
    break
  done
  echo "$try_id"
}

function cleanup_vmid() {
  if qm status $VMID &>/dev/null; then
    qm stop $VMID &>/dev/null
    qm destroy $VMID &>/dev/null
  fi
}

function cleanup() {
  local exit_code=$?
  popd >/dev/null
  if [[ "${POST_TO_API_DONE:-}" == "true" && "${POST_UPDATE_DONE:-}" != "true" ]]; then
    if [[ $exit_code -eq 0 ]]; then
      post_update_to_api "done" "none"
    else
      post_update_to_api "failed" "$exit_code"
    fi
  fi
  rm -rf $TEMP_DIR
}

TEMP_DIR=$(mktemp -d)
pushd $TEMP_DIR >/dev/null

if whiptail --backtitle "Proxmox VE Helper Scripts" --title "Proxmox Datacenter Manager VM" --yesno "This will create a New Proxmox Datacenter Manager VM. Proceed?" 10 65; then
  :
else
  header_info && echo -e "${CROSS}${RD}User exited script${CL}\n" && exit
fi

function msg_info() { local msg="$1"; echo -ne "${TAB}${YW}${HOLD}${msg}${HOLD}"; }
function msg_ok() { local msg="$1"; echo -e "${BFR}${CM}${GN}${msg}${CL}"; }
function msg_error() { local msg="$1"; echo -e "${BFR}${CROSS}${RD}${msg}${CL}"; }

function check_root() {
  if [[ "$(id -u)" -ne 0 || $(ps -o comm= -p $PPID) == "sudo" ]]; then
    clear; msg_error "Please run this script as root."; echo -e "\nExiting..."; sleep 2; exit
  fi
}

pve_check() {
  local PVE_VER="$(pveversion | awk -F'/' '{print $2}' | awk -F'-' '{print $1}')"
  if [[ "$PVE_VER" =~ ^8\.([0-9]+) && "${BASH_REMATCH[1]}" -le 9 ]] || [[ "$PVE_VER" =~ ^9\.(0|1) ]]; then
    return 0
  fi
  msg_error "This version of Proxmox VE is not supported."
  exit 1
}

function arch_check() {
  if [ "$(dpkg --print-architecture)" != "amd64" ]; then
    echo -e "\n ${INFO}This script will not work with PiMox!\n"; exit
  fi
}

function ssh_check() {
  if command -v pveversion >/dev/null && [ -n "${SSH_CLIENT:+x}" ]; then
    if whiptail --backtitle "Proxmox VE Helper Scripts" --title "SSH DETECTED" --yesno "It's suggested to use the Proxmox shell instead of SSH. Proceed anyway?" 10 62; then
      :
    else
      exit
    fi
  fi
}

function exit-script() {
  clear; echo -e "\n${CROSS}${RD}User exited script${CL}\n"; exit
}

function default_settings() {
  VMID=$(get_valid_nextid)
  FORMAT=",efitype=4m"
  MACHINE=""
  DISK_SIZE="32G"
  DISK_CACHE=""
  HN="pdm"
  CPU_TYPE=""
  CORE_COUNT="4"
  RAM_SIZE="8192"
  BRG="vmbr0"
  MAC="$GEN_MAC"
  VLAN=""
  MTU=""
  START_VM="yes"
  METHOD="default"
  echo -e "${CONTAINERID}${BOLD}${DGN}Virtual Machine ID: ${BGN}${VMID}${CL}"
  echo -e "${CONTAINERTYPE}${BOLD}${DGN}Machine Type: ${BGN}i440fx${CL}"
  echo -e "${DISKSIZE}${BOLD}${DGN}Disk Size: ${BGN}${DISK_SIZE}${CL}"
  echo -e "${DISKSIZE}${BOLD}${DGN}Disk Cache: ${BGN}None${CL}"
  echo -e "${HOSTNAME}${BOLD}${DGN}Hostname: ${BGN}${HN}${CL}"
  echo -e "${OS}${BOLD}${DGN}CPU Model: ${BGN}KVM64${CL}"
  echo -e "${CPUCORE}${BOLD}${DGN}CPU Cores: ${BGN}${CORE_COUNT}${CL}"
  echo -e "${RAMSIZE}${BOLD}${DGN}RAM Size: ${BGN}${RAM_SIZE}${CL}"
  echo -e "${BRIDGE}${BOLD}${DGN}Bridge: ${BGN}${BRG}${CL}"
  echo -e "${MACADDRESS}${BOLD}${DGN}MAC Address: ${BGN}${MAC}${CL}"
  echo -e "${VLANTAG}${BOLD}${DGN}VLAN: ${BGN}Default${CL}"
  echo -e "${DEFAULT}${BOLD}${DGN}Interface MTU Size: ${BGN}Default${CL}"
  echo -e "${GATEWAY}${BOLD}${DGN}Start VM when completed: ${BGN}yes${CL}"
  echo -e "${CREATING}${BOLD}${DGN}Creating a Proxmox Datacenter Manager VM using the above default settings${CL}"
}

function advanced_settings() {
  METHOD="advanced"
  [ -z "${VMID:-}" ] && VMID=$(get_valid_nextid)
  while true; do
    if VMID=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Set Virtual Machine ID" 8 58 $VMID --title "VIRTUAL MACHINE ID" --cancel-button Exit-Script 3>&1 1>&2 2>&3); then
      if [ -z "$VMID" ]; then VMID=$(get_valid_nextid); fi
      if pct status "$VMID" &>/dev/null || qm status "$VMID" &>/dev/null; then
        echo -e "${CROSS}${RD} ID $VMID is already in use${CL}"; sleep 2; continue
      fi
      echo -e "${CONTAINERID}${BOLD}${DGN}Virtual Machine ID: ${BGN}$VMID${CL}"
      break
    else exit-script; fi
  done

  if MACH=$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "MACHINE TYPE" --radiolist --cancel-button Exit-Script "Choose Type" 10 58 2 \
    "i440fx" "Machine i440fx" ON \
    "q35" "Machine q35" OFF 3>&1 1>&2 2>&3); then
    if [ "$MACH" = q35 ]; then
      FORMAT=""; MACHINE=" -machine q35"
    else
      FORMAT=",efitype=4m"; MACHINE=""
    fi
    echo -e "${CONTAINERTYPE}${BOLD}${DGN}Machine Type: ${BGN}$MACH${CL}"
  else exit-script; fi

  DISK_SIZE=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Set Disk Size (e.g. 32G)" 8 58 "32G" --title "DISK SIZE" --cancel-button Exit-Script 3>&1 1>&2 2>&3) || exit-script
  echo -e "${DISKSIZE}${BOLD}${DGN}Disk Size: ${BGN}${DISK_SIZE}${CL}"

  if DISK_CACHE=$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "DISK CACHE" --radiolist --cancel-button Exit-Script "Choose Cache" 12 58 5 \
    "none" "No caching" ON \
    "writeback" "Writeback" OFF \
    "writethrough" "Writethrough" OFF \
    "directsync" "Directsync" OFF \
    "unsafe" "Unsafe" OFF 3>&1 1>&2 2>&3); then
    [ "$DISK_CACHE" != "none" ] && DISK_CACHE=",cache=$DISK_CACHE" || DISK_CACHE=""
    echo -e "${DISKSIZE}${BOLD}${DGN}Disk Cache: ${BGN}${DISK_CACHE:-None}${CL}"
  else exit-script; fi

  HN=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Set Hostname" 8 58 "pdm" --title "HOSTNAME" --cancel-button Exit-Script 3>&1 1>&2 2>&3) || exit-script
  echo -e "${HOSTNAME}${BOLD}${DGN}Hostname: ${BGN}$HN${CL}"

  CPU_MODEL=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "CPU Model (blank = kvm64)" 8 58 "" --title "CPU MODEL" --cancel-button Exit-Script 3>&1 1>&2 2>&3) || exit-script
  [ -n "$CPU_MODEL" ] && CPU_TYPE=" -cpu $CPU_MODEL" || CPU_TYPE=""
  echo -e "${OS}${BOLD}${DGN}CPU Model: ${BGN}${CPU_MODEL:-kvm64}${CL}"

  CORE_COUNT=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "CPU Cores" 8 58 "4" --title "CPU CORES" --cancel-button Exit-Script 3>&1 1>&2 2>&3) || exit-script
  RAM_SIZE=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "RAM Size (MiB)" 8 58 "8192" --title "RAM SIZE" --cancel-button Exit-Script 3>&1 1>&2 2>&3) || exit-script
  BRG=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "Bridge" 8 58 "vmbr0" --title "BRIDGE" --cancel-button Exit-Script 3>&1 1>&2 2>&3) || exit-script
  MAC=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "MAC Address (blank = random)" 8 58 "$GEN_MAC" --title "MAC ADDRESS" --cancel-button Exit-Script 3>&1 1>&2 2>&3) || exit-script
  VLAN=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "VLAN Tag (blank = none)" 8 58 "" --title "VLAN" --cancel-button Exit-Script 3>&1 1>&2 2>&3) || exit-script
  [ -n "$VLAN" ] && VLAN=",tag=$VLAN"
  MTU=$(whiptail --backtitle "Proxmox VE Helper Scripts" --inputbox "MTU (blank = default)" 8 58 "" --title "MTU" --cancel-button Exit-Script 3>&1 1>&2 2>&3) || exit-script
  [ -n "$MTU" ] && MTU=",mtu=$MTU"
  if whiptail --backtitle "Proxmox VE Helper Scripts" --title "START VM" --yesno "Start VM when finished?" 10 58; then START_VM="yes"; else START_VM="no"; fi

  echo -e "${CREATING}${BOLD}${DGN}Creating a Proxmox Datacenter Manager VM using the above advanced settings${CL}"
}

function start_script() {
  if whiptail --backtitle "Proxmox VE Helper Scripts" --title "SETTINGS" --yesno "Use Default Settings?" 10 58; then
    default_settings
  else
    advanced_settings
  fi
}

check_root
arch_check
pve_check
ssh_check
start_script

# Storage selection (exact from tteck)
msg_info "Validating Storage"
STORAGE_MENU=()
MSG_MAX_LENGTH=0
while read -r line; do
  TAG=$(echo $line | awk '{print $1}')
  TYPE=$(echo $line | awk '{printf "%-10s", $2}')
  FREE=$(echo $line | numfmt --field 4-6 --from-unit=K --to=iec --format %.2f | awk '{printf( "%9sB", $6)}')
  ITEM="  Type: $TYPE Free: $FREE "
  OFFSET=2
  if [[ $((${#ITEM} + $OFFSET)) -gt ${MSG_MAX_LENGTH:-} ]]; then MSG_MAX_LENGTH=$((${#ITEM} + $OFFSET)); fi
  STORAGE_MENU+=("$TAG" "$ITEM" "OFF")
done < <(pvesm status -content images | awk 'NR>1')
VALID=$(pvesm status -content images | awk 'NR>1')
if [ -z "$VALID" ]; then msg_error "Unable to detect a valid storage location."; exit
elif [ $((${#STORAGE_MENU[@]} / 3)) -eq 1 ]; then STORAGE=${STORAGE_MENU[0]}
else
  while [ -z "${STORAGE:+x}" ]; do
    STORAGE=$(whiptail --backtitle "Proxmox VE Helper Scripts" --title "Storage Pools" --radiolist "Which storage pool would you like to use?" 16 $(($MSG_MAX_LENGTH + 23)) 6 "${STORAGE_MENU[@]}" 3>&1 1>&2 2>&3)
  done
fi
msg_ok "Using ${CL}${BL}$STORAGE${CL} ${GN}for Storage Location."

# === LOCAL ISO CHECK ===
ISO="proxmox-datacenter-manager_1.0-2.iso"
ISO_DIR="/var/lib/vz/template/iso"
ISO_PATH="${ISO_DIR}/${ISO}"
SHA256="b4b98ed3e8f4dabb1151ebb713d6e7109aeba00d95b88bf65f954dd9ef1e89e1"

mkdir -p "$ISO_DIR"
if [[ -f "$ISO_PATH" ]]; then
  msg_ok "ISO already available locally → ${ISO_PATH}"
else
  msg_info "Downloading Proxmox Datacenter Manager 1.0-2 ISO (~1.48 GB)"
  wget -q --show-progress -O "$ISO_PATH" "https://download.proxmox.com/iso/${ISO}" || { msg_error "Download failed"; exit 1; }
  msg_ok "ISO downloaded"
fi
msg_info "Verifying SHA256 checksum"
if echo "${SHA256}  ${ISO_PATH}" | sha256sum --check --status; then
  msg_ok "Checksum OK"
else
  msg_error "Checksum failed! Delete ${ISO_PATH} and re-run."
  exit 1
fi

# === VM CREATION ===
msg_info "Creating Proxmox Datacenter Manager VM"
qm create $VMID -agent 1${MACHINE} -tablet 0 -localtime 1 -bios ovmf -cores $CORE_COUNT -memory $RAM_SIZE \
  -name $HN -net0 virtio,bridge=$BRG,macaddr=$MAC$VLAN$MTU -onboot 1 -ostype l26 -scsihw virtio-scsi-pci${CPU_TYPE}

qm set $VMID -efidisk0 ${STORAGE}:1${FORMAT} >/dev/null
qm set $VMID -scsi0 ${STORAGE}:0,size=${DISK_SIZE}${DISK_CACHE}${THIN} >/dev/null
qm set $VMID -ide2 local:iso/${ISO},media=cdrom >/dev/null
qm set $VMID -boot order=ide2\;scsi0 >/dev/null

DESCRIPTION=$(cat <<'EOF'
<h1>Proxmox Datacenter Manager 1.0</h1>
<p>Created with tteck/community-scripts style helper (v.01).</p>
<p><b>Next step:</b> Start the VM → open console → run the graphical installer (choose scsi0).</p>
<p>Web UI: <b>https://VM-IP:8443</b></p>
EOF
)
qm set $VMID -description "$DESCRIPTION" >/dev/null

msg_ok "VM ${VMID} created successfully!"

if [[ "$START_VM" == "yes" ]]; then
  msg_info "Starting VM (boots into installer)"
  qm start $VMID
  msg_ok "VM started → open console in Proxmox GUI"
else
  msg_ok "VM ready — start it manually"
fi

echo -e "\n${INFO}After the installer finishes the VM will reboot into PDM."
echo -e "${INFO}Default web interface: ${GN}https://<VM-IP>:8443${CL}"
post_update_to_api "done" "none"
