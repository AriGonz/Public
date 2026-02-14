#!/usr/bin/env bash
# check-proxmox-travel.sh
# Diagnostic script for Proxmox node to assess readiness as portable travel router.
# Outputs JSON with hardware/software info and readiness flags.
# Usage: bash -c "$(curl -fsSL https://raw.githubusercontent.com/AriGonz/Public/refs/heads/main/check-proxmox-travel.sh)"
# Usage: bash check-proxmox-travel.sh [output_file]  # Defaults to stdout
# Example: bash check-proxmox-travel.sh > check.json

set -euo pipefail

# ──────────────────────────────────────────────────────────────────────────────
#  Helper Functions
# ──────────────────────────────────────────────────────────────────────────────

# Get Proxmox version
get_proxmox_version() {
    pveversion | grep -oP 'pve-manager/\K[0-9]+\.[0-9]+' || echo "unknown"
}

# Get CPU info
get_cpu_info() {
    lscpu | grep -E 'Model name|Socket|Core|Thread' | jq -R 'from_entries' | jq -s 'add'
}

# Get RAM (total in GB)
get_ram_total() {
    free -m | awk '/Mem:/ {printf "%.0f\n", $2 / 1024}'
}

# Get storage info (focus on root disk, size in GB)
get_storage_info() {
    df -h / | awk 'NR==2 {print $2}' | sed 's/G//' || echo "unknown"
}

# Get NICs (Ethernet only, exclude lo/vmbr/veth)
get_nics() {
    ip link show | grep -oP '^[0-9]+: \K(en[^:]+|eth[^:]+)' | jq -R . | jq -s .
}

# Get NIC details (vendor, status)
get_nic_details() {
    local nics=($(get_nics | jq -r '.[]'))
    local details=()
    for nic in "${nics[@]}"; do
        vendor=$(ethtool -i "$nic" | grep driver | awk '{print $2}' || echo "unknown")
        status=$(ip link show "$nic" | grep -oP 'state \K\w+')
        details+=("{\"name\":\"$nic\",\"vendor\":\"$vendor\",\"status\":\"$status\"}")
    done
    echo "[${details[*]}]" | jq -s 'add'
}

# Check existing bridges
get_bridges() {
    brctl show | awk 'NR>1 {print $1}' | jq -R . | jq -s .
}

# Check for OPNsense ISO/VM
check_opnsense() {
    local iso_exists=$(ls /var/lib/vz/template/iso/opnsense*.iso 2>/dev/null | wc -l)
    local vm_exists=$(qm list | grep opnsense 2>/dev/null | wc -l)
    echo "{\"iso_exists\": $( ((iso_exists > 0)) && echo true || echo false ), \"vm_exists\": $( ((vm_exists > 0)) && echo true || echo false )}"
}

# Assess readiness
assess_readiness() {
    local version=$(get_proxmox_version)
    local ram=$(get_ram_total)
    local storage=$(get_storage_info)
    local nic_count=$(get_nics | jq 'length')
    local bridges=$(get_bridges | jq 'length')

    local ram_ok=$( ((ram >= 16)) && echo true || echo false )
    local storage_ok=$( (( $(echo "$storage" | sed 's/\..*//') >= 128 )) && echo true || echo false )  # Approximate, ignore decimals
    local nics_ok=$( ((nic_count >= 2)) && echo true || echo false )
    local version_ok=$( [[ "$version" > "9.0" || "$version" == "9.1" ]] && echo true || echo false )  # Loose check for >=9.1
    local bridges_ok=$( ((bridges >= 2)) && echo true || echo false )  # Ideal: at least vmbr0/vmbr1

    local missing=()
    $ram_ok || missing+=("RAM upgrade (need >=16GB)")
    $storage_ok || missing+=("Storage upgrade (need >=128GB)")
    $nics_ok || missing+=("Add NIC (need >=2 Ethernet)")
    $version_ok || missing+=("Update Proxmox (>=9.1)")
    $bridges_ok || missing+=("Create bridges (vmbr0/vmbr1)")

    echo "{\"ram_ok\":$ram_ok, \"storage_ok\":$storage_ok, \"nics_ok\":$nics_ok, \"version_ok\":$version_ok, \"bridges_ok\":$bridges_ok, \"missing\": $(echo "${missing[*]}" | jq -R . | jq -s .)}"
}

# ──────────────────────────────────────────────────────────────────────────────
#  Main: Collect and Output JSON
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
} | jq . > "${1:-/dev/stdout}"

echo "Diagnostic complete. Output is JSON-ready for install script."
