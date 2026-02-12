#!/bin/bash
# Usage: bash -c "$(curl -fsSL https://raw.githubusercontent.com/AriGonz/Public/refs/heads/main/install_netbird.sh)"
# This script installs the NetBird client on Debian-based systems.
# Run as root or with sudo.

# Attempt to sync system time to resolve potential clock skew issues
if command -v timedatectl &> /dev/null; then
    timedatectl set-ntp true || true
fi

# If Proxmox enterprise repo is causing 401 errors, disable it and add no-subscription repo
if [ -f /etc/apt/sources.list.d/pve-enterprise.list ]; then
    mv /etc/apt/sources.list.d/pve-enterprise.list /etc/apt/sources.list.d/pve-enterprise.list.bak || true
    echo "deb http://download.proxmox.com/debian/pve trixie pve-no-subscription" | tee /etc/apt/sources.list.d/pve-no-subscription.list >/dev/null
fi

# Update package list (continue even if fails due to other repo issues)
apt-get update || true

# Install required packages
apt install ca-certificates curl gnupg -y || true

# Add NetBird GPG key (overwrite without prompt)
curl -sSL https://pkgs.netbird.io/debian/public.key | gpg --dearmor | tee /usr/share/keyrings/netbird-archive-keyring.gpg >/dev/null

# Add NetBird repository
echo 'deb [signed-by=/usr/share/keyrings/netbird-archive-keyring.gpg] https://pkgs.netbird.io/debian stable main' | tee /etc/apt/sources.list.d/netbird.list

# Debug: Show added repo
echo "NetBird repository added:"
cat /etc/apt/sources.list.d/netbird.list

# Update package list again (continue even if fails)
apt-get update || true

# Debug: Check if netbird package is available
apt-cache policy netbird

# Install NetBird CLI
apt-get install netbird -y

# Install NetBird UI (optional)
apt-get install netbird-ui -y

    # Start NetBird with custom management URL
    netbird up --management-url https://netbird.arigonz.com
