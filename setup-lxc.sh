#!/usr/bin/env bash

# =============================================================================
#  Proxmox LXC initial setup script
#  - Safe package update/upgrade
#  - Installs essential tools if missing
#  - Easy to extend
# Usage:   bash -c "$(curl -fsSL https://raw.githubusercontent.com/AriGonz/Public/refs/heads/main/setup-lxc.sh)"
# =============================================================================

set -euo pipefail

# ──────────────────────────────────────────────────────────────────────────────
#  Configuration - add your packages here
# ──────────────────────────────────────────────────────────────────────────────

ESSENTIAL_PACKAGES=(
    curl
    gpg          # provides gpg command
    # Add more packages below, one per line
    # wget
    # git
    # vim
    # htop
    # net-tools
    # jq
    # unzip
)

# ──────────────────────────────────────────────────────────────────────────────
#  Functions
# ──────────────────────────────────────────────────────────────────────────────

update_and_upgrade() {
    echo "→ Updating package lists..."
    apt-get update -yqq

    echo "→ Upgrading installed packages..."
    # DEBIAN_FRONTEND=noninteractive → no interactive prompts
    DEBIAN_FRONTEND=noninteractive \
        apt-get upgrade -y \
        --no-install-recommends \
        --fix-missing

    echo "→ Performing distribution upgrade (if needed)..."
    DEBIAN_FRONTEND=noninteractive \
        apt-get dist-upgrade -y \
        --no-install-recommends

    echo "→ Cleaning up..."
    apt-get autoremove -yqq
    apt-get autoclean -yqq
}

install_if_missing() {
    local pkg="$1"

    if dpkg -s "$pkg" >/dev/null 2>&1; then
        echo "✓ $pkg is already installed"
        return 0
    fi

    echo "→ Installing $pkg ..."
    DEBIAN_FRONTEND=noninteractive \
        apt-get install -y --no-install-recommends "$pkg"
}

# ──────────────────────────────────────────────────────────────────────────────
#  Main
# ──────────────────────────────────────────────────────────────────────────────

echo "============================================================="
echo "  Proxmox LXC - Initial Setup"
echo "============================================================="

# Make sure we are root
if [[ $EUID -ne 0 ]]; then
    echo "ERROR: This script must be run as root" >&2
    exit 1
fi

# 1. Full system update + upgrade
update_and_upgrade

# 2. Install missing essential packages
echo -e "\n→ Installing essential tools...\n"

for pkg in "${ESSENTIAL_PACKAGES[@]}"; do
    install_if_missing "$pkg"
done

echo -e "\n→ Setup completed!\n"

echo "Installed packages:"
for pkg in "${ESSENTIAL_PACKAGES[@]}"; do
    if dpkg -s "$pkg" >/dev/null 2>&1; then
        echo "  • $pkg"
    fi
done

echo -e "\nYou can now safely add more packages to the ESSENTIAL_PACKAGES array.\n"
