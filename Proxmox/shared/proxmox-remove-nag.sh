#!/usr/bin/env bash
# =============================================================================
# proxmox-remove-nag.sh
# Removes the "No valid subscription" popup from the Proxmox web UI
# Supports: PVE | PBS | PDM
#
# Usage  : bash -c "$(curl -fsSL https://raw.githubusercontent.com/AriGonz/Public/refs/heads/main/Proxmox/shared/proxmox-remove-nag.sh)"
#
# What this script does:
#   1.  Detects the installed Proxmox product (PVE / PBS / PDM)
#   2.  Backs up the target JavaScript file(s) before patching
#   3.  Patches the subscription check in proxmoxlib.js (all products)
#   4.  Patches proxmoxbackuplib.js as well (PBS only)
#   5.  Verifies the patch was applied successfully
#   6.  Restarts the appropriate proxy service to apply changes
#   7.  Prints a final recap
#
# NOTE: The patch is applied to files in /usr/share/javascript/.
#       These files are overwritten by apt upgrades of the widget toolkit
#       package. Re-run this script after any proxmox-widget-toolkit upgrade.
#
# Idempotent — safe to re-run; will detect and skip already-patched files.
# =============================================================================

set -euo pipefail

SCRIPT_VERSION="0.02"

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

PRODUCT=""          # pve | pbs | pdm
FILES_PATCHED=()    # list of files successfully patched
FILES_SKIPPED=()    # list of files already patched (idempotent)
FILES_MISSING=()    # list of expected files not found on disk

# Shared widget toolkit — present on all three products
WIDGET_JS="/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js"

# PBS-specific UI library
PBS_JS="/usr/share/javascript/proxmox-backup/proxmoxbackuplib.js"

# Patch fingerprint — string that only exists after the patch is applied.
# Pass 1 produces:  void({ //Ext.Msg.show({
# That is the most reliable sentinel across all PVE/PBS/PDM versions.
PATCH_SENTINEL='void({ //Ext.Msg.show({'

# =============================================================================
# Preflight
# =============================================================================

preflight() {
    [[ $EUID -ne 0 ]] && die "This script must be run as root."

    for cmd in sed grep cp systemctl dpkg-query; do
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
        PRODUCT="pve"; warn "Detected via service pve-cluster → PVE"; return 0
    fi

    if systemctl is-active --quiet proxmox-datacenter-manager 2>/dev/null; then
        PRODUCT="pdm"; warn "Detected via service proxmox-datacenter-manager → PDM"; return 0
    fi

    if systemctl is-active --quiet proxmox-backup 2>/dev/null; then
        PRODUCT="pbs"; warn "Detected via service proxmox-backup → PBS"; return 0
    fi

    # Priority 3: marker files
    if [[ -f /etc/pve/version ]]; then
        PRODUCT="pve"; warn "Detected via /etc/pve/version → PVE"; return 0
    fi

    if [[ -f /usr/share/proxmox-datacenter-manager/RELEASE ]]; then
        PRODUCT="pdm"; warn "Detected via PDM marker file → PDM"; return 0
    fi

    if [[ -f /usr/share/proxmox-backup/RELEASE ]]; then
        PRODUCT="pbs"; warn "Detected via PBS marker file → PBS"; return 0
    fi

    die "Cannot detect a supported Proxmox product (PVE / PBS / PDM). Aborting."
}

# =============================================================================
# Patch Helpers
# =============================================================================

# Backs up a JS file with a timestamped suffix — only if no backup exists yet
# for the current package version, to avoid cluttering /usr/share with stale
# backups on every re-run.
backup_file() {
    local file="$1"
    local backup="${file}.bak"

    if [[ ! -f "${backup}" ]]; then
        cp "${file}" "${backup}"
        info "Backup created: ${backup}"
    else
        info "Backup already exists — skipping: ${backup}"
    fi
}

# Apply the nag-removal patch to a single JS file.
# The patch wraps the Ext.Msg.show "No valid subscription" block in a void()
# so it is never executed, regardless of what the surrounding if-condition
# evaluates to.  This single-pass approach is version-agnostic: it does not
# depend on the exact status comparison string used by a given release
# (e.g. !== 'active', .toLowerCase() !== 'active', !== 'Active', etc.).
#
# Sentinel used to detect an already-patched file:
#   void({ //Ext.Msg.show({
# which is the exact output of the sed substitution below.
#
# Returns 0 on success, 1 if the file does not exist.
patch_file() {
    local file="$1"

    if [[ ! -f "${file}" ]]; then
        warn "File not found — skipping: ${file}"
        FILES_MISSING+=("${file}")
        return 1
    fi

    # Idempotency check — already patched?
    if grep -qF "${PATCH_SENTINEL}" "${file}" 2>/dev/null; then
        success "Already patched — skipping: ${file}"
        FILES_SKIPPED+=("${file##*/}")
        return 0
    fi

    backup_file "${file}"

    # Wrap the Ext.Msg.show "No valid subscription" call in void() so the
    # popup dialog is silently discarded.  Uses -Ezi for multiline matching
    # since the title: line may not immediately follow Ext.Msg.show(.
    sed -Ezi \
        's/(Ext\.Msg\.show\(\{\s*title:\s*gettext\(.No valid sub)/void\(\{ \/\/\1/g' \
        "${file}"

    # Verify patch was applied using a fixed-string match (-F) to avoid
    # any regex interpretation of the sentinel value.
    if grep -qF "${PATCH_SENTINEL}" "${file}" 2>/dev/null; then
        success "Patched successfully: ${file}"
        FILES_PATCHED+=("${file##*/}")
    else
        warn "Patch may not have applied cleanly to: ${file}"
        warn "The nag check string may have changed in this version."
        warn "Please inspect the file manually: ${file}"
        FILES_SKIPPED+=("${file##*/} (patch unverified)")
    fi
}

# =============================================================================
# Product-Specific Patch Targets
# =============================================================================

patch_pve() {
    step "Patching PVE subscription nag..."
    patch_file "${WIDGET_JS}"
}

patch_pbs() {
    step "Patching PBS subscription nag..."
    patch_file "${WIDGET_JS}"
    patch_file "${PBS_JS}"
}

patch_pdm() {
    step "Patching PDM subscription nag..."
    patch_file "${WIDGET_JS}"
}

# =============================================================================
# Service Restart
# =============================================================================

restart_proxy() {
    step "Restarting proxy service to apply changes..."

    local service
    case "${PRODUCT}" in
        pve) service="pveproxy.service" ;;
        pbs) service="proxmox-backup-proxy.service" ;;
        pdm) service="proxmox-datacenter-api.service" ;;
    esac

    if systemctl restart "${service}" 2>/dev/null; then
        success "Service restarted: ${service}"
    else
        warn "Could not restart ${service} — try manually:"
        warn "  systemctl restart ${service}"
    fi
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

    echo ""
    echo -e "${BOLD}${BLUE}$(printf '═%.0s' $(seq 1 ${width}))${NC}"
    printf "${BOLD}${BLUE}  %-*s${NC}\n" $(( width - 2 )) "RECAP"
    echo -e "${BOLD}${BLUE}$(printf '═%.0s' $(seq 1 ${width}))${NC}"
    printf "  ${BOLD}%-24s${NC} %s\n" "Product:" "${product_label}"

    echo ""
    if (( ${#FILES_PATCHED[@]} > 0 )); then
        printf "  ${BOLD}%-24s${NC}\n" "Files patched:"
        for f in "${FILES_PATCHED[@]}"; do
            printf "    ${GREEN}✔${NC} %s\n" "${f}"
        done
    fi

    if (( ${#FILES_SKIPPED[@]} > 0 )); then
        printf "  ${BOLD}%-24s${NC}\n" "Files skipped:"
        for f in "${FILES_SKIPPED[@]}"; do
            printf "    ${YELLOW}–${NC} %s\n" "${f}"
        done
    fi

    if (( ${#FILES_MISSING[@]} > 0 )); then
        printf "  ${BOLD}%-24s${NC}\n" "Files not found:"
        for f in "${FILES_MISSING[@]}"; do
            printf "    ${RED}✘${NC} %s\n" "${f}"
        done
    fi

    echo ""
    printf "  ${BOLD}%-24s${NC} %s\n" "Browser action:" "Hard-refresh the UI (Ctrl+Shift+R)"
    echo ""
    echo -e "  ${CYAN}NOTE: This patch is lost when proxmox-widget-toolkit${NC}"
    echo -e "  ${CYAN}is upgraded by apt. Re-run this script after upgrades.${NC}"
    echo -e "${BOLD}${BLUE}$(printf '═%.0s' $(seq 1 ${width}))${NC}"
    echo ""
}

# =============================================================================
# Main
# =============================================================================

main() {
    echo ""
    echo -e "${BOLD}${BLUE}$(printf '═%.0s' $(seq 1 62))${NC}"
    printf "${BOLD}${BLUE}  %-58s${NC}\n" "proxmox-remove-nag.sh  v${SCRIPT_VERSION}"
    printf "${BOLD}${BLUE}  %-58s${NC}\n" "Proxmox Subscription Nag Remover"
    echo -e "${BOLD}${BLUE}$(printf '═%.0s' $(seq 1 62))${NC}"
    echo ""

    preflight

    # ── Detection ───────────────────────────────────────────────────────────
    detect_product

    # ── Patching ─────────────────────────────────────────────────────────────
    case "${PRODUCT}" in
        pve) patch_pve ;;
        pbs) patch_pbs ;;
        pdm) patch_pdm ;;
    esac

    # ── Service restart ──────────────────────────────────────────────────────
    # Only restart if we actually patched something new
    if (( ${#FILES_PATCHED[@]} > 0 )); then
        restart_proxy
    else
        info "No new patches applied — skipping service restart."
    fi

    # ── Recap ────────────────────────────────────────────────────────────────
    print_recap

    success "Done. Hard-refresh your browser (Ctrl+Shift+R) to clear the cached JS."
}

main "$@"
