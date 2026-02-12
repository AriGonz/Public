#!/bin/bash
# Usage: bash -c "$(curl -fsSL https://raw.githubusercontent.com/AriGonz/Public/refs/heads/main/install_netbird.sh)"
# This script installs the NetBird client on Debian-based systems.
# Run as root or with sudo.

set -e  # Exit on error

# Update package list
apt-get update

# Install required packages
apt install ca-certificates curl gnupg -y

# Add NetBird GPG key (overwrite without prompt)
curl -sSL https://pkgs.netbird.io/debian/public.key | gpg --dearmor | tee /usr/share/keyrings/netbird-archive-keyring.gpg >/dev/null

# Add NetBird repository (correct format without escaped brackets)
echo 'deb [signed-by=/usr/share/keyrings/netbird-archive-keyring.gpg] https://pkgs.netbird.io/debian stable main' | tee /etc/apt/sources.list.d/netbird.list

# Update package list again
apt-get update

# Install NetBird CLI
apt-get install netbird -y

# Install NetBird UI (optional, but included as per original)
apt-get install netbird-ui -y

# Start NetBird with custom management URL
netbird up --management-url https://netbird.arigonz.com
