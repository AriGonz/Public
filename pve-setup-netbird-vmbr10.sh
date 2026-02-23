#!/bin/bash
# =============================================================================
# Proxmox NetBird → vmbr10 Bridge Setup Script
# For Proxmox VE 9.1.1 and later (uses /etc/network/interfaces + ifupdown2)
#
# What it does:
#   1. Detects the NetBird interface (default: wt0) and its IP/CIDR
#   2. Moves that IP/CIDR to a new Linux bridge vmbr10
#   3. Configures vmbr10 so VMs/LXCs can join the SAME NetBird network
#      (same subnet, host acts as L3 gateway + proxy-ARP)
# Usage: bash -c "$(curl -fsSL https://raw.githubusercontent.com/AriGonz/Public/refs/heads/main/pve-setup-netbird-vmbr10.sh)"
# Version .01
# =============================================================================

set -euo pipefail

NETBIRD_IF="wt0"      # Change only if you used --interface-name when running netbird up
BRIDGE="vmbr10"
INTERFACES_FILE="/etc/network/interfaces"

# ----------------------------- Root check ------------------------------------
if [[ $EUID -ne 0 ]]; then
  echo "❌ Please run this script as root (sudo)"
  exit 1
fi

# ----------------------------- Detect NetBird IP -----------------------------
echo "🔍 Detecting NetBird connection..."

if ! ip link show "$NETBIRD_IF" &>/dev/null; then
  echo "❌ Interface $NETBIRD_IF not found."
  echo "   Make sure NetBird is installed and connected:"
  echo "   netbird status"
  exit 1
fi

# Prefer the 100.64.0.0/10 CGNAT range NetBird uses; fallback to first IPv4
IP_CIDR=$(ip -4 -o addr show "$NETBIRD_IF" | awk '{print $4}' | grep -E '^100\.64\.' | head -n1)
if [[ -z "$IP_CIDR" ]]; then
  IP_CIDR=$(ip -4 -o addr show "$NETBIRD_IF" | awk '{print $4}' | head -n1)
fi

if [[ -z "$IP_CIDR" ]]; then
  echo "❌ No IPv4 address found on $NETBIRD_IF"
  echo "   Run 'netbird up' and try again."
  exit 1
fi

echo "✅ NetBird IP detected: $IP_CIDR on $NETBIRD_IF"

# ----------------------------- Backup ---------------------------------------
BACKUP="${INTERFACES_FILE}.netbird-bak.$(date +%Y%m%d_%H%M%S)"
cp "$INTERFACES_FILE" "$BACKUP"
echo "💾 Backup created → $BACKUP"

# ----------------------------- Write config ---------------------------------
# Remove any previous vmbr10 block we may have added
sed -i '/# NetBird vmbr10 Bridge - auto-generated/,+15d' "$INTERFACES_FILE" 2>/dev/null || true

cat <<EOF >> "$INTERFACES_FILE"

# NetBird vmbr10 Bridge - auto-generated $(date)
# VMs attached here share the NetBird network (same subnet)
auto $BRIDGE
iface $BRIDGE inet static
	address $IP_CIDR
	bridge-ports none
	bridge-stp off
	bridge-fd 0
	# Enable proxy ARP + forwarding so VMs in the NetBird range work
	post-up echo 1 > /proc/sys/net/ipv4/conf/\$IFACE/proxy_arp
	post-up echo 1 > /proc/sys/net/ipv4/conf/\$IFACE/proxy_arp_pvlan
	post-up echo 1 > /proc/sys/net/ipv4/ip_forward

# Keep NetBird interface without IP (prevents conflict)
auto $NETBIRD_IF
iface $NETBIRD_IF inet manual
EOF

echo "📝 Configuration added to $INTERFACES_FILE"

# ----------------------------- Apply changes --------------------------------
echo "🔄 Applying network configuration..."

# Remove IP from wt0 (NetBird keeps the tunnel alive)
ip addr flush dev "$NETBIRD_IF" scope global 2>/dev/null || true

# Reload everything
ifreload -a

# Make sure bridge is up
ip link set "$BRIDGE" up 2>/dev/null || true

echo "🎉 Success!"
echo ""
echo "   Bridge $BRIDGE now has $IP_CIDR"
echo "   Gateway for VMs: ${IP_CIDR%%/*}"
echo ""
echo "How to use in VMs / LXCs:"
echo "   • Network → Bridge: vmbr10"
echo "   • Model: VirtIO (recommended)"
echo "   • IP: static address from the same NetBird range (no conflicts!)"
echo "   • Gateway: ${IP_CIDR%%/*}"
echo ""
echo "💡 Tip: If you want full bidirectional access from other NetBird peers"
echo "   to your VMs, set the host as a subnet router in the NetBird dashboard"
echo "   (advertise the VM subnet) or run NetBird client inside each VM."
echo ""
echo "Re-run this script after a NetBird restart if the IP moves back to wt0."
echo "Original backup: $BACKUP"
