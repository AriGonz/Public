#!/usr/bin/env bash
# =============================================================================
# proxmox-update.sh
# Universal Proxmox repository configurator & system updater
# Supports: PVE 9.x | PBS | PDM
#
# Usage  : bash -c "$(curl -fsSL https://raw.githubusercontent.com/AriGonz/Public/refs/heads/main/Proxmox/shared/proxmox-update.sh)"

# What this script does:
#   1. Detects the installed Proxmox product (PVE / PBS / PDM)
#   2. Detects the Debian codename (bookworm / trixie)
#   3. Disables all enterprise/subscription repos
#   4. Removes stale .bak* repo files
#   5. Ensures the correct no-subscription community repo is present
#   6. Ensures standard Debian repos are present and correct
#   7. Validates repos with apt-get update
#   8. Runs apt-get full-upgrade + autoremove
#   9. Reports post-upgrade recommendations (reboot / service restart)
#  10. Prints a final recap table
#
# Idempotent — safe to re-run on an already-configured system.
# =============================================================================

set -euo pipefail

SCRIPT_VERSION="0.02"
echo "proxmox-update.sh v${SCRIPT_VERSION}"

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
# Global State (populated during detection & upgrade phases)
# =============================================================================

PRODUCT=""          # pve | pbs | pdm
CODENAME=""         # bookworm | trixie
REPOS_CONFIGURED=() # list of repo actions taken
PKGS_UPGRADED=0     # count of upgraded packages
REBOOT_NEEDED=false
RESTART_NEEDED=""   # service name if restart recommended

# =============================================================================
# Detection
# =============================================================================

detect_product() {
    step "Detecting installed Proxmox product..."

    # Priority 1: installed package presence
    if dpkg-query -W -f='${Status}' pve-manager 2>/dev/null | grep -q "install ok installed"; then
        PRODUCT="pve"
        success "Detected product via package: pve-manager → PVE"
        return 0
    fi

    if dpkg-query -W -f='${Status}' proxmox-datacenter-manager 2>/dev/null | grep -q "install ok installed"; then
        PRODUCT="pdm"
        success "Detected product via package: proxmox-datacenter-manager → PDM"
        return 0
    fi

    if dpkg-query -W -f='${Status}' proxmox-backup-server 2>/dev/null | grep -q "install ok installed"; then
        PRODUCT="pbs"
        success "Detected product via package: proxmox-backup-server → PBS"
        return 0
    fi

    # Priority 2: running service names
    if systemctl is-active --quiet pve-cluster 2>/dev/null; then
        PRODUCT="pve"
        warn "Package not found; detected product via service pve-cluster → PVE"
        return 0
    fi

    if systemctl is-active --quiet proxmox-datacenter-manager 2>/dev/null; then
        PRODUCT="pdm"
        warn "Package not found; detected product via service proxmox-datacenter-manager → PDM"
        return 0
    fi

    if systemctl is-active --quiet proxmox-backup 2>/dev/null; then
        PRODUCT="pbs"
        warn "Package not found; detected product via service proxmox-backup → PBS"
        return 0
    fi

    # Priority 3: product-specific marker files / os-release
    if [[ -f /etc/pve/version ]]; then
        PRODUCT="pve"
        warn "Package/service not found; detected product via /etc/pve/version → PVE"
        return 0
    fi

    if [[ -f /usr/share/proxmox-datacenter-manager/RELEASE ]]; then
        PRODUCT="pdm"
        warn "Package/service not found; detected product via PDM marker file → PDM"
        return 0
    fi

    if [[ -f /usr/share/proxmox-backup/RELEASE ]]; then
        PRODUCT="pbs"
        warn "Package/service not found; detected product via PBS marker file → PBS"
        return 0
    fi

    die "Cannot detect a supported Proxmox product (PVE / PBS / PDM). Aborting."
}

detect_codename() {
    step "Detecting Debian codename..."

    local version_codename
    version_codename=$(grep -oP '(?<=^VERSION_CODENAME=).*' /etc/os-release 2>/dev/null || true)

    # Strip any surrounding quotes that some distros add
    version_codename="${version_codename//\"/}"

    case "${version_codename}" in
        bookworm|trixie)
            CODENAME="${version_codename}"
            success "Codename detected: ${CODENAME}"
            ;;
        *)
            die "Unsupported Debian codename '${version_codename}'. Only bookworm and trixie are supported."
            ;;
    esac
}

# =============================================================================
# Repository Helpers
# =============================================================================

# Disable a .list-format repo file by commenting out active deb lines
_disable_list_file() {
    local file="$1"
    local changed=false

    # Only act if the file contains uncommented deb lines
    if grep -qP '^\s*deb\s' "${file}" 2>/dev/null; then
        # Comment out all active deb / deb-src lines
        sed -i 's|^\(\s*deb\)|#\1|g' "${file}"
        changed=true
    fi

    ${changed} && info "Disabled (commented): ${file}"
}

# Disable a .sources-format repo file by setting Enabled: no
_disable_sources_file() {
    local file="$1"

    # If already has Enabled: no, skip
    if grep -qi '^\s*Enabled\s*:\s*no' "${file}" 2>/dev/null; then
        info "Already disabled: ${file}"
        return 0
    fi

    # If it has Enabled: yes, flip it
    if grep -qi '^\s*Enabled\s*:' "${file}" 2>/dev/null; then
        sed -i 's|^\(\s*Enabled\s*:\s*\).*|\1no|I' "${file}"
        info "Disabled (Enabled: no): ${file}"
        return 0
    fi

    # No Enabled field present — inject one before the first blank line or at top
    sed -i '1s|^|Enabled: no\n|' "${file}"
    info "Disabled (injected Enabled: no): ${file}"
}

# Disable all enterprise/subscription repos for the detected product
# Also disables Ceph enterprise repos which are present on PVE nodes.
disable_enterprise_repos() {
    step "Disabling enterprise/subscription repositories..."

    local -a targets=()

    case "${PRODUCT}" in
        pve) targets=(
                "/etc/apt/sources.list.d/pve-enterprise.list"
                "/etc/apt/sources.list.d/pve-enterprise.sources"
                # Ceph enterprise repos — present on PVE nodes regardless of
                # whether Ceph is actively used; always safe to disable.
                "/etc/apt/sources.list.d/ceph.list"
                "/etc/apt/sources.list.d/ceph.sources"
            ) ;;
        pbs) targets=(
                "/etc/apt/sources.list.d/pbs-enterprise.list"
                "/etc/apt/sources.list.d/pbs-enterprise.sources"
            ) ;;
        pdm) targets=(
                "/etc/apt/sources.list.d/pdm-enterprise.list"
                "/etc/apt/sources.list.d/pdm-enterprise.sources"
            ) ;;
    esac

    local found=false
    for f in "${targets[@]}"; do
        if [[ -f "${f}" ]]; then
            found=true
            case "${f}" in
                *.list)    _disable_list_file    "${f}" ;;
                *.sources) _disable_sources_file "${f}" ;;
            esac
            REPOS_CONFIGURED+=("disabled: ${f##*/}")
        fi
    done

    ${found} || info "No enterprise repo files found — nothing to disable."
}

# Remove stale .bak* files from sources.list.d
remove_stale_bak_files() {
    step "Removing stale .bak* files from /etc/apt/sources.list.d/..."

    local count=0
    local f
    for f in /etc/apt/sources.list.d/*.bak*; do
        [[ -e "${f}" ]] || continue          # glob matched nothing
        rm -f "${f}"
        info "Removed: ${f}"
        (( count++ )) || true
    done

    if (( count > 0 )); then
        success "Removed ${count} stale .bak* file(s)."
        REPOS_CONFIGURED+=("removed ${count} .bak* files")
    else
        info "No stale .bak* files found."
    fi
}

# Ensure the no-subscription community repo is present
add_no_subscription_repo() {
    step "Configuring no-subscription community repository..."

    local repo_url repo_suite repo_component no_sub_file

    case "${PRODUCT}" in
        pve) repo_url="http://download.proxmox.com/debian/pve" ;;
        pbs) repo_url="http://download.proxmox.com/debian/pbs" ;;
        pdm) repo_url="http://download.proxmox.com/debian/pdm" ;;
    esac

    repo_suite="${CODENAME}"
    repo_component="pve-no-subscription"

    case "${PRODUCT}" in
        pbs) repo_component="pbs-no-subscription" ;;
        pdm) repo_component="pdm-no-subscription" ;;
    esac

    no_sub_file="/etc/apt/sources.list.d/${PRODUCT}-no-subscription.list"

    local desired_line="deb ${repo_url} ${repo_suite} ${repo_component}"

    # Check if the exact line is already active (uncommented) in any list file
    if grep -rh '^\s*deb\s' /etc/apt/sources.list.d/ /etc/apt/sources.list 2>/dev/null \
            | grep -qF "${repo_url}"; then
        success "No-subscription repo already present — skipping."
        info "  ${desired_line}"
        return 0
    fi

    echo "${desired_line}" > "${no_sub_file}"
    success "Added no-subscription repo: ${no_sub_file}"
    info "  ${desired_line}"
    REPOS_CONFIGURED+=("added: ${no_sub_file##*/}")
}

# Returns true if a given URL+suite combo is already configured in ANY active
# repo source — handles both .list format (deb ...) and .sources format
# (URIs: / Suites: stanzas). Checks both enabled and to-be-enabled state.
_repo_already_present() {
    local url="$1" suite="$2"

    # 1. Check .list files — uncommented deb lines
    if grep -rh '^\s*deb\s' /etc/apt/sources.list.d/ /etc/apt/sources.list 2>/dev/null \
            | grep -q "${url}.*${suite}"; then
        return 0
    fi

    # 2. Check .sources files (DEB822 format) — look for the URL in URIs: lines
    #    and the suite in Suites: lines within the same stanza.
    #    Strategy: scan each .sources file; if a stanza contains both the URL
    #    and the suite and is NOT explicitly disabled, consider it present.
    local sf
    for sf in /etc/apt/sources.list.d/*.sources; do
        [[ -f "${sf}" ]] || continue

        # Skip fully disabled stanzas
        if grep -qi '^\s*Enabled\s*:\s*no' "${sf}" 2>/dev/null; then
            continue
        fi

        if grep -q "${url}" "${sf}" 2>/dev/null \
                && grep -q "\b${suite}\b" "${sf}" 2>/dev/null; then
            return 0
        fi
    done

    return 1
}

# Ensure standard Debian repos are present and correct.
#
# PVE 9 ships /etc/apt/sources.list.d/debian.sources (DEB822 format) which
# already covers main, updates, and security.  On those systems sources.list
# should stay empty to avoid duplicate-source warnings from apt.
# On older installs or PBS/PDM nodes that lack debian.sources, we fall back to
# writing the classic deb lines into /etc/apt/sources.list.
ensure_debian_repos() {
    step "Ensuring standard Debian repositories are present..."

    local debian_sources="/etc/apt/sources.list.d/debian.sources"
    local debian_list="/etc/apt/sources.list"

    # The three repo URL+suite pairs we need covered
    local -a required=(
        "http://deb.debian.org/debian|${CODENAME}"
        "http://deb.debian.org/debian|${CODENAME}-updates"
        "http://security.debian.org/debian-security|${CODENAME}-security"
    )

    # Check whether debian.sources already covers everything
    local all_present=true
    for entry in "${required[@]}"; do
        local url suite
        url="${entry%%|*}"
        suite="${entry##*|}"
        if ! _repo_already_present "${url}" "${suite}"; then
            all_present=false
            break
        fi
    done

    if ${all_present}; then
        success "All standard Debian repos already present (via debian.sources or sources.list)."
        # Ensure sources.list doesn't duplicate what debian.sources provides —
        # wipe any deb.debian.org / security.debian.org lines from sources.list
        # so apt doesn't warn about duplicate sources.
        if grep -qE 'deb\.debian\.org|security\.debian\.org' "${debian_list}" 2>/dev/null; then
            sed -i '/deb\.debian\.org\|security\.debian\.org/d' "${debian_list}"
            info "Removed redundant Debian lines from ${debian_list} (covered by debian.sources)."
            REPOS_CONFIGURED+=("cleaned redundant lines from sources.list")
        fi
        return 0
    fi

    # debian.sources absent or incomplete — write classic .list lines
    local -a missing_lines=(
        "deb http://deb.debian.org/debian ${CODENAME} main contrib"
        "deb http://deb.debian.org/debian ${CODENAME}-updates main contrib"
        "deb http://security.debian.org/debian-security ${CODENAME}-security main contrib"
    )

    local added=0
    for line in "${missing_lines[@]}"; do
        local url suite
        url=$(echo "${line}" | awk '{print $2}')
        suite=$(echo "${line}" | awk '{print $3}')
        if _repo_already_present "${url}" "${suite}"; then
            info "Already present: ${line}"
        else
            echo "${line}" >> "${debian_list}"
            info "Added: ${line}"
            (( added++ )) || true
        fi
    done

    if (( added > 0 )); then
        success "Added ${added} missing Debian repo line(s) to ${debian_list}."
        REPOS_CONFIGURED+=("added ${added} Debian repo line(s)")
    else
        success "All standard Debian repos already present."
    fi
}

# Validate repos by running apt-get update and confirming a resolvable package
validate_repos() {
    step "Validating repository configuration with apt-get update..."

    if ! apt-get update 2>&1 | tee /tmp/proxmox-update-apt.log; then
        die "apt-get update failed. See /tmp/proxmox-update-apt.log for details."
    fi

    # Confirm a product-specific package is resolvable in the new repo
    local probe_pkg
    case "${PRODUCT}" in
        pve) probe_pkg="pve-manager" ;;
        pbs) probe_pkg="proxmox-backup-server" ;;
        pdm) probe_pkg="proxmox-datacenter-manager" ;;
    esac

    if ! apt-cache show "${probe_pkg}" &>/dev/null; then
        die "Repository validation failed: cannot resolve package '${probe_pkg}'. Check repo URLs and network connectivity."
    fi

    success "Repository validated — '${probe_pkg}' is resolvable."
}

# =============================================================================
# System Update
# =============================================================================

run_upgrade() {
    step "Running apt-get full-upgrade..."

    # Capture the list of packages before upgrade to diff afterwards
    local before_file after_file
    before_file=$(mktemp /tmp/proxmox-pkgs-before-XXXXXX)
    after_file=$(mktemp /tmp/proxmox-pkgs-after-XXXXXX)

    dpkg-query -W -f='${Package} ${Version}\n' | sort > "${before_file}"

    DEBIAN_FRONTEND=noninteractive \
        apt-get full-upgrade -y \
            -o Dpkg::Options::="--force-confdef" \
            -o Dpkg::Options::="--force-confold" \
        || die "apt-get full-upgrade failed."

    dpkg-query -W -f='${Package} ${Version}\n' | sort > "${after_file}"

    # Count changed packages (version lines that differ)
    PKGS_UPGRADED=$(diff "${before_file}" "${after_file}" | grep -c '^[<>]' || true)
    # diff counts both old and new lines, so divide by 2 for unique packages
    PKGS_UPGRADED=$(( PKGS_UPGRADED / 2 ))

    rm -f "${before_file}" "${after_file}"

    success "full-upgrade complete. ~${PKGS_UPGRADED} package(s) changed."
}

run_autoremove() {
    step "Running apt-get autoremove..."
    DEBIAN_FRONTEND=noninteractive apt-get autoremove -y \
        || warn "autoremove encountered an error (non-fatal)."
    success "autoremove complete."
}

# =============================================================================
# Post-Upgrade Checks
# =============================================================================

check_post_upgrade() {
    step "Checking post-upgrade recommendations..."

    case "${PRODUCT}" in
        pve) _check_pve_kernel ;;
        pbs) _check_pbs_restart ;;
        pdm) _check_pdm_restart ;;
    esac
}

_check_pve_kernel() {
    # Check if a newer pve-kernel package was recently installed
    local new_kernel
    new_kernel=$(find /boot -maxdepth 1 -name 'vmlinuz-*-pve' 2>/dev/null | sort -V | tail -1 || true)

    local running_kernel
    running_kernel=$(uname -r 2>/dev/null || true)

    if [[ -n "${new_kernel}" ]]; then
        local installed_ver="${new_kernel##*/vmlinuz-}"
        if [[ "${installed_ver}" != "${running_kernel}" ]]; then
            warn "A new PVE kernel is installed (${installed_ver}) but not running (${running_kernel})."
            warn "A reboot is required to activate the new kernel."
            REBOOT_NEEDED=true
        else
            success "Running kernel (${running_kernel}) matches the latest installed kernel."
        fi
    else
        info "Could not determine kernel status from /boot — skipping kernel check."
    fi
}

_check_pbs_restart() {
    # If proxmox-backup-server was upgraded (journal shows recent activity), recommend restart
    local service="proxmox-backup"
    if systemctl is-active --quiet "${service}" 2>/dev/null; then
        # Check if the binary on disk is newer than the running process's start time
        local bin="/usr/sbin/proxmox-backup-manager"
        local svc_start pid
        pid=$(systemctl show -p MainPID --value "${service}" 2>/dev/null || true)

        if [[ -n "${pid}" && "${pid}" != "0" && -f "${bin}" ]]; then
            svc_start=$(stat -c '%Y' "/proc/${pid}" 2>/dev/null || echo 0)
            local bin_mtime
            bin_mtime=$(stat -c '%Y' "${bin}" 2>/dev/null || echo 0)

            if (( bin_mtime > svc_start )); then
                warn "proxmox-backup-server binary was updated while service is running."
                warn "Consider restarting the service: systemctl restart ${service}"
                RESTART_NEEDED="${service}"
            else
                success "proxmox-backup service is current — no restart needed."
            fi
        else
            info "Could not determine PBS process age — consider restarting ${service} if upgrade occurred."
            RESTART_NEEDED="${service} (advisory)"
        fi
    else
        info "Service '${service}' is not running — no restart check needed."
    fi
}

_check_pdm_restart() {
    local service="proxmox-datacenter-manager"
    if systemctl is-active --quiet "${service}" 2>/dev/null; then
        local bin="/usr/sbin/proxmox-datacenter-manager"
        local pid svc_start
        pid=$(systemctl show -p MainPID --value "${service}" 2>/dev/null || true)

        if [[ -n "${pid}" && "${pid}" != "0" && -f "${bin}" ]]; then
            svc_start=$(stat -c '%Y' "/proc/${pid}" 2>/dev/null || echo 0)
            local bin_mtime
            bin_mtime=$(stat -c '%Y' "${bin}" 2>/dev/null || echo 0)

            if (( bin_mtime > svc_start )); then
                warn "proxmox-datacenter-manager binary was updated while service is running."
                warn "Consider restarting the service: systemctl restart ${service}"
                RESTART_NEEDED="${service}"
            else
                success "proxmox-datacenter-manager service is current — no restart needed."
            fi
        else
            info "Could not determine PDM process age — consider restarting ${service} if upgrade occurred."
            RESTART_NEEDED="${service} (advisory)"
        fi
    else
        info "Service '${service}' is not running — no restart check needed."
    fi
}

# =============================================================================
# Recap Table
# =============================================================================

print_recap() {
    local width=62

    local product_label codename_label repos_label pkgs_label reboot_label restart_label
    case "${PRODUCT}" in
        pve) product_label="Proxmox VE (PVE)" ;;
        pbs) product_label="Proxmox Backup Server (PBS)" ;;
        pdm) product_label="Proxmox Datacenter Manager (PDM)" ;;
        *)   product_label="${PRODUCT}" ;;
    esac

    codename_label="${CODENAME}"

    if (( ${#REPOS_CONFIGURED[@]} > 0 )); then
        repos_label=$(IFS=$'\n'; echo "${REPOS_CONFIGURED[*]}")
    else
        repos_label="already correct — no changes made"
    fi

    pkgs_label="${PKGS_UPGRADED} package(s) upgraded"

    if ${REBOOT_NEEDED}; then
        reboot_label="${RED}YES — reboot required${NC}"
    else
        reboot_label="${GREEN}no${NC}"
    fi

    if [[ -n "${RESTART_NEEDED}" ]]; then
        restart_label="${YELLOW}${RESTART_NEEDED}${NC}"
    else
        restart_label="${GREEN}none${NC}"
    fi

    echo ""
    echo -e "${BOLD}${BLUE}$(printf '═%.0s' $(seq 1 ${width}))${NC}"
    printf "${BOLD}${BLUE}  %-*s${NC}\n" $(( width - 2 )) "RECAP"
    echo -e "${BOLD}${BLUE}$(printf '═%.0s' $(seq 1 ${width}))${NC}"
    printf "  ${BOLD}%-22s${NC} %s\n"   "Product:"    "${product_label}"
    printf "  ${BOLD}%-22s${NC} %s\n"   "Codename:"   "${codename_label}"
    echo ""
    printf "  ${BOLD}%-22s${NC}\n"      "Repos configured:"
    while IFS= read -r line; do
        printf "    • %s\n" "${line}"
    done <<< "${repos_label}"
    echo ""
    printf "  ${BOLD}%-22s${NC} %s\n"   "Packages upgraded:"  "${pkgs_label}"
    printf "  ${BOLD}%-22s${NC}"        "Reboot needed:"
    echo -e " ${reboot_label}"
    printf "  ${BOLD}%-22s${NC}"        "Service restart:"
    echo -e " ${restart_label}"
    echo -e "${BOLD}${BLUE}$(printf '═%.0s' $(seq 1 ${width}))${NC}"
    echo ""
}

# =============================================================================
# Preflight
# =============================================================================

preflight() {
    [[ $EUID -ne 0 ]] && die "This script must be run as root."

    for cmd in apt-get apt-cache dpkg-query grep sed awk stat diff; do
        command -v "${cmd}" &>/dev/null \
            || die "Required command not found: ${cmd}"
    done
}

# =============================================================================
# Main
# =============================================================================

main() {
    echo ""
    echo -e "${BOLD}${BLUE}$(printf '═%.0s' $(seq 1 62))${NC}"
    printf "${BOLD}${BLUE}  %-58s${NC}\n" "proxmox-update.sh  v${SCRIPT_VERSION}"
    printf "${BOLD}${BLUE}  %-58s${NC}\n" "Universal Proxmox Repo Configurator & Updater"
    echo -e "${BOLD}${BLUE}$(printf '═%.0s' $(seq 1 62))${NC}"
    echo ""

    preflight

    # ── Detection ───────────────────────────────────────────────────────────
    detect_product
    detect_codename

    # ── Repository management ────────────────────────────────────────────────
    disable_enterprise_repos
    remove_stale_bak_files
    add_no_subscription_repo
    ensure_debian_repos
    validate_repos

    # ── System update ────────────────────────────────────────────────────────
    run_upgrade
    run_autoremove

    # ── Post-upgrade checks ──────────────────────────────────────────────────
    check_post_upgrade

    # ── Summary ──────────────────────────────────────────────────────────────
    print_recap

    if ${REBOOT_NEEDED}; then
        warn "ACTION REQUIRED: reboot this node to activate the new kernel."
        warn "  systemctl reboot"
    fi

    if [[ -n "${RESTART_NEEDED}" && "${RESTART_NEEDED}" != *"advisory"* ]]; then
        warn "ACTION REQUIRED: restart the service to apply the upgrade."
        warn "  systemctl restart ${RESTART_NEEDED}"
    fi

    success "Done."
}

main "$@"
