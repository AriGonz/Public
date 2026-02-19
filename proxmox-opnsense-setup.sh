#!/bin/bash
# =============================================================
# Proxmox VE — Portable OPNsense Firewall Setup Script
# Repo   : github.com/AriGonz/Public
# Usage  : bash -c "$(curl -fsSL https://raw.githubusercontent.com/AriGonz/Public/main/proxmox-opnsense-setup.sh)"
# Version: 1.9
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

SCRIPT_VERSION="1.9"

info()    { echo -e "${GREEN}[+]${NC} $1"; }
warn()    { echo -e "${YELLOW}[!]${NC} $1"; }
error()   { echo -e "${RED}[✗]${NC} $1"; exit 1; }
step()    { echo -e "\n${BLUE}${BOLD}━━━ $1 ━━━${NC}"; }
success() { echo -e "${GREEN}[✓]${NC} $1"; }

echo -e "${BLUE}${BOLD}"
echo -e "  ╔══════════════════════════════════════════════════╗"
echo -e "  ║   Proxmox OPNsense Setup  •  Version ${SCRIPT_VERSION}        ║"
echo -e "  ║   github.com/AriGonz/Public                     ║"
echo -e "  ╚══════════════════════════════════════════════════╝"
echo -e "${NC}"

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
# PHASE 0 — REPOSITORY SETUP (runs immediately, no prompts)
# =============================================================
step "PHASE 0: Repository Setup"

# Disable ALL enterprise repos — handles both .list and .sources (deb822) formats
info "Disabling enterprise repos"
while IFS= read -r repo_file; do
    if [[ "$repo_file" == *.sources ]]; then
        # deb822 format — set Enabled: no
        if grep -q "^Enabled:" "$repo_file"; then
            sed -i 's/^Enabled:.*/Enabled: no/' "$repo_file"
        else
            echo "Enabled: no" >> "$repo_file"
        fi
    else
        # classic .list format — comment out deb lines
        sed -i 's/^deb/#deb/' "$repo_file"
    fi
    info "Disabled: $(basename "$repo_file")"
done < <(grep -rl "enterprise.proxmox.com" /etc/apt/sources.list.d/ 2>/dev/null)

# Also catch any enterprise entries in main sources.list
if grep -q "enterprise.proxmox.com" /etc/apt/sources.list 2>/dev/null; then
    sed -i '/enterprise\.proxmox\.com/s/^deb/#deb/' /etc/apt/sources.list
    info "Disabled enterprise entries in /etc/apt/sources.list"
fi

# Enable no-subscription repo
PVE_CODENAME=$(grep VERSION_CODENAME /etc/os-release | cut -d= -f2)
NO_SUB_REPO="deb http://download.proxmox.com/debian/pve ${PVE_CODENAME} pve-no-subscription"
if ! grep -qF "pve-no-subscription" /etc/apt/sources.list 2>/dev/null; then
    echo "$NO_SUB_REPO" >> /etc/apt/sources.list
    info "No-subscription repo added"
else
    warn "No-subscription repo already present"
fi

# Refresh package lists with correct repos
info "Updating package lists..."
apt-get update 2>&1 | grep -E "^(Err|W:|E:)" | while read -r line; do
    warn "$line"
done || true
info "Repositories configured and updated"

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

while true; do
    read -rsp "$(echo -e "${CYAN}OPNsense admin password${NC} (min 8 chars): ")" OPNSENSE_PASS
    echo
    [[ ${#OPNSENSE_PASS} -ge 8 ]] && break
    warn "Password must be at least 8 characters, try again"
done

echo ""
echo -e "${BOLD}Configuration Summary:${NC}"
echo -e "  Hostname        : ${CYAN}${HOSTNAME}${NC}"
echo -e "  OPNsense VM     : ${CYAN}${VM_ID}${NC}"
echo -e "  WiFi SSID       : ${CYAN}${WIFI_SSID}${NC}"
echo -e "  OPNsense pass   : ${CYAN}$(echo "${OPNSENSE_PASS}" | sed 's/./*/g')${NC}"
echo -e "  LAN IP          : ${CYAN}${LAN_HOST_IP}/${LAN_SUBNET}${NC}"
echo -e "  OPNsense IP     : ${CYAN}${LAN_GW}${NC}"
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
# START ISO DOWNLOAD IN BACKGROUND (while other phases run)
# =============================================================
ISO_DOWNLOAD_PID=""
if [[ -f "$ISO_PATH" ]]; then
    info "OPNsense ISO already exists — skipping download"
else
    info "Starting OPNsense ${OPNSENSE_VER} ISO download in background..."
    (
        wget -q -O "/var/lib/vz/template/iso/${ISO_BZ2}" "$ISO_URL" && \
        bunzip2 -k "/var/lib/vz/template/iso/${ISO_BZ2}" && \
        rm -f "/var/lib/vz/template/iso/${ISO_BZ2}"
    ) &
    ISO_DOWNLOAD_PID=$!
    info "ISO downloading in background (PID: ${ISO_DOWNLOAD_PID}) — setup will continue"
fi

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

# Update packages in background so Netbird setup can run in parallel
info "Starting apt full-upgrade in background..."
(
    apt-get update -qq
    DEBIAN_FRONTEND=noninteractive apt-get full-upgrade -y -q
    apt-get autoremove -y -qq
) >> /var/log/proxmox-setup-apt.log 2>&1 &
APT_UPGRADE_PID=$!
info "apt full-upgrade running in background (PID: ${APT_UPGRADE_PID}) → /var/log/proxmox-setup-apt.log"

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
# PHASE 4 — NETBIRD
# =============================================================
step "PHASE 4: Netbird"

info "Installing Netbird..."
curl -fsSL https://pkgs.netbird.io/install.sh | bash

info "Connecting to Netbird management server..."
# Capture netbird up output to a temp file — it prints the auth URL there
NETBIRD_LOG=$(mktemp /tmp/netbird-XXXXX.log)
netbird up --management-url "$NETBIRD_MGMT" > "$NETBIRD_LOG" 2>&1 &

# Wait 10s for netbird up to print the auth URL
info "Waiting 10s for Netbird to initialize..."
sleep 10

# Get auth URL from netbird up output (primary) or netbird status (fallback)
NETBIRD_AUTH_URL=$(grep -oE 'https://[^ ]+' "$NETBIRD_LOG" 2>/dev/null \
    | grep -v 'pkgs\|install\|docs' | head -1 || true)
if [[ -z "$NETBIRD_AUTH_URL" ]]; then
    NETBIRD_AUTH_URL=$(netbird status 2>/dev/null | grep -oE 'https://[^ ]+' | head -1 || true)
fi

echo ""
echo -e "${YELLOW}${BOLD}━━━ Netbird Authorization Required ━━━${NC}"
if [[ -n "$NETBIRD_AUTH_URL" ]]; then
    echo -e "  Open this URL to authorize this device:"
    echo -e "  ${CYAN}${NETBIRD_AUTH_URL}${NC}"
else
    echo -e "  Run ${CYAN}netbird status${NC} to get your authorization URL"
    echo -e "  Management URL: ${CYAN}${NETBIRD_MGMT}${NC}"
fi
echo ""

# Poll until Netbird is connected
info "Waiting for Netbird authorization..."
while true; do
    NETBIRD_FULL=$(netbird status 2>/dev/null || true)
    if echo "$NETBIRD_FULL" | grep -qi "connected"; then
        # Primary: parse 100.x.x.x from status output
        NETBIRD_IP=$(echo "$NETBIRD_FULL" | grep -oE '100\.[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
        # Fallback: read directly from the wt0 interface
        if [[ -z "$NETBIRD_IP" ]]; then
            NETBIRD_IP=$(ip addr show wt0 2>/dev/null | grep -oE '100\.[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
        fi
        echo ""
        success "Netbird connected! Your Netbird IP: ${CYAN}${NETBIRD_IP}${NC}"
        break
    fi
    NETBIRD_STATE=$(echo "$NETBIRD_FULL" | grep -i "status\|state" | head -1 | awk '{print $NF}' || echo "waiting")
    echo -ne "\r  [~] Netbird status: ${YELLOW}${NETBIRD_STATE:-waiting}${NC} — authorize at the URL above...     "
    sleep 5
done
echo ""

# Wait for background apt upgrade before continuing
if [[ -n "${APT_UPGRADE_PID:-}" ]]; then
    if kill -0 "$APT_UPGRADE_PID" 2>/dev/null; then
        info "Waiting for apt full-upgrade to finish..."
        wait "$APT_UPGRADE_PID" && info "System updated" || warn "apt full-upgrade had errors — check /var/log/proxmox-setup-apt.log"
    else
        info "apt full-upgrade already completed"
    fi
fi

# =============================================================
# PHASE 5 — NETWORK CONFIGURATION
# =============================================================
step "PHASE 5: Network Configuration"

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

# Bring up WAN bridge immediately so VM creation can use it
info "Bringing up ${WAN_BRIDGE}..."
timeout 15 ifup "${WAN_BRIDGE}" 2>/dev/null || {
    ip link add name "${WAN_BRIDGE}" type bridge 2>/dev/null || true
    ip link set "${WAN_NIC}" master "${WAN_BRIDGE}" 2>/dev/null || true
    ip link set "${WAN_BRIDGE}" up 2>/dev/null || true
}
info "${WAN_BRIDGE} is up"

# =============================================================
# PHASE 6 — WIFI ACCESS POINT
# =============================================================
if [[ "$SKIP_WIFI" == "false" ]]; then
    step "PHASE 6: WiFi Access Point"

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
    step "PHASE 6: WiFi Access Point — SKIPPED (no compatible WiFi NIC)"
fi

# =============================================================
# PHASE 7 — OPNSENSE VM
# =============================================================
step "PHASE 7: OPNsense VM"

# Wait for ISO download to complete if still running
if [[ -n "$ISO_DOWNLOAD_PID" ]]; then
    if kill -0 "$ISO_DOWNLOAD_PID" 2>/dev/null; then
        info "Waiting for OPNsense ISO download to complete..."
        while kill -0 "$ISO_DOWNLOAD_PID" 2>/dev/null; do
            DOWNLOADED=$(du -sh "/var/lib/vz/template/iso/${ISO_BZ2}" 2>/dev/null | cut -f1 || echo "0")
            printf "\r  [~] Downloaded so far: %s    " "$DOWNLOADED"
            sleep 3
        done
        echo ""
        wait "$ISO_DOWNLOAD_PID" && info "ISO download complete" || error "ISO download failed — re-run the script"
    else
        info "ISO download already completed"
    fi
fi

# Verify ISO exists
[[ -f "$ISO_PATH" ]] || error "ISO not found at ${ISO_PATH} — download may have failed"
info "ISO ready: ${ISO_PATH}"

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
# PHASE 9 — OPNSENSE CONFIGURATION & PORT FORWARDING
# =============================================================
step "PHASE 9: OPNsense Configuration & Port Forwarding"

# Install sshpass for non-interactive SSH into OPNsense
DEBIAN_FRONTEND=noninteractive apt-get install -y -q sshpass

# Wait for OPNsense SSH to become available
info "Waiting for OPNsense to boot and become reachable..."
OPNSENSE_SSH_READY=false
for i in $(seq 1 60); do
    if sshpass -p 'opnsense' ssh -o StrictHostKeyChecking=no -o ConnectTimeout=3 \
        root@"${LAN_GW}" 'echo ok' &>/dev/null; then
        OPNSENSE_SSH_READY=true
        break
    fi
    printf "\r  [~] Waiting for OPNsense SSH... (%ds)" "$((i*5))"
    sleep 5
done
echo ""

if [[ "$OPNSENSE_SSH_READY" != "true" ]]; then
    warn "OPNsense SSH not reachable after 5 minutes — skipping auto-configuration"
    warn "Complete OPNsense setup manually via Proxmox console → VM ${VM_ID}"
else
    success "OPNsense is reachable"

    # Run full OPNsense configuration via PHP over SSH
    info "Configuring OPNsense interfaces, DHCP, password and port forwarding..."
    sshpass -p 'opnsense' ssh -o StrictHostKeyChecking=no root@"${LAN_GW}" bash << OPNSENSE_EOF
php -r "
require_once('/usr/local/etc/inc/config.inc');
require_once('/usr/local/etc/inc/util.inc');
require_once('/usr/local/etc/inc/interfaces.inc');
require_once('/usr/local/etc/inc/filter.inc');

\\\$config = parse_config();

// ── Interfaces ────────────────────────────────────────────
\\\$config['interfaces']['wan'] = [
    'if'     => 'vtnet0',
    'descr'  => 'WAN',
    'ipaddr' => 'dhcp',
    'enable' => true,
];
\\\$config['interfaces']['lan'] = [
    'if'          => 'vtnet1',
    'descr'       => 'LAN',
    'ipaddr'      => '192.168.1.1',
    'subnet'      => '24',
    'enable'      => true,
];

// ── DHCP Server ───────────────────────────────────────────
\\\$config['dhcpd']['lan'] = [
    'enable' => true,
    'range'  => ['from' => '192.168.1.100', 'to' => '192.168.1.200'],
];

// ── Admin Password ────────────────────────────────────────
foreach (\\\$config['system']['user'] as &\\\$user) {
    if (\\\$user['name'] === 'root' || \\\$user['name'] === 'admin') {
        \\\$user['password'] = crypt('${OPNSENSE_PASS}', '\\\$6\\\$' . bin2hex(random_bytes(16)) . '\\\$');
    }
}
unset(\\\$user);

// ── Generate API Key ──────────────────────────────────────
\\\$apiKey    = bin2hex(random_bytes(32));
\\\$apiSecret = bin2hex(random_bytes(32));
\\\$apiHash   = crypt(\\\$apiSecret, '\\\$6\\\$' . bin2hex(random_bytes(16)) . '\\\$');
foreach (\\\$config['system']['user'] as &\\\$user) {
    if (\\\$user['name'] === 'root' || \\\$user['name'] === 'admin') {
        \\\$user['apikeys']['item'] = [
            'key'    => \\\$apiKey,
            'secret' => \\\$apiHash,
        ];
    }
}
unset(\\\$user);
file_put_contents('/tmp/opnsense_api.txt', \\\$apiKey . ':' . \\\$apiSecret . PHP_EOL);

// ── Port Forwarding (NAT) ─────────────────────────────────
\\\$nat_rules = [
    ['descr' => 'Proxmox Web UI',  'dstport' => '8006', 'target' => '192.168.1.254', 'targetport' => '8006'],
    ['descr' => 'Proxmox SSH',     'dstport' => '22',   'target' => '192.168.1.254', 'targetport' => '22'],
    ['descr' => 'OPNsense HTTPS',  'dstport' => '443',  'target' => '192.168.1.1',   'targetport' => '443'],
    ['descr' => 'OPNsense HTTP',   'dstport' => '80',   'target' => '192.168.1.1',   'targetport' => '80'],
];
if (!isset(\\\$config['nat']['rule'])) \\\$config['nat']['rule'] = [];
foreach (\\\$nat_rules as \\\$rule) {
    \\\$config['nat']['rule'][] = [
        'interface'      => 'wan',
        'protocol'       => 'tcp',
        'source'         => ['any' => true],
        'destination'    => ['any' => true, 'port' => \\\$rule['dstport']],
        'target'         => \\\$rule['target'],
        'local-port'     => \\\$rule['targetport'],
        'descr'          => \\\$rule['descr'],
        'associated-rule-id' => 'nat_' . \\\$rule['dstport'],
    ];
}

// ── Save & Apply ──────────────────────────────────────────
write_config('Automated setup by proxmox-opnsense-setup.sh');
echo 'CONFIG_OK' . PHP_EOL;
"
OPNSENSE_EOF

    # Check config was saved
    if sshpass -p 'opnsense' ssh -o StrictHostKeyChecking=no root@"${LAN_GW}" \
        'cat /tmp/opnsense_api.txt 2>/dev/null' | grep -q ':'; then
        success "OPNsense configuration applied"

        # Get API credentials
        API_CREDS=$(sshpass -p 'opnsense' ssh -o StrictHostKeyChecking=no \
            root@"${LAN_GW}" 'cat /tmp/opnsense_api.txt && rm /tmp/opnsense_api.txt')
        API_KEY=$(echo "$API_CREDS" | cut -d: -f1)
        API_SECRET=$(echo "$API_CREDS" | cut -d: -f2)

        # Reload OPNsense services via API
        info "Reloading OPNsense services..."
        curl -sk -u "${API_KEY}:${API_SECRET}" \
            -X POST "https://${LAN_GW}/api/core/firmware/reboot" &>/dev/null || true
        sleep 30

        # Get WAN IP after reboot
        info "Getting OPNsense WAN IP..."
        WAN_IP=""
        for i in $(seq 1 12); do
            WAN_IP=$(sshpass -p "${OPNSENSE_PASS}" ssh -o StrictHostKeyChecking=no \
                -o ConnectTimeout=5 root@"${LAN_GW}" \
                "ifconfig vtnet0 2>/dev/null | awk '/inet /{print \$2}'" 2>/dev/null || true)
            [[ -n "$WAN_IP" ]] && break
            printf "\r  [~] Waiting for WAN IP... (%ds)" "$((i*5))"
            sleep 5
        done
        echo ""

        if [[ -n "$WAN_IP" ]]; then
            success "OPNsense WAN IP: ${CYAN}${WAN_IP}${NC}"
        else
            warn "Could not detect WAN IP — check OPNsense console"
            WAN_IP="<WAN_IP>"
        fi
    else
        warn "OPNsense config may not have applied — check manually"
        WAN_IP="<WAN_IP>"
    fi
fi

# =============================================================
# PHASE 10 — INSTALL GET-WAN-IP SCRIPT
# =============================================================
step "PHASE 10: Installing get-wan-ip.sh"

info "Downloading get-wan-ip.sh..."
curl -fsSL https://raw.githubusercontent.com/AriGonz/Public/refs/heads/main/get-wan-ip.sh \
    -o /root/get-wan-ip.sh && chmod +x /root/get-wan-ip.sh

# Update OPNsense password in the script to match what was set
sed -i "s|OPNSENSE_PASS=.*|OPNSENSE_PASS=\"${OPNSENSE_PASS}\"|" /root/get-wan-ip.sh
info "OPNsense password updated in get-wan-ip.sh"

# Run it to show current IPs and install the systemd boot service
info "Running get-wan-ip.sh (installs boot service on first run)..."
bash /root/get-wan-ip.sh

# =============================================================
# FINAL OUTPUT
# =============================================================
echo ""
echo -e "${GREEN}${BOLD}╔═══════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}${BOLD}║              SETUP COMPLETE                          ║${NC}"
echo -e "${GREEN}${BOLD}╚═══════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "  ${BOLD}LAN Access (plug into ${LAN_NIC} or WiFi ${WIFI_SSID:-N/A}):${NC}"
echo -e "  • Proxmox  → ${CYAN}https://${LAN_HOST_IP}:8006${NC}"
echo -e "  • OPNsense → ${CYAN}https://${LAN_GW}${NC}"
echo ""
echo -e "  ${BOLD}WAN Access (from any upstream network):${NC}"
echo -e "  • Proxmox  → ${CYAN}https://${WAN_IP:-<WAN_IP>}:8006${NC}"
echo -e "  • OPNsense → ${CYAN}https://${WAN_IP:-<WAN_IP>}${NC}"
echo ""
echo -e "  ${BOLD}Remote Access (any network, any location):${NC}"
echo -e "  • Netbird  → ${CYAN}https://${NETBIRD_IP:-<Netbird_IP>}:8006${NC}"
echo ""
echo -e "  ${BOLD}Credentials:${NC}"
echo -e "  • Proxmox login  : root / (your password)"
echo -e "  • OPNsense login : admin / (password you set)"
echo ""
echo -e "${GREEN}${BOLD}  Done! SSH will drop momentarily — reconnect on ${LAN_HOST_IP}${NC}"
echo ""
