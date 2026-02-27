#!/usr/bin/env bash
# =============================================================================
# launcher.sh
# Interactive menu launcher for Proxmox shared scripts
# Supports: PVE | PBS | PDM
#
# Usage  : bash -c "$(curl -fsSL https://raw.githubusercontent.com/AriGonz/Public/refs/heads/main/Proxmox/shared/launcher.sh)"
#
# What this script does:
#   1.  Checks GitHub for a newer version of itself and self-updates if found
#   2.  Presents a numbered menu of all available Proxmox shared scripts
#   3.  Shows a one-line description for each script (parsed from its header)
#   4.  Downloads and runs the chosen script via curl | bash
#   5.  Returns to the menu after each run so you can run another script
#   6.  Exit option always available
#
# To add a new script to the menu: add an entry to the SCRIPTS array below.
# =============================================================================

set -euo pipefail

SCRIPT_VERSION="0.01"
SCRIPT_NAME="launcher.sh"
RAW_BASE="https://raw.githubusercontent.com/AriGonz/Public/refs/heads/main/Proxmox/shared"
SELF_URL="${RAW_BASE}/${SCRIPT_NAME}"

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
# Script Registry
# Hardcoded list of available scripts.
# Format: "filename.sh|One-line description shown in the menu"
# The launcher itself is intentionally excluded.
# =============================================================================

SCRIPTS=(
    "proxmox-update.sh|Configure no-subscription repos and run a full system upgrade"
    "netbird-install.sh|Install and connect NetBird VPN on this Proxmox node"
    "cloudflared-install.sh|Install Cloudflare Tunnel (cloudflared) on this Proxmox node"
    "proxmox-remove-nag.sh|Remove the 'No valid subscription' popup from the web UI"
)

# =============================================================================
# Preflight
# =============================================================================

preflight() {
    [[ $EUID -ne 0 ]] && die "This script must be run as root."
    command -v curl &>/dev/null || die "curl is required but not installed."
}

# =============================================================================
# Self-Update
# Downloads the latest version of this launcher from GitHub.
# Compares SCRIPT_VERSION strings; re-executes if a newer version is found.
# =============================================================================

self_update() {
    step "Checking for launcher updates..."

    local tmp_file
    tmp_file=$(mktemp /tmp/launcher-update-XXXXXX.sh)

    # Download latest launcher into a temp file
    if ! curl -fsSL "${SELF_URL}" -o "${tmp_file}" 2>/dev/null; then
        warn "Could not reach GitHub — skipping self-update check."
        rm -f "${tmp_file}"
        return 0
    fi

    # Extract remote version
    local remote_ver
    remote_ver=$(grep -oP '(?<=^SCRIPT_VERSION=")[^"]+' "${tmp_file}" 2>/dev/null || echo "0.00")

    if [[ "${remote_ver}" == "${SCRIPT_VERSION}" ]]; then
        success "Launcher is up to date (v${SCRIPT_VERSION})."
        rm -f "${tmp_file}"
        return 0
    fi

    # Simple version comparison using sort -V
    local newer
    newer=$(printf '%s\n%s\n' "${SCRIPT_VERSION}" "${remote_ver}" | sort -V | tail -1)

    if [[ "${newer}" == "${remote_ver}" && "${remote_ver}" != "${SCRIPT_VERSION}" ]]; then
        warn "New launcher version available: v${remote_ver} (current: v${SCRIPT_VERSION})"
        info "Re-launching with the updated version..."
        chmod +x "${tmp_file}"
        exec bash "${tmp_file}"
        # exec replaces this process — nothing below runs if update succeeded
    else
        info "Local version (v${SCRIPT_VERSION}) is ahead of remote (v${remote_ver}) — skipping update."
        rm -f "${tmp_file}"
    fi
}

# =============================================================================
# Fetch Script Description
# Pulls the first line from the script's header comment that looks like a
# description (the line immediately after the filename comment line).
# Falls back to the hardcoded description if the fetch fails.
# =============================================================================

fetch_description() {
    local script_file="$1"
    local fallback="$2"
    local url="${RAW_BASE}/${script_file}"

    local desc
    # Download just the first 20 lines to avoid a full file fetch
    desc=$(curl -fsSL "${url}" 2>/dev/null \
        | head -20 \
        | grep -oP '(?<=^# )(?!={3,}|Usage|What|Supports|Idempotent).*' \
        | grep -v "^\s*$" \
        | head -1 \
        || true)

    if [[ -n "${desc}" ]]; then
        echo "${desc}"
    else
        echo "${fallback}"
    fi
}

# =============================================================================
# Menu
# =============================================================================

print_header() {
    clear
    echo ""
    echo -e "${BOLD}${BLUE}$(printf '═%.0s' $(seq 1 62))${NC}"
    printf "${BOLD}${BLUE}  %-58s${NC}\n" "Proxmox Script Launcher  v${SCRIPT_VERSION}"
    printf "${BOLD}${BLUE}  %-58s${NC}\n" "AriGonz / Public / Proxmox / shared"
    echo -e "${BOLD}${BLUE}$(printf '═%.0s' $(seq 1 62))${NC}"
    echo ""
}

print_menu() {
    local i=1
    echo -e "  ${BOLD}Available scripts:${NC}"
    echo ""

    for entry in "${SCRIPTS[@]}"; do
        local filename desc
        filename="${entry%%|*}"
        desc="${entry##*|}"

        printf "  ${BOLD}${CYAN}[%d]${NC}  ${BOLD}%-34s${NC}\n" "${i}" "${filename}"
        printf "        ${BLUE}%s${NC}\n" "${desc}"
        echo ""
        (( i++ ))
    done

    echo -e "  ${BOLD}${RED}[0]${NC}  Exit"
    echo ""
    echo -e "${BOLD}${BLUE}$(printf '─%.0s' $(seq 1 62))${NC}"
    echo ""
}

run_script() {
    local filename="$1"
    local url="${RAW_BASE}/${filename}"

    echo ""
    echo -e "${BOLD}${BLUE}$(printf '─%.0s' $(seq 1 62))${NC}"
    printf "  ${CYAN}${BOLD}Running: %s${NC}\n" "${filename}"
    echo -e "${BOLD}${BLUE}$(printf '─%.0s' $(seq 1 62))${NC}"
    echo ""

    if ! curl -fsSL "${url}" | bash; then
        warn "Script exited with a non-zero status."
    fi

    echo ""
    echo -e "${BOLD}${BLUE}$(printf '─%.0s' $(seq 1 62))${NC}"
    echo -e "  ${GREEN}${BOLD}${filename} finished.${NC} Press Enter to return to the menu..."
    echo -e "${BOLD}${BLUE}$(printf '─%.0s' $(seq 1 62))${NC}"
    read -r
}

menu_loop() {
    local total="${#SCRIPTS[@]}"

    while true; do
        print_header
        print_menu

        local choice
        read -rp "  Select a script to run [0-${total}]: " choice

        # Validate input
        if [[ ! "${choice}" =~ ^[0-9]+$ ]]; then
            echo -e "\n  ${YELLOW}Invalid input. Please enter a number between 0 and ${total}.${NC}"
            sleep 1
            continue
        fi

        if [[ "${choice}" -eq 0 ]]; then
            echo ""
            success "Goodbye!"
            echo ""
            exit 0
        fi

        if [[ "${choice}" -lt 1 || "${choice}" -gt "${total}" ]]; then
            echo -e "\n  ${YELLOW}Please choose a number between 0 and ${total}.${NC}"
            sleep 1
            continue
        fi

        # Arrays are 0-indexed; menu is 1-indexed
        local entry="${SCRIPTS[$(( choice - 1 ))]}"
        local filename="${entry%%|*}"

        run_script "${filename}"
    done
}

# =============================================================================
# Main
# =============================================================================

main() {
    preflight
    self_update
    menu_loop
}

main "$@"
