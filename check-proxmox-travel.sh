#!/usr/bin/env bash
# Version 0.02
# Usage: bash -c "$(curl -fsSL https://raw.githubusercontent.com/AriGonz/Public/refs/heads/main/check-proxmox-travel.sh)"
#
# check-proxmox-travel.sh
# Diagnostic tool to assess if a Proxmox node is ready to become a portable travel router
# Writes output to ./check-proxmox-travel.json by default

set -euo pipefail

DEFAULT_OUTPUT="check-proxmox-travel.json"
OUTPUT_FILE="${1:-$DEFAULT_OUTPUT}"

# Helper: safe jq that returns fallback on failure
safe_jq() { jq "$@" 2>/dev/null || echo "${2:-null}"; }

# ──────────────────────────────────────────────────────────────────────────────
# Data collection functions
# ──────────────────────────────────────────────────────────────────────────────

get_version() { echo "0.02"; }

get_proxmox_version() {
    pveversion 2>/dev/null | grep -oP 'pve-manager/\K[\d.]+' || echo "unknown"
}

get_cpu_model() {
    lscpu 2>/dev/null | grep "Model name:" | cut -d':' -f2- | sed 's/^[ \t]*//' || echo "unknown"
}

get_cpu_cores() {
    lscpu 2>/dev/null | grep "^CPU(s):" | awk '{print $2}' || echo 0
}

get_cpu_threads() {
    lscpu 2>/dev/null | grep "^Thread(s) per core:" | awk '{print $4}' || echo 0
}

get_ram_gb() {
    free -m 2>/dev/null | awk '/Mem:/ {printf "%.0f", $2 / 1024}' || echo 0
}

get_root_storage_gb() {
    df -BG / 2>/dev/null | awk 'NR==2 {gsub(/G$/,"",$2); print $2+0}' || echo 0
}

get_available_storage_gb() {
    local pool=$(pvesm status 2>/dev/null | grep -E 'local-lvm|local-zfs|local' | head -1 | awk '{print $1}')
    if [[ -n "$pool" ]]; then
        pvesm status | grep "^$pool" | awk '{printf "%.0f", $4 / 1024 / 1024 / 1024}' || echo 0
    else
        echo 0
    fi
}

get_nics() {
    ip -o link show 2>/dev/null | grep -E 'en|eth' | awk '{print $2}' | sed 's/:$//' | safe_jq -R . -s .
}

get_nic_details() {
    local nics; mapfile -t nics < <(get_nics | jq -r '.[]' 2>/dev/null || true)
    local out=()
    for nic in "${nics[@]}"; do
        [[ -z "$nic" ]] && continue
        driver=$(ethtool -i "$nic" 2>/dev/null | grep '^driver:' | awk '{print $2}' || echo "unknown")
        state=$(ip link show "$nic" 2>/dev/null | grep -oP 'state \K\w+' || echo "DOWN")
        speed=$(ethtool "$nic" 2>/dev/null | grep 'Speed:' | awk '{print $2}' || echo "unknown")
        out+=("{\"name\":\"$nic\",\"driver\":\"$driver\",\"state\":\"$state\",\"speed\":\"$speed\"}")
    done
    if [ ${#out[@]} -eq 0 ]; then echo "[]"; else printf '%s\n' "${out[@]}" | jq -s .; fi
}

get_bridges() {
    brctl show 2>/dev/null | awk 'NR>1 && $1 ~ /^vmbr/ {print $1}' | safe_jq -R . -s . || echo "[]"
}

get_iommu_status() {
    dmesg | grep -i iommu 2>/dev/null | grep -qi 'DMAR: IOMMU enabled' && echo true || echo false
}

get_virt_support() {
    egrep -c '(vmx|svm)' /proc/cpuinfo 2>/dev/null | awk '{print $1 > 0 ? "true" : "false"}' || echo "false"
}

check_opnsense() {
    local iso_count=$(find /var/lib/vz/template/iso -name 'OPNsense*.iso' 2>/dev/null | wc -l || echo 0)
    local vm_count=$(qm list 2>/dev/null | grep -i opnsense | wc -l || echo 0)
    echo "{\"iso_present\":$((iso_count > 0)), \"vm_exists\":$((vm_count > 0))}"
}

# Readiness assessment
assess_readiness() {
    local pv=$(get_proxmox_version)
    local ram=$(get_ram_gb)
    local storage=$(get_root_storage_gb)
    local avail=$(get_available_storage_gb)
    local nics=$(get_nics | jq length 2>/dev/null || echo 0)
    local bridges=$(get_bridges | jq length 2>/dev/null || echo 0)
    local cores=$(get_cpu_cores)

    local checks=(
        "version_ok":$([[ "$pv" > "9.0" ]] && echo true || echo false)
        "ram_ok":$((ram >= 16 ? true : false))
        "storage_ok":$((storage >= 128 ? true : false))
        "avail_storage_ok":$((avail >= 50 ? true : false))   # at least 50GB free recommended
        "nics_ok":$((nics >= 2 ? true : false))
        "cores_ok":$((cores >= 4 ? true : false))
        "iommu_ok":$(get_iommu_status)
        "virt_ok":$(get_virt_support)
    )

    local missing=()
    [[ "${checks[version_ok]}" != "true" ]] && missing+=("Proxmox >= 9.1 recommended")
    [[ "${checks[ram_ok]}" != "true" ]] && missing+=("RAM >= 16 GB")
    [[ "${checks[storage_ok]}" != "true" ]] && missing+=("Root disk >= 128 GB")
    [[ "${checks[avail_storage_ok]}" != "true" ]] && missing+=("At least 50 GB free space recommended")
    [[ "${checks[nics_ok]}" != "true" ]] && missing+=("At least 2 Ethernet NICs")
    [[ "${checks[cores_ok]}" != "true" ]] && missing+=("At least 4 CPU cores recommended")
    [[ "${checks[iommu_ok]}" != "true" ]] && missing+=("IOMMU not enabled/detected — passthrough may not work")
    [[ "${checks[virt_ok]}" != "true" ]] && missing+=("CPU virtualization extensions not detected")

    local missing_json=$(printf '%s\n' "${missing[@]}" | safe_jq -R . -s . || echo "[]")

    jq -n \
        --argjson checks "$(printf '%s\n' "${checks[@]}")" \
        --argjson missing "$missing_json" \
        '{checks: $checks, missing: $missing}'
}

# ──────────────────────────────────────────────────────────────────────────────
# Main output
# ──────────────────────────────────────────────────────────────────────────────

{
    cat <<EOF
{
  "script_version": "$(get_version)",
  "proxmox_version": "$(get_proxmox_version)",
  "cpu_model": "$(get_cpu_model)",
  "cpu_cores": $(get_cpu_cores),
  "cpu_threads_per_core": $(get_cpu_threads),
  "ram_gb": $(get_ram_gb),
  "root_storage_gb": $(get_root_storage_gb),
  "available_storage_gb": $(get_available_storage_gb),
  "nics": $(get_nics),
  "nic_details": $(get_nic_details),
  "bridges": $(get_bridges),
  "iommu_enabled": $(get_iommu_status),
  "virtualization_supported": $(get_virt_support),
  "opnsense": $(check_opnsense),
  "readiness": $(assess_readiness)
}
EOF
} | jq . > "$OUTPUT_FILE" 2>/dev/null || {
    echo "Error: JSON generation failed. Run with bash -x for debug." >&2
    exit 1
}

echo "Diagnostic complete (v$(get_version)). Results saved to: $OUTPUT_FILE" >&2
echo "View with: cat $OUTPUT_FILE | jq ." >&2
