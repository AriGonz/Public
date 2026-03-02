#!/usr/bin/env bash
# =============================================================================
# netbird-install.sh
# NetBird VPN client installer for Proxmox nodes
# Supports: PVE | PBS | PDM
#
# Usage  : bash -c "$(curl -fsSL https://raw.githubusercontent.com/AriGonz/Public/refs/heads/main/Proxmox/shared/netbird-install.sh)"
#
# What this script does:
#   1. Detects the installed Proxmox product (PVE / PBS / PDM)
#   2. Checks if NetBird is already installed
#   3. Installs NetBird if missing (via official install script)
#   4. Asks whether you have a NetBird setup key
#   5a. If yes: prompts for the key and runs netbird up with it
#   5b. If no:  starts a device-auth flow and saves the link + instructions
#       to /root/netbird-setup.txt for you to complete from a browser
#   6. Prints a final recap
#
# Idempotent — safe to re-run on an already-configured system.
# =============================================================================

set -euo pipefail

SCRIPT_VERSION="0.04"

# =============================================================================
# Colors & Output Helpers
# =============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

step()    { echo -e "\n${CYAN}${BOLD}▶ $*${NC}"; }
success() { echo -e "${GREEN}  [OK]${NC}    $*"; }
warn()    { echo -e "${YELLOW}  [WARN]${NC}  $*"; }
info()    { echo -e "${BLUE}  [INFO]${NC}  $*"; }
error()   { echo -e "${RED}  [ERROR]${NC} $*" >&2; }
die()     { error "$*"; exit 1; }

# =============================================================================
# Global State
# =============================================================================

PRODUCT=""              # pve | pbs | pdm
NETBIRD_WAS_INSTALLED=false
SETUP_KEY_USED=false
DEVICE_AUTH_FILE="/root/netbird-setup.txt"

# Self-hosted NetBird management server
NETBIRD_SERVER="netbird.arigonz.com"

# =============================================================================
# Preflight
# =============================================================================

preflight() {
    [[ $EUID -ne 0 ]] && die "This script must be run as root."

    for cmd in curl grep sed awk systemctl; do
        command -v "${cmd}" &>/dev/null \
            || die "Required command not found: ${cmd}"
    done
}

# =============================================================================
# Detection
# =============================================================================

detect_product() {
    step "Detecting installed Proxmox product..."

    # Priority 1: installed package presence
    if dpkg-query -W -f='${Status}' pve-manager 2>/dev/null | grep -q "install ok installed"; then
        PRODUCT="pve"
        success "Detected: pve-manager → Proxmox VE (PVE)"
        return 0
    fi

    if dpkg-query -W -f='${Status}' proxmox-datacenter-manager 2>/dev/null | grep -q "install ok installed"; then
        PRODUCT="pdm"
        success "Detected: proxmox-datacenter-manager → Proxmox Datacenter Manager (PDM)"
        return 0
    fi

    if dpkg-query -W -f='${Status}' proxmox-backup-server 2>/dev/null | grep -q "install ok installed"; then
        PRODUCT="pbs"
        success "Detected: proxmox-backup-server → Proxmox Backup Server (PBS)"
        return 0
    fi

    # Priority 2: running services
    if systemctl is-active --quiet pve-cluster 2>/dev/null; then
        PRODUCT="pve"
        warn "Package not found; detected via service pve-cluster → PVE"
        return 0
    fi

    if systemctl is-active --quiet proxmox-datacenter-manager 2>/dev/null; then
        PRODUCT="pdm"
        warn "Package not found; detected via service proxmox-datacenter-manager → PDM"
        return 0
    fi

    if systemctl is-active --quiet proxmox-backup 2>/dev/null; then
        PRODUCT="pbs"
        warn "Package not found; detected via service proxmox-backup → PBS"
        return 0
    fi

    # Priority 3: marker files
    if [[ -f /etc/pve/version ]]; then
        PRODUCT="pve"
        warn "Detected via /etc/pve/version → PVE"
        return 0
    fi

    if [[ -f /usr/share/proxmox-datacenter-manager/RELEASE ]]; then
        PRODUCT="pdm"
        warn "Detected via PDM marker file → PDM"
        return 0
    fi

    if [[ -f /usr/share/proxmox-backup/RELEASE ]]; then
        PRODUCT="pbs"
        warn "Detected via PBS marker file → PBS"
        return 0
    fi

    die "Cannot detect a supported Proxmox product (PVE / PBS / PDM). Aborting."
}

# =============================================================================
# NetBird Installation
# =============================================================================

is_netbird_installed() {
    command -v netbird &>/dev/null
}

install_netbird() {
    step "Installing NetBird..."

    info "Downloading and running the official NetBird install script..."
    curl -fsSL https://pkgs.netbird.io/install.sh | sh \
        || die "NetBird installation failed. Check network connectivity."

    # Confirm the binary is now available
    if ! command -v netbird &>/dev/null; then
        die "NetBird binary not found after install. Something went wrong."
    fi

    NETBIRD_WAS_INSTALLED=true
    success "NetBird installed successfully: $(netbird version 2>/dev/null || echo 'version unknown')"
}

ensure_netbird_service() {
    step "Ensuring NetBird service is enabled and running..."

    if systemctl enable --now netbird &>/dev/null; then
        success "NetBird service is enabled and running."
    else
        warn "Could not enable/start netbird service automatically."
        warn "Try: systemctl enable --now netbird"
    fi
}

# =============================================================================
# Setup Key / Device Auth Flow
# =============================================================================

prompt_setup_key() {
    step "NetBird Authentication"
    echo ""
    echo -e "  ${BOLD}Do you have a NetBird setup key?${NC}"
    echo -e "  ${CYAN}(A setup key lets the script connect this node automatically.)${NC}"
    echo ""
    echo -e "  ${BOLD}[y]${NC} Yes — I have a setup key"
    echo -e "  ${BOLD}[n]${NC} No  — generate a device-auth link instead"
    echo ""

    local answer
    while true; do
        # Read from /dev/tty explicitly so this works when stdin is a pipe
        # (e.g. when the script is fetched and run via: bash -c "$(curl ...)")
        read -rp "  Your choice [y/n]: " answer </dev/tty
        case "${answer,,}" in
            y|yes) return 0 ;;
            n|no)  return 1 ;;
            *) echo -e "  ${YELLOW}Please enter y or n.${NC}" ;;
        esac
    done
}

connect_with_setup_key() {
    step "Connecting NetBird with setup key..."
    echo ""

    local setup_key
    while true; do
        # Read from /dev/tty explicitly so this works when stdin is a pipe
        read -rp "  Enter your setup key: " setup_key </dev/tty
        setup_key="${setup_key// /}"   # strip accidental spaces
        if [[ -n "${setup_key}" ]]; then
            break
        fi
        echo -e "  ${YELLOW}Setup key cannot be empty. Try again.${NC}"
    done

    info "Running: netbird up --setup-key <redacted>"
    if netbird up --management-url "https://${NETBIRD_SERVER}" --setup-key "${setup_key}"; then
        SETUP_KEY_USED=true
        success "NetBird connected successfully using setup key."
    else
        warn "netbird up returned a non-zero exit code."
        warn "Check 'netbird status' for details."
    fi
}

connect_with_device_auth() {
    step "Generating NetBird device-auth link..."

    info "Running: netbird up (device auth flow — no setup key)"
    info "A URL and code will appear below. Open the URL in a browser to authenticate."
    info "The script will continue automatically once auth is complete."
    echo ""

    # Run netbird up directly (NOT in a subshell) so the URL prints live to
    # the terminal and the process can complete the auth handshake.
    # Capturing via $(...) would deadlock — the URL never shows, auth never
    # completes, and netbird up never exits.
    netbird up --management-url "https://${NETBIRD_SERVER}" || warn "netbird up returned a non-zero exit code — check 'netbird status'."

    write_device_auth_instructions "<completed via browser — run 'netbird status' to confirm>"
}

write_device_auth_instructions() {
    local auth_info="${1:-<see terminal output above>}"

    cat > "${DEVICE_AUTH_FILE}" <<EOF
================================================================================
  NetBird Device Auth Instructions
  Generated: $(date)
  Host:      $(hostname -f 2>/dev/null || hostname)
  Product:   ${PRODUCT^^}
================================================================================

To finish connecting this Proxmox node to NetBird, complete the OAuth2 flow:

  1. Open a browser on any device.

  2. Go to the URL + code shown below:

     ${auth_info}

  3. Log in with your NetBird / IdP account and approve the device.

  4. Once approved, this node will automatically appear in your NetBird dashboard.

  5. Verify the connection on this node with:

     netbird status

  6. (Optional) Check the NetBird service:

     systemctl status netbird

You can re-run this file's instructions at any time by running:

     netbird up

then following the link printed to the terminal.

================================================================================
EOF

    success "Instructions written to: ${DEVICE_AUTH_FILE}"
    info "Run  cat ${DEVICE_AUTH_FILE}  to review at any time."
}

# =============================================================================
# Recap
# =============================================================================

print_recap() {
    local width=62

    local product_label
    case "${PRODUCT}" in
        pve) product_label="Proxmox VE (PVE)" ;;
        pbs) product_label="Proxmox Backup Server (PBS)" ;;
        pdm) product_label="Proxmox Datacenter Manager (PDM)" ;;
        *)   product_label="${PRODUCT}" ;;
    esac

    local nb_version
    nb_version=$(netbird version 2>/dev/null || echo "unknown")

    local install_label
    ${NETBIRD_WAS_INSTALLED} && install_label="installed during this run" \
                             || install_label="already present"

    local auth_label
    if ${SETUP_KEY_USED}; then
        auth_label="${GREEN}connected via setup key${NC}"
    else
        auth_label="${YELLOW}device-auth pending — see ${DEVICE_AUTH_FILE}${NC}"
    fi

    echo ""
    echo -e "${BOLD}${BLUE}$(printf '═%.0s' $(seq 1 ${width}))${NC}"
    printf "${BOLD}${BLUE}  %-*s${NC}\n" $(( width - 2 )) "RECAP"
    echo -e "${BOLD}${BLUE}$(printf '═%.0s' $(seq 1 ${width}))${NC}"
    printf "  ${BOLD}%-24s${NC} %s\n"  "Product:"           "${product_label}"
    printf "  ${BOLD}%-24s${NC} %s\n"  "NetBird version:"   "${nb_version}"
    printf "  ${BOLD}%-24s${NC} %s\n"  "NetBird install:"   "${install_label}"
    printf "  ${BOLD}%-24s${NC}"       "Auth status:"
    echo -e " ${auth_label}"

    if ! ${SETUP_KEY_USED}; then
        echo ""
        printf "  ${BOLD}%-24s${NC} %s\n" "Instructions file:" "${DEVICE_AUTH_FILE}"
    fi

    echo -e "${BOLD}${BLUE}$(printf '═%.0s' $(seq 1 ${width}))${NC}"
    echo ""
}

# =============================================================================
# Main
# =============================================================================

main() {
    echo ""
    echo -e "${BOLD}${BLUE}$(printf '═%.0s' $(seq 1 62))${NC}"
    printf "${BOLD}${BLUE}  %-58s${NC}\n" "netbird-install.sh  v${SCRIPT_VERSION}"
    printf "${BOLD}${BLUE}  %-58s${NC}\n" "NetBird Installer for Proxmox Nodes"
    echo -e "${BOLD}${BLUE}$(printf '═%.0s' $(seq 1 62))${NC}"
    echo ""

    preflight

    # ── Detection ───────────────────────────────────────────────────────────
    detect_product

    # ── NetBird installation ─────────────────────────────────────────────────
    step "Checking NetBird installation status..."
    if is_netbird_installed; then
        success "NetBird is already installed: $(netbird version 2>/dev/null || echo 'version unknown')"
    else
        warn "NetBird is not installed."
        install_netbird
    fi

    ensure_netbird_service

    # ── Authentication ───────────────────────────────────────────────────────
    if prompt_setup_key; then
        connect_with_setup_key
    else
        connect_with_device_auth
    fi

    # ── Recap ────────────────────────────────────────────────────────────────
    print_recap

    if ! ${SETUP_KEY_USED}; then
        warn "ACTION REQUIRED: complete the browser auth flow."
        warn "  Instructions saved to: ${DEVICE_AUTH_FILE}"
        warn "  Run 'cat ${DEVICE_AUTH_FILE}' to review."
    fi

    success "Done."
}

main "$@"
