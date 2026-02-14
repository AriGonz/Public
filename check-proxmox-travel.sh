#!/usr/bin/env bash
# Usage: bash -c "$(curl -fsSL https://raw.githubusercontent.com/AriGonz/Public/refs/heads/main/check-proxmox-travel.sh)"
#
# check-proxmox-travel.sh
# Diagnostic script for Proxmox node readiness as portable travel router.
# Automatically writes output to check-proxmox-travel.json (or custom path if provided)
# Default: creates ./check-proxmox-travel.json
# Example with custom name: bash check-proxmox-travel.sh my-check.json

set -euo pipefail

# ──────────────────────────────────────────────────────────────────────────────
#  Configuration
# ──────────────────────────────────────────────────────────────────────────────

DEFAULT_OUTPUT="check-proxmox-travel.json"
OUTPUT_FILE="${1:-$DEFAULT_OUTPUT}"

# ──────────────────────────────────────────────────────────────────────────────
#  Helper Functions
# ──────────────────────────────────────────────────────────────────────────────

get_proxmox_version() {
    pveversion | grep -oP 'pve-manager/\K[0-9]+\.[0-9]+' || echo "unknown"
}

get_cpu_info() {
    lscpu | grep -E 'Model name|Socket|Core|Thread' | jq -R 'from_entries' | jq -s 'add' 2>/dev/null || echo "{}"
}

get_ram_total() {
    free -m | awk '/Mem:/ {printf "%.0f\n", $2 / 1024}' || echo "0"
}

get_storage_info() {
    df -h / | awk 'NR==2 {print $2}' | sed 's/[A-Za-z]*$//' || echo "0"
}

get_nics() {
    ip link show | grep -oP '^[0-9]+: \K(en[^:]+|eth[^:]+)' | jq -R . | jq -s . 2>/dev/null || echo "[]"
}

get_nic_details() {
    local nics=($(get_nics | jq -r '.[]' 2>/dev/null || true))
    local details=()
    for nic in "${nics[@]}"; do
        vendor=$(ethtool -i "$nic" 2>/dev/null | grep driver | awk '{print $2}' || echo "unknown")
        status=$(ip link show "$nic" 2>/dev/null | grep -oP 'state \K\w+' || echo "unknown")
        details+=("{\"name\":\"$nic\",\"vendor\":\"$vendor\",\"status\":\"$status\"}")
    done
    echo "[${details[*]}]" | jq -s 'add' 2>/dev/null || echo "[]"
}

get_bridges() {
    brctl show | awk 'NR>1 {print $1}' | jq -R . | jq -s . 2>/dev/null || echo "[]"
}

check_opnsense() {
    local iso_exists=$(ls /var/lib/vz/template/iso/opnsense*.iso 2>/dev/null | wc -l)
    local vm_exists=$(qm list 2>/dev/null | grep -i opnsense | wc -l)
    echo "{\"iso_exists\": $( ((iso_exists > 0)) && echo true || echo false ), \"vm_exists\": $( ((vm_exists > 0)) && echo true || echo false )}"
}

assess_readiness() {
    local version=$(get_proxmox_version)
    local ram=$(get_ram_total)
    local storage=$(get_storage_info)
    local nic_count=$(get_nics | jq 'length' 2>/dev/null || echo 0)
    local bridges=$(get_bridges | jq 'length' 2>/dev/null || echo 0)

    local ram_ok=$( ((ram >= 16)) && echo true || echo false )
    local storage_num=${storage%%.*}  # Remove decimal part if present
    local storage_ok=$( ((storage_num >= 128)) && echo true || echo false )
    local nics_ok=$( ((nic_count >= 2)) && echo true || echo false )
    local version_ok=$( [[ "$version" =~ ^9\.[1-9] || "$version" == "9.1" ]] && echo true || echo false )
    local bridges_ok=$( ((bridges >= 2)) && echo true || echo false )

    local missing=()
    $ram_ok || missing+=("RAM upgrade (need >=16GB)")
    $storage_ok || missing+=("Storage upgrade (need >=128GB)")
    $nics_ok || missing+=("Add NIC (need >=2 Ethernet)")
    $version_ok || missing+=("Update Proxmox (>=9.1)")
    $bridges_ok || missing+=("Create bridges (vmbr0/vmbr1)")

    echo "{\"ram_ok\":$ram_ok, \"storage_ok\":$storage_ok, \"nics_ok\":$nics_ok, \"version_ok\":$version_ok, \"bridges_ok\":$bridges_ok, \"missing\":$(echo "${missing[*]}" | jq -R . | jq -s .)}"
}

# ──────────────────────────────────────────────────────────────────────────────
#  Main: Generate JSON and write to file
# ──────────────────────────────────────────────────────────────────────────────

{
    echo "{"
    echo "\"proxmox_version\": \"$(get_proxmox_version)\","
    echo "\"cpu_info\": $(get_cpu_info),"
    echo "\"ram_gb\": $(get_ram_total),"
    echo "\"storage_root_gb\": \"$(get_storage_info)\","
    echo "\"nics\": $(get_nics),"
    echo "\"nic_details\": $(get_nic_details),"
    echo "\"bridges\": $(get_bridges),"
    echo "\"opnsense\": $(check_opnsense),"
    echo "\"readiness\": $(assess_readiness)"
    echo "}"
} | jq . > "$OUTPUT_FILE" 2>/dev/null || {
    echo "Error: Failed to generate valid JSON" >&2
    exit 1
}

echo "Diagnostic complete. JSON written to: $OUTPUT_FILE" >&2
echo "You can now feed this file to your install script, e.g.:" >&2
echo "   bash install-travel-router.sh --input $OUTPUT_FILE" >&2
