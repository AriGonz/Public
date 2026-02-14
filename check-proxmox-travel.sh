#!/usr/bin/env bash
# Version 0.05
# Usage: bash -c "$(curl -fsSL https://raw.githubusercontent.com/AriGonz/Public/refs/heads/main/check-proxmox-travel.sh)"
#
# check-proxmox-travel.sh
# Diagnostic tool to assess if a Proxmox node is ready to become a portable travel router
# Writes output to ./check-proxmox-travel.json by default

set -euo pipefail

# Install jq if not present, handling Proxmox repo issues
if ! command -v jq &> /dev/null; then
    echo "jq not found, attempting to install..." >&2
    if ! apt update -y &> /dev/null; then
        echo "Apt update failed. Adding Proxmox no-subscription repo..." >&2
        echo "deb http://download.proxmox.com/debian/pve bookworm pve-no-subscription" > /etc/apt/sources.list.d/pve-no-subscription.list
        apt update -y &> /dev/null || { echo "Still failed to update apt. Check internet or repositories manually." >&2; exit 1; }
    fi
    apt install -y jq &> /dev/null || { echo "Failed to install jq. Run 'apt update && apt install -y jq' manually." >&2; exit 1; }
fi

DEFAULT_OUTPUT="check-proxmox-travel.json"
OUTPUT_FILE="${1:-$DEFAULT_OUTPUT}"

# Helper: safe jq that returns fallback on failure
safe_jq() { jq "$@" 2>/dev/null || echo "${2:-null}"; }

# ──────────────────────────────────────────────────────────────────────────────
# Data collection functions
# ──────────────────────────────────────────────────────────────────────────────

get_version() { echo "0.05"; }

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
    local ifaces=$(ip -o link show 2>/dev/null | grep -E 'en|eth' | awk '{print $2}' | sed 's/:$//' )
    if [[ -n "$ifaces" ]]; then
        echo "$ifaces" | jq -R . | jq -s .
    else
        echo '[]'
    fi
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
    local bridges=$(brctl show 2>/dev/null | awk 'NR>1 && $1 ~ /^vmbr/ {print $1}')
    if [[ -n "$bridges" ]]; then
        echo "$bridges" | jq -R . | jq -s .
    else
        echo '[]'
    fi
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
    echo "{\"iso_present\": $((iso_count > 0)), \"vm_exists\": $((vm_count > 0))}"
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

    local version_ok
    if [[ "$pv" > "9.0" ]]; then version_ok=true; else version_ok=false; fi
    local ram_ok
    if (( ram >= 16 )); then ram_ok=true; else ram_ok=false; fi
    local storage_ok
    if (( storage >= 128 )); then storage_ok=true; else storage_ok=false; fi
    local avail_ok
    if (( avail >= 50 )); then avail_ok=true; else avail_ok=false; fi
    local nics_ok
    if (( nics >= 2 )); then nics_ok=true; else nics_ok=false; fi
    local cores_ok
    if (( cores >= 4 )); then cores_ok=true; else cores_ok=false; fi
    local iommu_ok=$(get_iommu_status)
    local virt_ok=$(get_virt_support)

    local missing=()
    [[ "$version_ok" == "true" ]] || missing+=("Proxmox >= 9.1 recommended")
    [[ "$ram_ok" == "true" ]] || missing+=("RAM >= 16 GB")
    [[ "$storage_ok" == "true" ]] || missing+=("Root disk >= 128 GB")
    [[ "$avail_ok" == "true" ]] || missing+=("At least 50 GB free space recommended")
    [[ "$nics_ok" == "true" ]] || missing+=("At least 2 Ethernet NICs")
    [[ "$cores_ok" == "true" ]] || missing+=("At least 4 CPU cores recommended")
    [[ "$iommu_ok" == "true" ]] || missing+=("IOMMU not enabled/detected — passthrough may not work")
    [[ "$virt_ok" == "true" ]] || missing+=("CPU virtualization extensions not detected")

    local missing_json=$(printf '%s\n' "${missing[@]}" | safe_jq -R . -s . || echo "[]")

    echo "{\"version_ok\": $version_ok, \"ram_ok\": $ram_ok, \"storage_ok\": $storage_ok, \"avail_storage_ok\": $avail_ok, \"nics_ok\": $nics_ok, \"cores_ok\": $cores_ok, \"iommu_ok\": $iommu_ok, \"virt_ok\": $virt_ok, \"missing\":$missing_json}"
}

# ──────────────────────────────────────────────────────────────────────────────
# Main output
# ──────────────────────────────────────────────────────────────────────────────

{
    echo "{"
    echo "\"script_version\": \"$(get_version)\","
    echo "\"proxmox_version\": \"$(get_proxmox_version)\","
    echo "\"cpu_model\": \"$(get_cpu_model)\","
    echo "\"cpu_cores\": $(get_cpu_cores),"
    echo "\"cpu_threads_per_core\": $(get_cpu_threads),"
    echo "\"ram_gb\": $(get_ram_gb),"
    echo "\"root_storage_gb\": $(get_root_storage_gb),"
    echo "\"available_storage_gb\": $(get_available_storage_gb),"
    echo "\"nics\": $(get_nics),"
    echo "\"nic_details\": $(get_nic_details),"
    echo "\"bridges\": $(get_bridges),"
    echo "\"iommu_enabled\": $(get_iommu_status),"
    echo "\"virtualization_supported\": $(get_virt_support),"
    echo "\"opnsense\": $(check_opnsense),"
    echo "\"readiness\": $(assess_readiness)"
    echo "}"
} | jq . > "$OUTPUT_FILE" 2>/dev/null || {
    echo "Error: JSON generation failed. Run with bash -x for debug." >&2
    exit 1
}

echo "Diagnostic complete (v$(get_version)). Results saved to: $OUTPUT_FILE" >&2
echo "View with: cat $OUTPUT_FILE | jq ." >&2
