#!/bin/bash

# Script to switch Proxmox network from static IP to DHCP (dynamic).
# WARNING: This may change your IP and break current connections. Set up Cloudflare Tunnel first!
# Assumes interface is vmbr0; adjust if needed.
# bash -c "$(curl -fsSL https://raw.githubusercontent.com/AriGonz/Public/refs/heads/main/pve-static-to-dhcp.sh)"

INTERFACE="vmbr0"
CONFIG_FILE="/etc/network/interfaces"

# Backup original config
cp "$CONFIG_FILE" "$CONFIG_FILE.backup.$(date +%Y%m%d_%H%M%S)"
echo "Backup created: $CONFIG_FILE.backup"

# Modify config: Replace 'inet static' with 'inet dhcp', remove address/gateway lines
sed -i "/iface $INTERFACE inet static/c\iface $INTERFACE inet dhcp" "$CONFIG_FILE"
sed -i "/address /d" "$CONFIG_FILE"
sed -i "/gateway /d" "$CONFIG_FILE"
sed -i "/netmask /d" "$CONFIG_FILE"  # Optional, if present

# Apply changes (this may drop your connection)
echo "Applying changes... Your connection may drop if IP changes."
ifdown "$INTERFACE" && ifup "$INTERFACE"

# If the above fails, reboot: systemctl reboot
echo "If interface doesn't come up, reboot the node and access via Cloudflare Tunnel."
echo "Done. Check new IP with 'ip addr show $INTERFACE' after reconnecting."
