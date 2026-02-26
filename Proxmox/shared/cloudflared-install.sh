#!/usr/bin/env bash
# =============================================================================
# cloudflared-install.sh
# Cloudflare Tunnel (cloudflared) installer for Proxmox nodes
# Supports: PVE | PBS | PDM
#
# Usage  : bash -c "$(curl -fsSL https://raw.githubusercontent.com/AriGonz/Public/refs/heads/main/Proxmox/shared/cloudflared-install.sh)"
#
# What this script does:
#   1.  Detects the installed Proxmox product (PVE / PBS / PDM)
#   2.  Checks if cloudflared is already installed
#   3.  Installs cloudflared via the official Cloudflare apt repo if missing
#   4.  Asks whether you want to run an interactive tunnel login
#       (browser-based, generates a cert in ~/.cloudflared/)
#   5a. If yes: runs  cloudflared tunnel login  and waits for browser auth
#   5b. If no:  prints the manual login URL and writes instructions to
#       /root/cloudflared-setup.txt so you can complete it from any browser
#   6.  Prints a final recap
#
# Idempotent — safe to re-run on an already-configured system.
# =============================================================================

set -euo pipefail

SCRIPT_VERSION="0.01"

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

PRODUCT=""                   # pve | pbs | pdm
CF_WAS_INSTALLED=false       # true if we installed cloudflared this run
CF_LOGGED_IN=false           # true if tunnel login completed successfully
SETUP_FILE="/root/cloudflared-setup.txt"

# =============================================================================
# Preflight
# =============================================================================

preflight() {
    [[ $EUID -ne 0 ]] && die "This script must be run as root."

    for cmd in curl apt-get dpkg grep sed awk; do
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
# cloudflared Installation
# =============================================================================

is_cloudflared_installed() {
    command -v cloudflared &>/dev/null
}

install_cloudflared() {
    step "Installing cloudflared via official Cloudflare apt repository..."

    local keyring_dir="/usr/share/keyrings"
    local keyring_file="${keyring_dir}/cloudflare-main.gpg"
    local sources_file="/etc/apt/sources.list.d/cloudflared.list"

    # 1. GPG keyring
    info "Adding Cloudflare GPG key..."
    mkdir -p --mode=0755 "${keyring_dir}"
    curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg \
        | tee "${keyring_file}" >/dev/null
    success "GPG key saved to ${keyring_file}"

    # 2. Apt repository
    info "Adding Cloudflare apt repository..."
    echo "deb [signed-by=${keyring_file}] https://pkg.cloudflare.com/cloudflared any main" \
        > "${sources_file}"
    success "Repo added: ${sources_file}"

    # 3. Update & install
    info "Running apt-get update..."
    apt-get update -qq

    info "Installing cloudflared package..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y cloudflared \
        || die "cloudflared installation failed."

    if ! command -v cloudflared &>/dev/null; then
        die "cloudflared binary not found after install. Something went wrong."
    fi

    CF_WAS_INSTALLED=true
    success "cloudflared installed: $(cloudflared --version 2>/dev/null | head -1 || echo 'version unknown')"
}

# =============================================================================
# Tunnel Login
# =============================================================================

prompt_login() {
    step "Cloudflare Tunnel Authentication"
    echo ""
    echo -e "  ${BOLD}Do you want to run the interactive tunnel login now?${NC}"
    echo -e "  ${CYAN}(This opens a browser auth flow and saves a cert to ~/.cloudflared/)${NC}"
    echo -e "  ${CYAN}You will need access to a browser on another device.)${NC}"
    echo ""
    echo -e "  ${BOLD}[y]${NC} Yes — start  cloudflared tunnel login  now"
    echo -e "  ${BOLD}[n]${NC} No  — save instructions to ${SETUP_FILE} for later"
    echo ""

    local answer
    while true; do
        read -rp "  Your choice [y/n]: " answer
        case "${answer,,}" in
            y|yes) return 0 ;;
            n|no)  return 1 ;;
            *) echo -e "  ${YELLOW}Please enter y or n.${NC}" ;;
        esac
    done
}

run_tunnel_login() {
    step "Running cloudflared tunnel login..."
    echo ""
    info "A URL will be printed below. Open it in a browser and authorise this host."
    info "The script will wait until you complete the flow."
    echo ""

    if cloudflared tunnel login; then
        CF_LOGGED_IN=true
        success "Tunnel login completed. Certificate saved to ~/.cloudflared/cert.pem"
    else
        warn "cloudflared tunnel login returned a non-zero exit code."
        warn "If auth timed out, run:  cloudflared tunnel login"
        write_setup_instructions "cloudflared tunnel login"
    fi
}

write_setup_instructions() {
    local login_cmd="${1:-cloudflared tunnel login}"

    cat > "${SETUP_FILE}" <<EOF
================================================================================
  Cloudflare Tunnel — Setup Instructions
  Generated: $(date)
  Host:      $(hostname -f 2>/dev/null || hostname)
  Product:   ${PRODUCT^^}
================================================================================

cloudflared is installed but not yet authenticated with Cloudflare.

To complete the setup:

  1. On this Proxmox node, run:

       ${login_cmd}

  2. A URL will be printed. Open it in a browser on any device.

  3. Log in with your Cloudflare account and select the zone (domain)
     to associate with this tunnel.

  4. Once authorised, a certificate will be saved to:

       ~/.cloudflared/cert.pem   (or /root/.cloudflared/cert.pem as root)

  5. Create a named tunnel:

       cloudflared tunnel create <tunnel-name>

  6. Create a config file at ~/.cloudflared/config.yml, for example:

       tunnel: <tunnel-id>
       credentials-file: /root/.cloudflared/<tunnel-id>.json

       ingress:
         - hostname: proxmox.example.com
           service: https://localhost:8006
           originRequest:
             noTLSVerify: true
         - service: http_status:404

  7. Route DNS (replaces a manual CNAME in Cloudflare dashboard):

       cloudflared tunnel route dns <tunnel-name> proxmox.example.com

  8. Run the tunnel:

       cloudflared tunnel run <tunnel-name>

     Or install it as a system service:

       cloudflared service install
       systemctl enable --now cloudflared

================================================================================
  Cloudflare Docs:  https://developers.cloudflare.com/cloudflare-one/connections/connect-networks/
================================================================================
EOF

    success "Instructions written to: ${SETUP_FILE}"
    info "Run  cat ${SETUP_FILE}  to review at any time."
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

    local cf_version
    cf_version=$(cloudflared --version 2>/dev/null | head -1 || echo "unknown")

    local install_label
    ${CF_WAS_INSTALLED} && install_label="installed during this run" \
                        || install_label="already present"

    local auth_label
    if ${CF_LOGGED_IN}; then
        auth_label="${GREEN}authenticated — cert saved to ~/.cloudflared/cert.pem${NC}"
    else
        auth_label="${YELLOW}not yet authenticated — see ${SETUP_FILE}${NC}"
    fi

    echo ""
    echo -e "${BOLD}${BLUE}$(printf '═%.0s' $(seq 1 ${width}))${NC}"
    printf "${BOLD}${BLUE}  %-*s${NC}\n" $(( width - 2 )) "RECAP"
    echo -e "${BOLD}${BLUE}$(printf '═%.0s' $(seq 1 ${width}))${NC}"
    printf "  ${BOLD}%-24s${NC} %s\n"  "Product:"              "${product_label}"
    printf "  ${BOLD}%-24s${NC} %s\n"  "cloudflared version:"  "${cf_version}"
    printf "  ${BOLD}%-24s${NC} %s\n"  "cloudflared install:"  "${install_label}"
    printf "  ${BOLD}%-24s${NC}"       "Auth status:"
    echo -e " ${auth_label}"

    if ! ${CF_LOGGED_IN}; then
        echo ""
        printf "  ${BOLD}%-24s${NC} %s\n" "Instructions file:" "${SETUP_FILE}"
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
    printf "${BOLD}${BLUE}  %-58s${NC}\n" "cloudflared-install.sh  v${SCRIPT_VERSION}"
    printf "${BOLD}${BLUE}  %-58s${NC}\n" "Cloudflare Tunnel Installer for Proxmox Nodes"
    echo -e "${BOLD}${BLUE}$(printf '═%.0s' $(seq 1 62))${NC}"
    echo ""

    preflight

    # ── Detection ───────────────────────────────────────────────────────────
    detect_product

    # ── Installation ─────────────────────────────────────────────────────────
    step "Checking cloudflared installation status..."
    if is_cloudflared_installed; then
        success "cloudflared is already installed: $(cloudflared --version 2>/dev/null | head -1 || echo 'version unknown')"
    else
        warn "cloudflared is not installed."
        install_cloudflared
    fi

    # ── Authentication ───────────────────────────────────────────────────────
    if prompt_login; then
        run_tunnel_login
        # If login didn't complete, write instructions as fallback
        if ! ${CF_LOGGED_IN}; then
            write_setup_instructions "cloudflared tunnel login"
        fi
    else
        write_setup_instructions "cloudflared tunnel login"
    fi

    # ── Recap ────────────────────────────────────────────────────────────────
    print_recap

    if ! ${CF_LOGGED_IN}; then
        warn "ACTION REQUIRED: complete Cloudflare tunnel authentication."
        warn "  Instructions saved to: ${SETUP_FILE}"
        warn "  Run 'cat ${SETUP_FILE}' to review."
    fi

    success "Done."
}

main "$@"
