#!/bin/bash

# Usage: bash -c "$(curl -fsSL https://raw.githubusercontent.com/AriGonz/Public/refs/heads/main/install_netbird.sh)"



# Update package list
apt-get update

# Install required packages
apt install ca-certificates curl gnupg -y

# Add NetBird GPG key
curl -sSL https://pkgs.netbird.io/debian/public.key | gpg --dearmor --output /usr/share/keyrings/netbird-archive-keyring.gpg

# Add NetBird repository
echo 'deb [signed-by=/usr/share/keyrings/netbird-archive-keyring.gpg] https://pkgs.netbird.io/debian stable main' | tee /etc/apt/sources.list.d/netbird.list

# Install NetBird
apt-get install netbird

# Install NetBird UI
apt-get install netbird-ui

ECHO. 
ECHO. 
# Start NetBird with custom management URL
netbird up --management-url https://netbird.arigonz.com
