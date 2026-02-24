#!/usr/bin/env bash
# =============================================================================
# setup-pdm-vm.sh
# Proxmox Datacenter Manager (PDM) VM Setup Script
# Runs ON the PVE host (9.1.6+) as root
#
# RECOMMENDED usage (save then run — do NOT pipe via bash -c):
#   wget -O setup-pdm-vm.sh https://raw.githubusercontent.com/.../pdm-vm.sh
#   chmod +x setup-pdm-vm.sh
#   ./setup-pdm-vm.sh
#
# What this script does:
#   1. Checks for the PDM ISO locally, downloads it if missing
#   2. Creates a VM with recommended specs
#   3. Injects an unattended answer file into the ISO
#   4. Boots the VM and waits for PDM to come online
#   5. SSHes into PDM and installs + connects Netbird
#
# Requirements:
#   - Run as root on the PVE host
#   - proxmox-auto-install-assistant (auto-installed if missing, ships with PVE 9.x)
#   - Your self-hosted Netbird management URL and setup key
# =============================================================================

set -euo pipefail

# =============================================================================
# !! CONFIGURE THESE BEFORE RUNNING !!
# =============================================================================

SCRIPT_VERSION="0.3"

# --- VM Settings ---
VM_ID=200                          # Change if 200 is already taken
VM_NAME="pdm"
VM_CORES=2
VM_RAM=4096                        # MB
VM_DISK_SIZE=32                    # GB
VM_BRIDGE="vmbr0"                  # Your PVE bridge
VM_STORAGE="local"                 # ISO storage (local = /var/lib/vz)
VM_DISK_STORAGE="local-lvm"        # VM disk storage (change if needed e.g. local-zfs)

# --- PDM ISO ---
PDM_ISO_NAME="proxmox-datacenter-manager_1.0-2.iso"
PDM_ISO_URL="https://enterprise.proxmox.com/iso/${PDM_ISO_NAME}"
PDM_ISO_SHA256="b4b98ed3e8f4dabb1151ebb713d6e7109aeba00d95b88bf65f954dd9ef1e89e1"
ISO_DIR="/var/lib/vz/template/iso"

# --- PDM Unattended Install Settings ---
PDM_HOSTNAME="pdm"
PDM_DOMAIN="local"                 # e.g. homelab.local
PDM_PASSWORD="ChangeMe123!"        # Root password for the PDM system
PDM_EMAIL="admin@example.com"
PDM_TIMEZONE="America/Chicago"     # Change to your timezone
PDM_KEYBOARD="en-us"
PDM_DISK="sda"                     # Target disk inside VM (usually sda)
PDM_FILESYSTEM="ext4"              # ext4 or zfs

# --- Netbird Settings ---
NETBIRD_MANAGEMENT_URL="https://your-netbird-server.example.com:33073"
NETBIRD_SETUP_KEY=""   # Leave blank — script will prompt you securely at runtime

# --- SSH Settings (used after PDM boots to install Netbird) ---
# Since we're using DHCP we wait for the VM to appear and grab its IP.
# Alternatively set this manually if you know it.
PDM_SSH_USER="root"
SSH_WAIT_SECONDS=600               # How long to wait for PDM to boot (seconds)
SSH_RETRY_INTERVAL=10

# =============================================================================
# Colors & Helpers
# =============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

info()    { echo -e "${BLUE}[INFO]${NC}  $*"; }
success() { echo -e "${GREEN}[OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }

# =============================================================================
# Prompt for Netbird Setup Key
# =============================================================================

prompt_netbird_key() {
    if [[ -n "${NETBIRD_SETUP_KEY}" ]]; then
        info "Netbird setup key already set in script variables."
        return 0
    fi

    echo ""
    echo -e "${BLUE}=============================================${NC}"
    echo -e "${BLUE}  Netbird Setup Key Required                ${NC}"
    echo -e "${BLUE}=============================================${NC}"
    echo ""
    echo "  Find your setup key in your Netbird dashboard:"
    echo "  Setup Keys → Create Key (or copy an existing reusable one)"
    echo ""

    local key=""
    while [[ -z "${key}" ]]; do
        read -rsp "  Enter Netbird setup key (input hidden): " key
        echo ""
        if [[ -z "${key}" ]]; then
            warn "Setup key cannot be empty. Please try again."
        fi
    done

    # Validate UUID format (8-4-4-4-12 hex, upper or lowercase)
    if [[ ! "${key}" =~ ^[A-Fa-f0-9]{8}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{4}-[A-Fa-f0-9]{12}$ ]]; then
        warn "Key format looks unusual (expected format: 9461387A-7F5E-4E2F-9489-EC70F0C17480)."
        warn "Double-check it in your Netbird dashboard. Continuing anyway..."
    fi

    NETBIRD_SETUP_KEY="${key}"
    success "Netbird setup key accepted."
    echo ""
}

# =============================================================================
# Preflight Checks
# =============================================================================

preflight() {
    info "Running preflight checks..."

    [[ $EUID -ne 0 ]] && error "This script must be run as root on the PVE host."

    command -v qm       &>/dev/null || error "'qm' not found. Are you running this on a PVE host?"
    command -v wget     &>/dev/null || error "'wget' not found. Install with: apt install wget"
    # proxmox-auto-install-assistant is auto-installed if missing
    command -v sha256sum &>/dev/null || error "'sha256sum' not found."
    command -v ssh      &>/dev/null || error "'ssh' not found."

    # Check VM ID is free
    if qm status "${VM_ID}" &>/dev/null; then
        error "VM ID ${VM_ID} already exists. Change VM_ID in the script."
    fi

    success "Preflight checks passed."
}

# =============================================================================
# Stage 1: ISO Check & Download
# =============================================================================

stage_iso() {
    info "Stage 1: Checking for PDM ISO..."
    local iso_path="${ISO_DIR}/${PDM_ISO_NAME}"

    mkdir -p "${ISO_DIR}"

    if [[ -f "${iso_path}" ]]; then
        info "ISO found locally. Verifying checksum..."
        local actual_sum
        actual_sum=$(sha256sum "${iso_path}" | awk '{print $1}')
        if [[ "${actual_sum}" == "${PDM_ISO_SHA256}" ]]; then
            success "ISO checksum verified: ${iso_path}"
            return 0
        else
            warn "Checksum mismatch! Re-downloading ISO..."
            rm -f "${iso_path}"
        fi
    else
        info "ISO not found locally. Downloading..."
    fi

    wget -O "${iso_path}" "${PDM_ISO_URL}" \
        --progress=bar:force 2>&1 \
        || error "Failed to download PDM ISO from ${PDM_ISO_URL}"

    info "Verifying downloaded ISO checksum..."
    local actual_sum
    actual_sum=$(sha256sum "${iso_path}" | awk '{print $1}')
    if [[ "${actual_sum}" != "${PDM_ISO_SHA256}" ]]; then
        rm -f "${iso_path}"
        error "Downloaded ISO checksum mismatch. File removed. Please retry."
    fi

    success "ISO downloaded and verified: ${iso_path}"
}

# =============================================================================
# Stage 2: Build Unattended Answer File & Repack ISO
# =============================================================================

stage_answer_file() {
    info "Stage 2: Building unattended answer file and repacking ISO..."

    local original_iso="${ISO_DIR}/${PDM_ISO_NAME}"
    local answer_iso="${ISO_DIR}/pdm-unattended.iso"
    local work_dir
    work_dir=$(mktemp -d /tmp/pdm-iso-XXXXXX)

    # --- Check for proxmox-auto-install-assistant (ships with PVE 9.x) ---
    if ! command -v proxmox-auto-install-assistant &>/dev/null; then
        warn "proxmox-auto-install-assistant not found. Installing..."
        apt-get install -y -qq proxmox-auto-install-assistant \
            || error "Failed to install proxmox-auto-install-assistant."
    fi

    # --- Write the answer file ---
    cat > "${work_dir}/answer.toml" <<ANSWEREOF
[global]
keyboard = "${PDM_KEYBOARD}"
country = "us"
fqdn = "${PDM_HOSTNAME}.${PDM_DOMAIN}"
mailto = "${PDM_EMAIL}"
timezone = "${PDM_TIMEZONE}"
root_password = "${PDM_PASSWORD}"

[network]
source = "from-dhcp"

[disk-setup]
filesystem = "${PDM_FILESYSTEM}"
disk_list = ["${PDM_DISK}"]
ANSWEREOF

    info "Answer file written."

    # --- Use the official Proxmox tool to prepare the ISO ---
    # This correctly handles grub patching, kernel parameters, and ISO repacking
    info "Repacking ISO with proxmox-auto-install-assistant (this may take a moment)..."

    proxmox-auto-install-assistant prepare-iso "${original_iso}" \
        --fetch-from iso \
        --answer-file "${work_dir}/answer.toml" \
        --output "${answer_iso}" \
        && success "ISO repacked successfully with answer file." \
        || error "proxmox-auto-install-assistant failed to prepare the ISO."

    rm -rf "${work_dir}"
    success "Unattended ISO ready: ${answer_iso}"
}

# =============================================================================
# Stage 3: Create & Start the VM
# =============================================================================

stage_create_vm() {
    info "Stage 3: Creating PDM VM (ID: ${VM_ID})..."

    # Clean up any previous failed attempt with this VM ID
    if qm status "${VM_ID}" &>/dev/null; then
        warn "VM ${VM_ID} already exists — stopping and removing it before recreating..."
        qm stop "${VM_ID}" &>/dev/null || true
        sleep 3
        qm destroy "${VM_ID}" --destroy-unreferenced-disks 1 --purge 1
        success "Old VM ${VM_ID} removed."
    fi

    local answer_iso="${ISO_DIR}/pdm-unattended.iso"

    qm create "${VM_ID}" \
        --name "${VM_NAME}" \
        --memory "${VM_RAM}" \
        --cores "${VM_CORES}" \
        --cpu host \
        --machine q35 \
        --bios seabios \
        --net0 "virtio,bridge=${VM_BRIDGE}" \
        --ostype l26 \
        --scsihw virtio-scsi-pci \
        --scsi0 "${VM_DISK_STORAGE}:${VM_DISK_SIZE},format=raw" \
        --ide2 "${VM_STORAGE}:iso/pdm-unattended.iso,media=cdrom" \
        --boot "order=ide2;scsi0" \
        --agent enabled=1 \
        --onboot 1 \
        --tablet 0

    success "VM ${VM_ID} created."

    info "Starting VM ${VM_ID}..."
    qm start "${VM_ID}"
    success "VM started. PDM installer is running."
    info "Boot order: installer will run from ISO, then reboot to disk."
}

# =============================================================================
# Stage 4: Wait for PDM to Boot & Get IP
# =============================================================================

# NOTE: This function prints status to stderr so it stays visible when called
# inside $() command substitution. Only the final IP is echoed to stdout.
get_vm_ip() {
    echo "[INFO]  Stage 4: Waiting for PDM VM to boot and obtain a DHCP IP..." >&2
    echo "[INFO]  Polling every ${SSH_RETRY_INTERVAL}s — status updates will appear below." >&2
    echo "" >&2

    local elapsed=0
    local vm_ip=""
    local vm_status=""

    while [[ $elapsed -lt $SSH_WAIT_SECONDS ]]; do
        # Get current VM power status
        vm_status=$(qm status "${VM_ID}" 2>/dev/null | awk '{print $2}' || echo "unknown")

        # Try to get IP via qemu-guest-agent (only works once agent is running post-install)
        vm_ip=$(qm guest exec "${VM_ID}" -- hostname -I 2>/dev/null \
            | grep -oE '([0-9]{1,3}\.){3}[0-9]{1,3}' \
            | grep -v '^127\.' \
            | head -1 || true)

        if [[ -n "${vm_ip}" ]]; then
            echo "" >&2
            echo "[OK]    PDM VM IP detected: ${vm_ip}" >&2
            echo "${vm_ip}"   # <-- only this goes to stdout / $()
            return 0
        fi

        # Describe what is likely happening based on elapsed time
        local phase_msg=""
        if   [[ $elapsed -lt 60 ]];  then phase_msg="VM booting, loading installer..."
        elif [[ $elapsed -lt 180 ]]; then phase_msg="PDM installation in progress (partitioning/packages)..."
        elif [[ $elapsed -lt 300 ]]; then phase_msg="Finalising install, first reboot imminent..."
        elif [[ $elapsed -lt 420 ]]; then phase_msg="PDM first boot — services starting up..."
        else                               phase_msg="Still waiting — install may be slow or check console."
        fi

        printf "  [%3ds]  VM status: %-10s  %s\n" \
            "${elapsed}" "${vm_status}" "${phase_msg}" >&2

        sleep "${SSH_RETRY_INTERVAL}"
        elapsed=$((elapsed + SSH_RETRY_INTERVAL))
    done

    echo "" >&2
    echo "[WARN]  Could not automatically detect VM IP after ${SSH_WAIT_SECONDS}s." >&2
    echo "[WARN]  The install may still be running. Options:" >&2
    echo "[WARN]    1. Check PVE web UI > VM ${VM_ID} > Console to see installer progress" >&2
    echo "[WARN]    2. Check your DHCP server for a lease assigned to '${VM_NAME}'" >&2
    echo "[WARN]    3. Once booted, run:  ./setup-pdm-vm.sh netbird <PDM_IP>" >&2
    echo ""
}

# =============================================================================
# Stage 5: Install Netbird on PDM via SSH
# =============================================================================

install_netbird() {
    local pdm_ip="${1:-}"

    if [[ -z "${pdm_ip}" ]]; then
        error "No IP provided for Netbird installation. Run: $0 netbird <PDM_IP>"
    fi

    info "Stage 5: Installing Netbird on PDM at ${pdm_ip}..."

    # Wait for SSH to be available
    info "Waiting for SSH on ${pdm_ip}:22..."
    local retries=0
    while ! ssh -o ConnectTimeout=5 \
                -o StrictHostKeyChecking=no \
                -o BatchMode=yes \
                "${PDM_SSH_USER}@${pdm_ip}" "exit" &>/dev/null; do
        retries=$((retries + 1))
        [[ $retries -gt 30 ]] && error "SSH not available after 5 minutes. Check PDM is fully booted."
        sleep 10
    done

    success "SSH is available."

    # Push and run the Netbird install script remotely
    ssh -o StrictHostKeyChecking=no \
        "${PDM_SSH_USER}@${pdm_ip}" \
        bash -s -- \
        "${NETBIRD_MANAGEMENT_URL}" \
        "${NETBIRD_SETUP_KEY}" \
        << 'REMOTE_SCRIPT'
#!/usr/bin/env bash
set -euo pipefail

MANAGEMENT_URL="$1"
SETUP_KEY="$2"

echo "[INFO] Updating packages..."
apt-get update -qq

echo "[INFO] Installing dependencies..."
apt-get install -y -qq ca-certificates curl gnupg

echo "[INFO] Adding Netbird apt repository..."
curl -sSL https://pkgs.netbird.io/debian/public.key \
    | gpg --dearmor --output /usr/share/keyrings/netbird-archive-keyring.gpg

echo 'deb [signed-by=/usr/share/keyrings/netbird-archive-keyring.gpg] https://pkgs.netbird.io/debian stable main' \
    | tee /etc/apt/sources.list.d/netbird.list

apt-get update -qq
apt-get install -y -qq netbird

echo "[INFO] Connecting to self-hosted Netbird management server..."
netbird up \
    --management-url "${MANAGEMENT_URL}" \
    --setup-key "${SETUP_KEY}" \
    --daemon-addr unix:///var/run/netbird.sock

echo "[INFO] Enabling Netbird service on boot..."
systemctl enable netbird
systemctl start netbird

echo "[OK] Netbird installed and connected."
echo ""
echo "Netbird peer status:"
netbird status
REMOTE_SCRIPT

    success "Netbird installed and connected on PDM."
    echo ""
    info "======================================================================"
    info " PDM is ready at: https://${pdm_ip}:8443"
    info " Netbird is connected to: ${NETBIRD_MANAGEMENT_URL}"
    info ""
    info " Next steps:"
    info "   1. Log into PDM web UI with root / your configured password"
    info "   2. On each remote PVE/PBS node, install Netbird and join the same"
    info "      Netbird network using another setup key"
    info "   3. In PDM, add remotes using their Netbird IP (100.x.x.x)"
    info "   4. Create a dedicated API token on each remote PVE/PBS for PDM"
    info "      (Datacenter > API Tokens, then add to PDM as a remote)"
    info "======================================================================"
}

# =============================================================================
# Main
# =============================================================================

main() {
    echo ""
    echo -e "${BLUE}=============================================${NC}"
    echo -e "${BLUE}  PDM + Netbird Setup Script  v${SCRIPT_VERSION}        ${NC}"
    echo -e "${BLUE}  PVE Host Automation (requires PVE 9.1.6+) ${NC}"
    echo -e "${BLUE}=============================================${NC}"
    echo ""

    # Warn if being piped through bash -c (causes script body to echo to terminal)
    if [[ "$0" == "bash" || "$0" == "-bash" || "$0" == "/bin/bash" ]]; then
        echo -e "${YELLOW}[WARN]${NC}  Detected: running via 'bash -c \$(curl ...)'"
        echo -e "${YELLOW}[WARN]${NC}  This causes the script body to print to your terminal."
        echo -e "${YELLOW}[WARN]${NC}  Recommended usage instead:"
        echo ""
        echo "    wget -O setup-pdm-vm.sh <URL>"
        echo "    chmod +x setup-pdm-vm.sh"
        echo "    ./setup-pdm-vm.sh"
        echo ""
        echo -e "${YELLOW}[WARN]${NC}  Continuing anyway in 5 seconds..."
        sleep 5
        echo ""
    fi

    case "${1:-full}" in
        full)
            preflight
            prompt_netbird_key
            stage_iso
            stage_answer_file
            stage_create_vm
            local vm_ip
            vm_ip=$(get_vm_ip)
            if [[ -n "${vm_ip}" ]]; then
                install_netbird "${vm_ip}"
            fi
            ;;
        iso)
            preflight
            stage_iso
            ;;
        vm)
            preflight
            stage_create_vm
            ;;
        netbird)
            # Run Netbird install stage only, with a provided IP
            # Usage: ./setup-pdm-vm.sh netbird 192.168.1.50
            prompt_netbird_key
            install_netbird "${2:-}"
            ;;
        *)
            echo "Usage: $0 [full|iso|vm|netbird <IP>]"
            echo ""
            echo "  full           Run all stages (default)"
            echo "  iso            Only check/download the PDM ISO"
            echo "  vm             Only create and start the VM"
            echo "  netbird <IP>   Only install Netbird on a running PDM at <IP>"
            exit 0
            ;;
    esac
}

main "$@"
