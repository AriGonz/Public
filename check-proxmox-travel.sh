#!/usr/bin/env bash
# Usage: bash -c "$(curl -fsSL https://raw.githubusercontent.com/AriGonz/Public/refs/heads/main/check-proxmox-travel.sh)"
#
# check-proxmox-travel.sh - Hardened version with error handling
# Outputs to ./check-proxmox-travel.json by default

set -euo pipefail

DEFAULT_OUTPUT="check-proxmox-travel.json"
OUTPUT_FILE="${1:-$DEFAULT_OUTPUT}"

safe_jq() { jq "$@" 2>/dev/null || echo 'null'; }

get_proxmox_version() {
    pveversion | grep -oP 'pve-manager/\K[0-9]+\.[0-9]+' || echo "unknown"
}

get_cpu_info() {
    lscpu 2>/dev/null | grep -E 'Model name|Socket|Core|Thread' | \
        awk -F: '{gsub(/^[ \t]+|[ \t]+$/, "", $2); print "\"" $1 "\": \"" $2 "\""}' | \
        paste -sd, - | { echo "{"; cat; echo "}"; } || echo "{}"
}

get_ram_total() {
    free -m 2>/dev/null | awk '/Mem:/ {printf "%.0f", $2 / 1024}' || echo "0"
}

get_storage_info() {
    df -h / 2>/dev/null | awk 'NR==2 {gsub(/[A-Za-z]+$/, "", $2); print $2}' || echo "0"
}

get_nics() {
    ip link show 2>/dev/null | grep -oP '^[0-9]+: \K(en[^:]+|eth[^:]+)' | \
        jq -R . | jq -s . 2>/dev/null || echo "[]"
}

get_nic_details() {
    local nics; nics=$(get_nics | jq -r '.[]' 2>/dev/null || true)
    local details=()
    for nic in $nics; do
        vendor=$(ethtool -i "$nic" 2>/dev/null | grep '^driver:' | awk '{print $2}' || echo "unknown")
        status=$(ip link show "$nic" 2>/dev/null | grep -oP 'state \K\w+' || echo "unknown")
        details+=("{\"name\":\"$nic\",\"vendor\":\"$vendor\",\"status\":\"$status\"}")
    done
    if [ ${#details[@]} -eq 0 ]; then echo "[]"; else echo "[${details[*]}]" | safe_jq -s 'add'; fi
}

get_bridges() {
    brctl show 2>/dev/null | awk 'NR>1 {print $1}' | jq -R . | jq -s . 2>/dev/null || echo "[]"
}

check_opnsense() {
    local iso_exists=$(ls /var/lib/vz/template/iso/opnsense*.iso 2>/dev/null | wc -l || echo 0)
    local vm_exists=$(qm list 2>/dev/null | grep -i opnsense | wc -l || echo 0)
    echo "{\"iso_exists\":$((iso_exists > 0)), \"vm_exists\":$((vm_exists > 0))}"
}

assess_readiness() {
    local version=$(get_proxmox_version)
    local ram=$(get_ram_total)
    local storage=$(get_storage_info)
    local nic_count=$(get_nics | jq 'length' 2>/dev/null || echo 0)
    local bridges=$(get_bridges | jq 'length' 2>/dev/null || echo 0)

    local ram_ok=$((ram >= 16 ? 1 : 0))
    local storage_num=${storage%%.*}; storage_num=${storage_num:-0}
    local storage_ok=$((storage_num >= 128 ? 1 : 0))
    local nics_ok=$((nic_count >= 2 ? 1 : 0))
    local version_ok=$([[ "$version" =~ ^9\.[1-9] || "$version" == "9.1" ]] && echo 1 || echo 0)
    local bridges_ok=$((bridges >= 2 ? 1 : 0))

    local missing=()
    ((ram_ok)) || missing+=("RAM upgrade (need >=16GB)")
    ((storage_ok)) || missing+=("Storage upgrade (need >=128GB)")
    ((nics_ok)) || missing+=("Add NIC (need >=2 Ethernet)")
    ((version_ok)) || missing+=("Update Proxmox (>=9.1)")
    ((bridges_ok)) || missing+=("Create bridges (vmbr0/vmbr1)")

    local missing_json; missing_json=$(printf '%s\n' "${missing[@]}" | jq -R . | jq -s . 2>/dev/null || echo "[]")

    echo "{\"ram_ok\":$((ram_ok)), \"storage_ok\":$((storage_ok)), \"nics_ok\":$((nics_ok)), \"version_ok\":$((version_ok)), \"bridges_ok\":$((bridges_ok)), \"missing\":$missing_json}"
}

# Main JSON assembly
{
    cat <<EOF
{
  "proxmox_version": "$(get_proxmox_version)",
  "cpu_info": $(get_cpu_info | safe_jq . || echo "{}"),
  "ram_gb": $(get_ram_total),
  "storage_root_gb": "$(get_storage_info)",
  "nics": $(get_nics),
  "nic_details": $(get_nic_details),
  "bridges": $(get_bridges),
  "opnsense": $(check_opnsense),
  "readiness": $(assess_readiness)
}
EOF
} | jq . > "$OUTPUT_FILE" 2>/dev/null || {
    echo "Error: Failed to generate valid JSON (check debug output above)" >&2
    exit 1
}

echo "Diagnostic complete. JSON written to: $OUTPUT_FILE" >&2
echo "Run 'cat $OUTPUT_FILE | jq .' to view" >&2
