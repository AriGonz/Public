#!/bin/bash
# =============================================================
# Proxmox VE — Portable OPNsense Firewall Setup Script
# Repo: github.com/AriGonz/Public
# Usage: bash -c "$(curl -fsSL https://raw.githubusercontent.com/AriGonz/Public/main/proxmox-opnsense-setup.sh)"
# =============================================================

set -euo pipefail

# ── Colors ────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

info()    { echo -e "${GREEN}[+]${NC} $1"; }
warn()    { echo -e "${YELLOW}[!]${NC} $1"; }
error()   { echo -e "${RED}[✗]${NC} $1"; exit 1; }
step()    { echo -e "\n${BLUE}${BOLD}━━━ $1 ━━━${NC}"; }
success() { echo -e "${GREEN}[✓]${NC} $1"; }

# ── Fixed Config ──────────────────────────────────────────────
OPNSENSE_VER="26.1"
VM_RAM=2048
VM_CORES=2
WAN_BRIDGE="vmbr1"
LAN_BRIDGE="vmbr0"
DISK_SIZE="32G"
STORAGE="local-lvm"
ISO_STORAGE="local"
LAN_GW="192.168.1.1"
LAN_HOST_IP="192.168.1.254"
LAN_SUBNET="24"
SSH_KEY="ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHgzljgx9gDLlln3EEE/vcPvr9NMz7kLiLraofNzeQoO pve-xx"
NETBIRD_MGMT="https://netbird.arigonz.com"
ISO_FILE="OPNsense-${OPNSENSE_VER}-dvd-amd64.iso"
ISO_BZ2="${ISO_FILE}.bz2"
ISO_PATH="/var/lib/vz/template/iso/${ISO_FILE}"
ISO_URL="https://pkg.opnsense.org/releases/${OPNSENSE_VER}/${ISO_BZ2}"
SKIP_WIFI=false

# =============================================================
# PHASE 1 — USER INPUT
# =============================================================
step "PHASE 1: Configuration"

CURRENT_HOSTNAME=$(hostname)
read -rp "$(echo -e "${CYAN}Proxmox hostname${NC} [${CURRENT_HOSTNAME}]: ")" INPUT_HOSTNAME
HOSTNAME="${INPUT_HOSTNAME:-$CURRENT_HOSTNAME}"

read -rp "$(echo -e "${CYAN}OPNsense VM ID${NC} [100]: ")" INPUT_VMID
VM_ID="${INPUT_VMID:-100}"
# Validate VM ID is a number
[[ "$VM_ID" =~ ^[0-9]+$ ]] || error "VM ID must be a number"

read -rp "$(echo -e "${CYAN}WiFi SSID${NC} [${HOSTNAME}]: ")" INPUT_SSID
WIFI_SSID="${INPUT_SSID:-$HOSTNAME}"

echo ""
echo -e "${BOLD}Configuration Summary:${NC}"
echo -e "  Hostname     : ${CYAN}${HOSTNAME}${NC}"
echo -e "  OPNsense VM  : ${CYAN}${VM_ID}${NC}"
echo -e "  WiFi SSID    : ${CYAN}${WIFI_SSID}${NC}"
echo -e "  LAN IP       : ${CYAN}${LAN_HOST_IP}/${LAN_SUBNET}${NC}"
echo -e "  OPNsense IP  : ${CYAN}${LAN_GW}${NC}"
echo ""
read -rp "$(echo -e "${YELLOW}Proceed with setup? [y/N]:${NC} ")" CONFIRM
[[ "${CONFIRM,,}" == "y" ]] || error "Aborted by user"

# =============================================================
# PHASE 2 — PRE-CHECKS
# =============================================================
step "PHASE 2: Pre-checks"

CHECKS_PASSED=true

pass_check()  { success "$1"; }
warn_check()  { warn "$1 — $2"; }
fail_check()  { echo -e "${RED}[✗]${NC} $1 — $2"; CHECKS_PASSED=false; }

# Root
[[ $EUID -eq 0 ]] && pass_check "Running as root" || fail_check "Running as root" "Must run as root"

# Proxmox
if command -v pveversion &>/dev/null; then
    PVE_VER=$(pveversion | head -1)
    pass_check "Proxmox VE detected (${PVE_VER})"
else
    fail_check "Proxmox VE detected" "pveversion not found — is this a Proxmox host?"
fi

# NIC count (exclude loopback, bridges, VPN, tap devices)
mapfile -t PHYS_NICS < <(ip link show | awk -F': ' '/^[0-9]+:/{print $2}' | cut -d@ -f1 | \
    grep -vE '^(lo|vmbr|wt|tap|docker|virbr|bond|dummy)')
NIC_COUNT=${#PHYS_NICS[@]}
if [[ $NIC_COUNT -ge 2 ]]; then
    pass_check "NIC count (${NIC_COUNT} NICs detected)"
else
    fail_check "NIC count" "Need at least 2 NICs, found ${NIC_COUNT}. A USB NIC is acceptable."
fi

# Internet
if curl -sf --connect-timeout 5 https://pkg.opnsense.org &>/dev/null; then
    pass_check "Internet access (pkg.opnsense.org reachable)"
else
    fail_check "Internet access" "Cannot reach pkg.opnsense.org"
fi

# VM ID free
if qm status "$VM_ID" &>/dev/null 2>&1; then
    fail_check "VM ID ${VM_ID} is free" "VM ${VM_ID} already exists — re-run and choose a different ID"
else
    pass_check "VM ID ${VM_ID} is free"
fi

# vmbr1 doesn't exist
if ip link show "$WAN_BRIDGE" &>/dev/null 2>&1; then
    fail_check "${WAN_BRIDGE} does not already exist" "${WAN_BRIDGE} already exists"
else
    pass_check "${WAN_BRIDGE} does not already exist"
fi

# ISO storage space (need 2.5GB = 2621440 KB)
ISO_DIR="/var/lib/vz/template/iso"
ISO_FREE_KB=$(df "$ISO_DIR" | awk 'NR==2 {print $4}')
ISO_FREE_GB=$(awk "BEGIN {printf \"%.1f\", ${ISO_FREE_KB}/1048576}")
if [[ $ISO_FREE_KB -ge 2621440 ]]; then
    pass_check "ISO storage (${ISO_FREE_GB}GB free, need 2.5GB)"
else
    fail_check "ISO storage" "Only ${ISO_FREE_GB}GB free in ${ISO_DIR}, need 2.5GB"
fi

# LVM pool space (need 35GB = 36700160 KB)
# pvesm status columns: Name Type Status Total Used Available %
# $6 = Available
LVM_FREE_KB=$(pvesm status 2>/dev/null | awk '/local-lvm/{print $6}')
if [[ -n "$LVM_FREE_KB" && "$LVM_FREE_KB" -ge 36700160 ]]; then
    LVM_FREE_GB=$(awk "BEGIN {printf \"%.1f\", ${LVM_FREE_KB}/1048576}")
    pass_check "LVM pool space (${LVM_FREE_GB}GB free, need 35GB)"
else
    LVM_FREE_GB=$(awk "BEGIN {printf \"%.1f\", ${LVM_FREE_KB:-0}/1048576}")
    fail_check "LVM pool space" "Only ${LVM_FREE_GB}GB free in local-lvm, need 35GB"
fi

# Root filesystem health (warn if >80%)
ROOT_USED=$(df / | awk 'NR==2 {print $5}' | tr -d '%')
if [[ $ROOT_USED -lt 80 ]]; then
    pass_check "Root filesystem (${ROOT_USED}% used)"
else
    warn_check "Root filesystem (${ROOT_USED}% used)" "Consider freeing space before continuing"
fi

# WiFi AP mode support
WIFI_NIC=""
while IFS= read -r nic; do
    PHY_IDX=$(cat /sys/class/net/"$nic"/phy80211/index 2>/dev/null || echo "")
    [[ -z "$PHY_IDX" ]] && continue
    if iw "phy${PHY_IDX}" info 2>/dev/null | grep -q "AP"; then
        WIFI_NIC="$nic"
        break
    fi
done < <(find /sys/class/net -maxdepth 1 -name 'wl*' -o -name 'wlo*' 2>/dev/null | xargs -I{} basename {})

if [[ -n "$WIFI_NIC" ]]; then
    pass_check "WiFi NIC supports AP mode (${WIFI_NIC})"
else
    warn_check "WiFi AP mode" "No WiFi NIC with AP support found — WiFi AP will be skipped"
    SKIP_WIFI=true
fi

# Abort if any check failed
if [[ "$CHECKS_PASSED" != "true" ]]; then
    echo ""
    error "One or more pre-checks failed. Fix the issues above and re-run."
fi

echo ""
info "All pre-checks passed! Starting setup..."
sleep 2

# =============================================================
# NIC SELECTION
# =============================================================
step "NIC Selection"

echo -e "\n${BOLD}Available network interfaces:${NC}\n"
declare -A NIC_MAP
i=1
while IFS= read -r nic; do
    MAC=$(cat /sys/class/net/"$nic"/address 2>/dev/null || echo "unknown")
    STATE=$(cat /sys/class/net/"$nic"/operstate 2>/dev/null || echo "unknown")
    [[ "$STATE" == "up" ]] && STATE_COLOR="${GREEN}${STATE}${NC}" || STATE_COLOR="${RED}${STATE}${NC}"
    printf "  [%d] %-12s  %s  " "$i" "$nic" "$MAC"
    echo -e "${STATE_COLOR}"
    NIC_MAP[$i]="$nic"
    ((i++))
done < <(printf '%s\n' "${PHYS_NICS[@]}")

echo ""
read -rp "$(echo -e "${CYAN}Select WAN NIC number${NC} (connects to internet/router): ")" WAN_NUM
WAN_NIC="${NIC_MAP[$WAN_NUM]:-}"
[[ -z "$WAN_NIC" ]] && error "Invalid WAN NIC selection"

read -rp "$(echo -e "${CYAN}Select LAN NIC number${NC} (connects to your devices): ")" LAN_NUM
LAN_NIC="${NIC_MAP[$LAN_NUM]:-}"
[[ -z "$LAN_NIC" ]] && error "Invalid LAN NIC selection"
[[ "$WAN_NIC" == "$LAN_NIC" ]] && error "WAN and LAN cannot be the same NIC"

info "WAN: ${WAN_NIC} → ${WAN_BRIDGE}"
info "LAN: ${LAN_NIC} → ${LAN_BRIDGE}"

# =============================================================
# PHASE 3 — PROXMOX POST-INSTALL
# =============================================================
step "PHASE 3: Proxmox Post-Install"

# Hostname
info "Setting hostname to ${HOSTNAME}"
hostnamectl set-hostname "$HOSTNAME"
echo "$HOSTNAME" > /etc/hostname
sed -i "s/127\.0\.1\.1.*/127.0.1.1\t${HOSTNAME}/" /etc/hosts 2>/dev/null || \
    echo "127.0.1.1	${HOSTNAME}" >> /etc/hosts

# Disable enterprise repos
info "Disabling enterprise repos"
[[ -f /etc/apt/sources.list.d/pve-enterprise.list ]] && \
    sed -i 's/^deb/#deb/' /etc/apt/sources.list.d/pve-enterprise.list
[[ -f /etc/apt/sources.list.d/ceph.list ]] && \
    sed -i 's/^deb/#deb/' /etc/apt/sources.list.d/ceph.list

# Enable no-subscription repo
info "Enabling no-subscription repo"
PVE_CODENAME=$(grep VERSION_CODENAME /etc/os-release | cut -d= -f2)
NO_SUB_REPO="deb http://download.proxmox.com/debian/pve ${PVE_CODENAME} pve-no-subscription"
if ! grep -qF "pve-no-subscription" /etc/apt/sources.list 2>/dev/null; then
    echo "$NO_SUB_REPO" >> /etc/apt/sources.list
    info "No-subscription repo added"
else
    warn "No-subscription repo already present"
fi

# Remove subscription nag
info "Removing subscription nag"
JS_FILE="/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js"
if [[ -f "$JS_FILE" ]]; then
    cp "${JS_FILE}" "${JS_FILE}.bak"
    sed -i.bak "s/data\.status !== 'Active'/false/g" "$JS_FILE" && \
        info "Subscription nag removed" || warn "Could not patch subscription nag"
else
    warn "proxmoxlib.js not found — skipping nag removal"
fi

# Update packages
info "Running apt full-upgrade (this may take a while)..."
apt-get update -qq
DEBIAN_FRONTEND=noninteractive apt-get full-upgrade -y -q
apt-get autoremove -y -qq
info "System updated"

# SSH key
info "Adding SSH key"
mkdir -p /root/.ssh
chmod 700 /root/.ssh
touch /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys
if ! grep -qF "pve-xx" /root/.ssh/authorized_keys; then
    echo "$SSH_KEY" >> /root/.ssh/authorized_keys
    info "SSH key added"
else
    warn "SSH key already present"
fi

# =============================================================
# PHASE 4 — NETWORK CONFIGURATION
# =============================================================
step "PHASE 4: Network Configuration"

info "Backing up current network config"
cp /etc/network/interfaces /etc/network/interfaces.bak.$(date +%Y%m%d%H%M%S)

info "Writing new /etc/network/interfaces"
cat > /etc/network/interfaces << EOF
auto lo
iface lo inet loopback

iface ${WAN_NIC} inet manual

iface ${LAN_NIC} inet manual

auto ${WAN_BRIDGE}
iface ${WAN_BRIDGE} inet manual
	bridge-ports ${WAN_NIC}
	bridge-stp off
	bridge-fd 0
	bridge-vlan-aware no

auto ${LAN_BRIDGE}
iface ${LAN_BRIDGE} inet static
	address ${LAN_HOST_IP}/${LAN_SUBNET}
	gateway ${LAN_GW}
	bridge-ports ${LAN_NIC}
	bridge-stp off
	bridge-fd 0

source /etc/network/interfaces.d/*
EOF

info "Network config written"

# =============================================================
# PHASE 5 — WIFI ACCESS POINT
# =============================================================
if [[ "$SKIP_WIFI" == "false" ]]; then
    step "PHASE 5: WiFi Access Point"

    while true; do
        read -rsp "$(echo -e "${CYAN}WiFi password for '${WIFI_SSID}'${NC} (min 8 chars): ")" WIFI_PASS
        echo
        [[ ${#WIFI_PASS} -ge 8 ]] && break
        warn "Password must be at least 8 characters, try again"
    done

    info "Installing hostapd"
    DEBIAN_FRONTEND=noninteractive apt-get install -y -q hostapd

    info "Configuring WiFi AP — SSID: ${WIFI_SSID}"
    cat > /etc/hostapd/hostapd.conf << EOF
interface=${WIFI_NIC}
bridge=${LAN_BRIDGE}
driver=nl80211
ssid=${WIFI_SSID}
hw_mode=g
channel=6
wmm_enabled=0
macaddr_acl=0
auth_algs=1
ignore_broadcast_ssid=0
wpa=2
wpa_passphrase=${WIFI_PASS}
wpa_key_mgmt=WPA-PSK
wpa_pairwise=TKIP
rsn_pairwise=CCMP
EOF

    sed -i 's|#DAEMON_CONF=""|DAEMON_CONF="/etc/hostapd/hostapd.conf"|' /etc/default/hostapd
    systemctl unmask hostapd
    systemctl enable hostapd
    info "WiFi AP configured (will start after network cutover)"
else
    step "PHASE 5: WiFi Access Point — SKIPPED (no compatible WiFi NIC)"
fi

# =============================================================
# PHASE 6 — OPNSENSE VM
# =============================================================
step "PHASE 6: OPNsense VM"

# Download ISO
if [[ -f "$ISO_PATH" ]]; then
    warn "OPNsense ISO already exists at ${ISO_PATH} — skipping download"
else
    info "Downloading OPNsense ${OPNSENSE_VER} ISO..."
    wget -q --show-progress -O "/var/lib/vz/template/iso/${ISO_BZ2}" "$ISO_URL"
    info "Extracting ISO..."
    bunzip2 -k "/var/lib/vz/template/iso/${ISO_BZ2}"
    rm -f "/var/lib/vz/template/iso/${ISO_BZ2}"
    info "ISO ready: ${ISO_PATH}"
fi

# Create VM
info "Creating OPNsense VM (ID: ${VM_ID})"
qm create "$VM_ID" \
    --name "opnsense" \
    --memory "$VM_RAM" \
    --cores "$VM_CORES" \
    --cpu host \
    --machine q35 \
    --bios ovmf \
    --ostype other \
    --net0 virtio,bridge="${WAN_BRIDGE}" \
    --net1 virtio,bridge="${LAN_BRIDGE}" \
    --cdrom "${ISO_STORAGE}:iso/${ISO_FILE}" \
    --boot order=ide2 \
    --onboot 1 \
    --startup order=1,up=60

# Disks
pvesm alloc "$STORAGE" "$VM_ID" "vm-${VM_ID}-disk-0" "$DISK_SIZE"
qm set "$VM_ID" --scsi0 "${STORAGE}:vm-${VM_ID}-disk-0"
qm set "$VM_ID" --efidisk0 "${STORAGE}:0,efitype=4m"
qm set "$VM_ID" --boot order="ide2;scsi0"

info "OPNsense VM ${VM_ID} created"

# Start VM
info "Starting OPNsense VM..."
qm start "$VM_ID"
sleep 3
qm status "$VM_ID"
info "OPNsense is booting"

# =============================================================
# PHASE 7 — NETBIRD
# =============================================================
step "PHASE 7: Netbird"

info "Installing Netbird..."
curl -fsSL https://pkgs.netbird.io/install.sh | bash

info "Connecting to Netbird management server..."
netbird up --management-url "$NETBIRD_MGMT" &
NETBIRD_PID=$!
sleep 8

echo ""
echo -e "${YELLOW}${BOLD}━━━ Netbird Authorization Required ━━━${NC}"
echo -e "Run the following command to get your auth URL:"
echo -e "  ${CYAN}netbird status${NC}"
echo -e "Then open the URL shown to authorize this device at:"
echo -e "  ${CYAN}${NETBIRD_MGMT}${NC}"
echo ""

# =============================================================
# PHASE 8 — NETWORK CUTOVER
# =============================================================
step "PHASE 8: Network Cutover"

echo ""
warn "This is the final step."
warn "The network configuration will now change:"
warn "  Current : $(ip route | awk '/default/{print $3}') (old gateway)"
warn "  New     : ${LAN_HOST_IP}/${LAN_SUBNET} via ${LAN_BRIDGE}"
warn "  Gateway : ${LAN_GW} (OPNsense)"
echo ""
warn "Your current SSH session WILL DROP after this step."
warn "Reconnect by plugging into the LAN port (${LAN_NIC})"
warn "New Proxmox address: ${LAN_HOST_IP}  port 8006"
echo ""
read -rp "$(echo -e "${RED}${BOLD}Press ENTER to apply network changes (or Ctrl+C to abort)...${NC}")" _

# Schedule network restart in background so script can finish printing
(sleep 3 && ifreload -a 2>/dev/null || (ifdown --force "${LAN_BRIDGE}" 2>/dev/null; ifup "${LAN_BRIDGE}" 2>/dev/null) && \
    [[ "$SKIP_WIFI" == "false" ]] && systemctl restart hostapd 2>/dev/null) &

# =============================================================
# FINAL OUTPUT
# =============================================================
echo ""
echo -e "${GREEN}${BOLD}╔═══════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}${BOLD}║            SETUP COMPLETE — NEXT STEPS               ║${NC}"
echo -e "${GREEN}${BOLD}╚═══════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${BOLD}Reconnect (after network changes apply in ~5 sec):${NC}"
echo -e "  • Plug laptop into LAN port (${LAN_NIC})"
[[ "$SKIP_WIFI" == "false" ]] && \
echo -e "  • Or connect to WiFi: ${CYAN}${WIFI_SSID}${NC}"
echo ""
echo -e "  ${BOLD}Web Interfaces:${NC}"
echo -e "  • Proxmox  → ${CYAN}https://${LAN_HOST_IP}:8006${NC}"
echo -e "  • OPNsense → ${CYAN}https://${LAN_GW}${NC}  (login: admin / opnsense)"
echo ""
echo -e "  ${BOLD}OPNsense First Boot (Proxmox Console → VM ${VM_ID}):${NC}"
echo -e "  1. Console menu → option 1 → Assign Interfaces"
echo -e "     WAN = vtnet0   LAN = vtnet1"
echo -e "  2. Console menu → option 2 → Set LAN IP"
echo -e "     IP: ${LAN_GW}  Subnet: 24  Enable DHCP: yes"
echo -e "     DHCP range: 192.168.1.100 – 192.168.1.200"
echo -e "  3. Open browser → ${CYAN}https://${LAN_GW}${NC}"
echo -e "     Complete setup wizard"
echo ""
echo -e "  ${BOLD}Netbird:${NC}"
echo -e "  • Run ${CYAN}netbird status${NC} to get your authorization URL"
echo -e "  • Authorize at: ${CYAN}${NETBIRD_MGMT}${NC}"
echo ""
echo -e "${GREEN}${BOLD}  Done! SSH will drop momentarily — reconnect on ${LAN_HOST_IP}${NC}"
echo ""
