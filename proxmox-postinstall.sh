#!/usr/bin/env bash
# =============================================================================
# Proxmox VE 9.1.x Post-Install Hardening & Configuration Script
# =============================================================================
# Run as root on a fresh Proxmox VE installation.
#
# Usage: bash -c "$(curl -fsSL https://raw.githubusercontent.com/.../proxmox-postinstall.sh)"
# =============================================================================

set -euo pipefail

# ──── CONFIGURATION VARIABLES ────────────────────────────────────────────────
PUBLIC_KEYS=(
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAx0vHaUQfDPrVPLt8GhC8aCwRDVAZWa8wGL9/aPb7dQ eddsa-key-20260205"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDwF69AFzU724Y+F875vRApoudqQkuOhVZti65kyfNzK eddsa-key-20260205"
    # Add more keys here if needed
)

PVE_NOSUBSCRIPTION_REPO="deb http://download.proxmox.com/debian/pve bookworm pve-no-subscription"
PVE_ENTERPRISE_LIST="/etc/apt/sources.list.d/pve-enterprise.list"
PVE_NOSUB_LIST="/etc/apt/sources.list.d/pve-no-subscription.list"

PROXMOXLIB_JS="/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js"

SSH_DIR="/root/.ssh"
AUTHORIZED_KEYS="${SSH_DIR}/authorized_keys"
SSHD_CONFIG="/etc/ssh/sshd_config"

# ──── END OF CONFIGURATION ───────────────────────────────────────────────────

# ──────────────────────────────────────────────────────────────────────────────
# 0. Initial checks & required tools installation
# ──────────────────────────────────────────────────────────────────────────────
clear
echo "┌──────────────────────────────────────────────────────────────┐"
echo "│   Proxmox VE 9.1.x Post-Install Configuration Script    │"
echo "└──────────────────────────────────────────────────────────────┘"
echo ""

echo "→ Checking and installing basic required tools..."
sleep 1

PACKAGES_TO_INSTALL=""
command -v lsb_release >/dev/null 2>&1 || PACKAGES_TO_INSTALL="$PACKAGES_TO_INSTALL lsb-release"
command -v curl       >/dev/null 2>&1 || PACKAGES_TO_INSTALL="$PACKAGES_TO_INSTALL curl"
command -v nano       >/dev/null 2>&1 || PACKAGES_TO_INSTALL="$PACKAGES_TO_INSTALL nano"
command -v vim        >/dev/null 2>&1 || PACKAGES_TO_INSTALL="$PACKAGES_TO_INSTALL vim"

if [[ -n "$PACKAGES_TO_INSTALL" ]]; then
    echo " Installing missing packages: $PACKAGES_TO_INSTALL"
    apt update -qq
    apt install -y $PACKAGES_TO_INSTALL
    echo " Basic tools installed."
else
    echo " All required tools already installed."
fi

echo ""
sleep 1

# ──────────────────────────────────────────────────────────────────────────────
# Check root privileges
# ──────────────────────────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    echo "Error: This script must be run as root" >&2
    echo " Try: sudo bash $0" >&2
    exit 1
fi

# ──────────────────────────────────────────────────────────────────────────────
# 1. Repository configuration
# ──────────────────────────────────────────────────────────────────────────────
echo "┌─────────────────────────────┐"
echo "│ 1. Configuring Repositories │"
echo "└─────────────────────────────┘"
echo ""
sleep 1

if [[ -f "$PVE_ENTERPRISE_LIST" ]]; then
    if ! grep -q "^# deb https://enterprise.proxmox.com/debian/pve" "$PVE_ENTERPRISE_LIST"; then
        echo " Disabling enterprise repository..."
        sed -i 's/^deb/#deb/' "$PVE_ENTERPRISE_LIST"
    else
        echo " Enterprise repo already disabled."
    fi
else
    echo " Enterprise repo file not found (already removed)."
fi

if [[ ! -f "$PVE_NOSUB_LIST" ]] || ! grep -qF "$PVE_NOSUBSCRIPTION_REPO" "$PVE_NOSUB_LIST"; then
    echo " Adding no-subscription repository..."
    echo "$PVE_NOSUBSCRIPTION_REPO" | tee "$PVE_NOSUB_LIST" >/dev/null
else
    echo " No-subscription repo already configured."
fi

echo ""
sleep 1

# ──────────────────────────────────────────────────────────────────────────────
# 2. Remove subscription nag
# ──────────────────────────────────────────────────────────────────────────────
echo "┌─────────────────────────────┐"
echo "│ 2. Removing Subscription Nag│"
echo "└─────────────────────────────┘"
echo ""
sleep 1

if [[ ! -f "$PROXMOXLIB_JS" ]]; then
    echo " Warning: $PROXMOXLIB_JS not found — skipping patch."
else
    if grep -q "return false;" "$PROXMOXLIB_JS" && grep -q "if (res === null" "$PROXMOXLIB_JS"; then
        echo " Subscription nag patch already applied."
    else
        BACKUP_FILE="${PROXMOXLIB_JS}.bak.$(date +%Y%m%d-%H%M%S)"
        echo " Creating backup → $BACKUP_FILE"
        cp -v "$PROXMOXLIB_JS" "$BACKUP_FILE"
        echo " Applying patch..."
        sed -i 's/if (res === null || res === undefined || !res || res/if (false || res === null || res === undefined || !res || res/' "$PROXMOXLIB_JS"
        echo " Patch applied."
    fi
fi

echo ""
sleep 1

# ──────────────────────────────────────────────────────────────────────────────
# 3. System update & upgrade
# ──────────────────────────────────────────────────────────────────────────────
echo "┌─────────────────────────────┐"
echo "│ 3. System Update & Upgrade  │"
echo "└─────────────────────────────┘"
echo ""
sleep 1

echo " Updating package lists..."
apt update -qq
echo ""
echo " Performing full upgrade..."
apt full-upgrade -y
echo ""

REBOOT_NEEDED=0
if [[ -f /var/run/reboot-required ]]; then
    REBOOT_NEEDED=1
    echo " → Reboot recommended after upgrade."
fi

echo ""
sleep 1

# ──────────────────────────────────────────────────────────────────────────────
# 4. Add SSH public keys
# ──────────────────────────────────────────────────────────────────────────────
echo "┌─────────────────────────────┐"
echo "│ 4. Adding SSH Public Keys   │"
echo "└─────────────────────────────┘"
echo ""
sleep 1

mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"

added_count=0
for key in "${PUBLIC_KEYS[@]}"; do
    [[ -z "$key" || "$key" =~ ^[[:space:]]*# ]] && continue
    if ! grep -qF -- "$key" "$AUTHORIZED_KEYS" 2>/dev/null; then
        echo "$key" >> "$AUTHORIZED_KEYS"
        echo " Added: ${key:0:50}..."
        ((added_count++))
    else
        echo " Already present: ${key:0:50}..."
    fi
done

if [[ $added_count -eq 0 ]]; then
    echo " All keys were already present."
else
    echo " → $added_count new key(s) added."
fi

chmod 600 "$AUTHORIZED_KEYS"
chown root:root "$SSH_DIR" "$AUTHORIZED_KEYS"

# Check if we have at least one valid SSH key now
SSH_KEYS_PRESENT=0
if [[ -f "$AUTHORIZED_KEYS" ]] && [[ -s "$AUTHORIZED_KEYS" ]]; then
    # Very basic check: file is not empty and contains at least one line starting with ssh-
    if grep -qE "^ssh-(rsa|ed25519|ecdsa)" "$AUTHORIZED_KEYS"; then
        SSH_KEYS_PRESENT=1
        echo " → At least one SSH public key is present in authorized_keys."
    else
        echo " Warning: authorized_keys exists but contains no valid SSH public keys."
    fi
else
    echo " Warning: No SSH public keys were added or found."
fi

echo ""
sleep 1

# ──────────────────────────────────────────────────────────────────────────────
# 5. SSH Hardening – only if keys are present
# ──────────────────────────────────────────────────────────────────────────────
echo "┌─────────────────────────────┐"
echo "│ 5. SSH Hardening            │"
echo "└─────────────────────────────┘"
echo ""

SSH_HARDENED=0

if [[ $SSH_KEYS_PRESENT -eq 1 ]]; then
    echo "WARNING: This will DISABLE password authentication over SSH."
    echo " You have at least one public key configured — proceeding is safer."
    echo ""

    read -p "Disable password login? (y/N): " -r CONFIRM
    echo ""

    if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
        echo "→ Hardening SSH..."
        cp -v "$SSHD_CONFIG" "${SSHD_CONFIG}.bak.$(date +%Y%m%d-%H%M%S)"

        sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' "$SSHD_CONFIG"
        sed -i 's/^#*PermitEmptyPasswords.*/PermitEmptyPasswords no/' "$SSHD_CONFIG"
        sed -i 's/^#*PubkeyAuthentication.*/PubkeyAuthentication yes/' "$SSHD_CONFIG"

        grep -q "^PasswordAuthentication" "$SSHD_CONFIG" || echo "PasswordAuthentication no" >> "$SSHD_CONFIG"
        grep -q "^PermitEmptyPasswords" "$SSHD_CONFIG" || echo "PermitEmptyPasswords no" >> "$SSHD_CONFIG"
        grep -q "^PubkeyAuthentication" "$SSHD_CONFIG" || echo "PubkeyAuthentication yes" >> "$SSHD_CONFIG"

        echo " → Restarting sshd..."
        if systemctl restart sshd; then
            echo " SSH service restarted successfully."
            SSH_HARDENED=1
        else
            echo " ERROR: Failed to restart sshd. Check $SSHD_CONFIG manually."
            exit 2
        fi
    else
        echo "→ SSH hardening skipped by user."
    fi
else
    echo " Skipping SSH hardening — no valid SSH public keys are configured."
    echo " Password authentication remains enabled to avoid locking yourself out."
    echo " Add keys manually and re-run this script or harden SSH yourself."
fi

echo ""
sleep 1

# ──────────────────────────────────────────────────────────────────────────────
# Summary
# ──────────────────────────────────────────────────────────────────────────────
echo "┌───────────────────────────────┐"
echo "│           SUMMARY             │"
echo "└───────────────────────────────┘"
echo ""

echo "• Basic tools (lsb-release, curl, nano, vim) checked/installed"
echo "• Enterprise repo disabled"
echo "• No-subscription repo enabled"
echo "• Subscription nag removed"
echo "• System updated & upgraded"
[[ $REBOOT_NEEDED -eq 1 ]] && echo " → Reboot recommended"
echo "• SSH keys processed (${#PUBLIC_KEYS[@]} configured)"
[[ $SSH_KEYS_PRESENT -eq 1 ]] && echo "• Valid SSH key(s) detected in authorized_keys"
[[ $SSH_KEYS_PRESENT -eq 0 ]] && echo "• No valid SSH public keys found — hardening skipped"
[[ $SSH_HARDENED -eq 1 ]] && echo "• SSH hardened (password auth disabled)"
[[ $SSH_HARDENED -eq 0 && $SSH_KEYS_PRESENT -eq 1 ]] && echo "• SSH hardening skipped by user"

echo ""
echo "Done."
if [[ $REBOOT_NEEDED -eq 1 ]]; then
    echo ""
    echo "Recommended next step:"
    echo " sudo reboot"
fi
echo ""

sleep 2
exit 0
