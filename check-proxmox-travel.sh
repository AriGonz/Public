#!/usr/bin/env bash
# Version 0.01
# Usage: bash -c "$(curl -fsSL https://raw.githubusercontent.com/AriGonz/Public/refs/heads/main/check-proxmox-travel.sh)"
#
# Script to check Proxmox node for travel router compatibility
# Outputs results to check-proxmox-travel.txt
# Run as root on Proxmox host

OUTPUT_FILE="check-proxmox-travel.txt"

# Function to append section headers and data
append_section() {
    echo "$1" >> "$OUTPUT_FILE"
    echo "----------------------------------------" >> "$OUTPUT_FILE"
    echo "$2" >> "$OUTPUT_FILE"
    echo "" >> "$OUTPUT_FILE"
}

# Clear output file if it exists
> "$OUTPUT_FILE"

# System Info
append_section "[System Info]" "$(uname -a)"
append_section "[Proxmox Version]" "$(pveversion -v)"

# CPU Info
append_section "[CPU Info]" "$(lscpu)"

# RAM Info
TOTAL_RAM=$(free -m | awk '/^Mem:/{print $2}')
append_section "[RAM Info]" "Total RAM: ${TOTAL_RAM} MB
$(free -h)"

# Storage Info
append_section "[Storage Devices]" "$(lsblk -o NAME,SIZE,TYPE,MODEL)"
append_section "[Root Filesystem Usage]" "$(df -h /)"
append_section "[NVMe Devices]" "$(lspci | grep -i nvme || echo 'No NVMe devices detected')"

# Network Interfaces
append_section "[Network Interfaces]" "$(ip -br link show | grep -E 'eth|en')"
append_section "[Ethernet Controllers (lspci)]" "$(lspci | grep -i ethernet)"
append_section "[Network Configuration]" "$(cat /etc/network/interfaces)"
append_section "[Bridges and Bonds]" "$(brctl show 2>/dev/null || echo 'brctl not installed or no bridges')"
append_section "[IP Addresses]" "$(ip addr show)"

# PCI Devices (for passthrough potential)
append_section "[PCI Devices]" "$(lspci -nn)"

# Installed Packages Relevant to Setup
append_section "[Relevant Packages]" "$(dpkg -l | grep -E 'proxmox|opnsense|qemu|kvm|bridge|vlan' || echo 'No matching packages')"

# Kernel Modules for Networking
append_section "[Loaded Network Modules]" "$(lsmod | grep -E 'igb|ixgbe|e1000|i40e|virtio_net|bridge|vlan' || echo 'No matching modules')"

# Check for Recommended Hardware
echo "[Hardware Checks]" >> "$OUTPUT_FILE"
echo "----------------------------------------" >> "$OUTPUT_FILE"

if [ "$TOTAL_RAM" -ge 16384 ]; then
    echo "RAM: Sufficient (>=16GB)" >> "$OUTPUT_FILE"
else
    echo "RAM: Insufficient (<16GB) - Upgrade recommended" >> "$OUTPUT_FILE"
fi

NIC_COUNT=$(lspci | grep -i ethernet | wc -l)
if [ "$NIC_COUNT" -ge 2 ]; then
    echo "NICs: Sufficient (>=2 Ethernet controllers)" >> "$OUTPUT_FILE"
else
    echo "NICs: Insufficient (<2) - Add USB Ethernet or upgrade hardware" >> "$OUTPUT_FILE"
fi

STORAGE_SIZE=$(df -BG / | awk 'NR==2 {print substr($2, 1, length($2)-1)}')
if [ "$STORAGE_SIZE" -ge 128 ]; then
    echo "Storage: Sufficient (>=128GB on root)" >> "$OUTPUT_FILE"
else
    echo "Storage: Insufficient (<128GB) - Upgrade storage" >> "$OUTPUT_FILE"
fi

INTEL_NIC=$(lspci | grep -i ethernet | grep -i intel | grep -E 'I225|I226' || echo '')
if [ -n "$INTEL_NIC" ]; then
    echo "NIC Type: Preferred Intel I225/I226 detected" >> "$OUTPUT_FILE"
else
    echo "NIC Type: No preferred Intel I225/I226 - Check compatibility (Realtek may work with quirks)" >> "$OUTPUT_FILE"
fi

PVE_MAJOR=$(pveversion | cut -d/ -f2 | cut -d. -f1)
PVE_MINOR=$(pveversion | cut -d/ -f2 | cut -d. -f2)
if [ "$PVE_MAJOR" -ge 9 ] && [ "$PVE_MINOR" -ge 1 ] || [ "$PVE_MAJOR" -gt 9 ]; then
    echo "Proxmox Version: Sufficient (>=9.1)" >> "$OUTPUT_FILE"
else
    echo "Proxmox Version: Insufficient (<9.1) - Update recommended" >> "$OUTPUT_FILE"
fi

echo "" >> "$OUTPUT_FILE"
echo "[End of Checks]" >> "$OUTPUT_FILE"
echo "Use this output as input for the install script." >> "$OUTPUT_FILE"

echo "Check complete. Output written to $OUTPUT_FILE"
