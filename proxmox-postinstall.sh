#!/usr/bin/env bash
# =============================================================================
# Proxmox VE 9.1.x Post-Install Hardening & Configuration Script
# =============================================================================
# Run as root on a fresh Proxmox VE installation.
#
# Usage recommendation:
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/AriGonz/Public/refs/heads/main/proxmox-postinstall.sh)"
#
# SSH keys are now fetched from:
#   https://raw.githubusercontent.com/AriGonz/Public/refs/heads/main/authorized_keys
# =============================================================================

# ──── CONFIGURATION VARIABLES ────────────────────────────────────────────────

# URL where your authorized_keys file lives (one key per line)
SSH_KEYS_URL="https://raw.githubusercontent.com/AriGonz/Public/refs/heads/main/authorized_keys"

# Repositories
PVE_NOSUBSCRIPTION_REPO="deb http://download.proxmox.com/debian/pve bookworm pve-no-subscription"
PVE_ENTERPRISE_LIST="/etc/apt/sources.list.d/pve-enterprise.list"
PVE_NOSUB_LIST="/etc/apt/sources.list.d/pve-no-subscription.list"

# Files to patch / backup
PROXMOXLIB_JS="/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js"

# SSH settings
SSH_DIR="/root/.ssh"
AUTHORIZED_KEYS="${SSH_DIR}/authorized_keys"
SSHD_CONFIG="/etc/ssh/sshd_config"

# Timeout for curl (seconds)
CURL_TIMEOUT=15

# ──── END OF CONFIGURATION ───────────────────────────────────────────────────

set -euo pipefail

# ──────────────────────────────────────────────────────────────────────────────
# Check root privileges
# ──────────────────────────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    echo "Error: This script must be run as root" >&2
    echo "       Try: sudo bash $0" >&2
    exit 1
fi

echo ""
echo "┌──────────────────────────────────────────────────────────────┐"
echo "│     Proxmox VE 9.1.x Post-Install Configuration Script       │"
echo "└──────────────────────────────────────────────────────────────┘"
echo ""

# ──────────────────────────────────────────────────────────────────────────────
# Fetch SSH public keys from remote URL
# ──────────────────────────────────────────────────────────────────────────────
echo "→ Fetching SSH public keys from:"
echo "  $SSH_KEYS_URL"

# Temporary file for downloaded keys
TMP_KEYS=$(mktemp)

if ! curl -fsSL --max-time "$CURL_TIMEOUT" -o "$TMP_KEYS" "$SSH_KEYS_URL"; then
    echo "ERROR: Failed to download keys from $SSH_KEYS_URL" >&2
    echo "       Check the URL, network, or GitHub availability." >&2
    rm -f "$TMP_KEYS"
    exit 1
fi

# Read keys into array, skipping invalid/empty/comment lines
mapfile -t PUBLIC_KEYS < "$TMP_KEYS"
rm -f "$TMP_KEYS"

valid_keys_count=0
for key in "${PUBLIC_KEYS[@]}"; do
    # Skip empty lines and comments
    [[ -z "${key// }" || "${key}" =~ ^[[:space:]]*# ]] && continue
    # Basic validation: should start with ssh-rsa, ssh-ed25519, etc.
    if [[ "$key" =~ ^ssh- ]]; then
        ((valid_keys_count++))
    else
        echo "  Warning: Skipping invalid looking line: ${key:0:50}..."
    fi
done

if [[ $valid_keys_count -eq 0 ]]; then
    echo "ERROR: No valid SSH public keys found in the downloaded file." >&2
    exit 1
fi

echo "  → Found $valid_keys_count valid key(s)"
echo ""

# ──────────────────────────────────────────────────────────────────────────────
# 1. Repository configuration
# ──────────────────────────────────────────────────────────────────────────────
echo "→ Configuring repositories..."

if [[ -f "$PVE_ENTERPRISE_LIST" ]]; then
    if ! grep -q "^# deb https://enterprise.proxmox.com/debian/pve" "$PVE_ENTERPRISE_LIST"; then
        echo "  Disabling enterprise repository..."
        sed -i 's/^deb/#deb/' "$PVE_ENTERPRISE_LIST"
    else
        echo "  Enterprise repo already disabled."
    fi
else
    echo "  Enterprise repo file not found (already removed)."
fi

if [[ ! -f "$PVE_NOSUB_LIST" ]] || ! grep -qF "$PVE_NOSUBSCRIPTION_REPO" "$PVE_NOSUB_LIST"; then
    echo "  Adding no-subscription repository..."
    echo "$PVE_NOSUBSCRIPTION_REPO" | tee "$PVE_NOSUB_LIST" >/dev/null
else
    echo "  No-subscription repo already configured."
fi

echo ""

# ──────────────────────────────────────────────────────────────────────────────
# 2. Remove subscription nag
# ──────────────────────────────────────────────────────────────────────────────
echo "→ Removing subscription nag popup..."

if [[ ! -f "$PROXMOXLIB_JS" ]]; then
    echo "  Warning: $PROXMOXLIB_JS not found — skipping patch."
else
    if grep -q "return false;" "$PROXMOXLIB_JS" && grep -q "if (res === null" "$PROXMOXLIB_JS"; then
        echo "  Subscription nag patch already applied."
    else
        BACKUP_FILE="${PROXMOXLIB_JS}.bak.$(date +%Y%m%d-%H%M%S)"
        echo "  Creating backup → $BACKUP_FILE"
        cp -v "$PROXMOXLIB_JS" "$BACKUP_FILE"

        echo "  Applying patch..."
        sed -i 's/if (res === null || res === undefined || !res || res/if (false || res === null || res === undefined || !res || res/' "$PROXMOXLIB_JS"
        echo "  Patch applied."
    fi
fi

echo ""

# ──────────────────────────────────────────────────────────────────────────────
# 3. System update & upgrade
# ──────────────────────────────────────────────────────────────────────────────
echo "→ Updating package lists and upgrading system..."

apt update -qq
echo ""
apt full-upgrade -y
echo ""

REBOOT_NEEDED=0
if [[ -f /var/run/reboot-required ]]; then
    REBOOT_NEEDED=1
    echo "  → Reboot recommended after upgrade."
fi

echo ""

# ──────────────────────────────────────────────────────────────────────────────
# 4. Add SSH public keys
# ──────────────────────────────────────────────────────────────────────────────
echo "→ Adding SSH public keys for root (from remote file)"

mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"

echo "  Processing keys (skipping duplicates)..."

added_count=0
for key in "${PUBLIC_KEYS[@]}"; do
    # Skip empty lines and comments
    [[ -z "${key// }" || "${key}" =~ ^[[:space:]]*# ]] && continue

    if ! grep -qF -- "$key" "$AUTHORIZED_KEYS" 2>/dev/null; then
        echo "$key" >> "$AUTHORIZED_KEYS"
        echo "    Added: ${key:0:50}..."
        ((added_count++))
    else
        echo "    Already present: ${key:0:50}..."
    fi
done

if [[ $added_count -eq 0 ]]; then
    echo "  All keys were already present."
else
    echo "  → $added_count new key(s) added."
fi

chmod 600 "$AUTHORIZED_KEYS"
chown root:root "$SSH_DIR" "$AUTHORIZED_KEYS"

echo ""

# ──────────────────────────────────────────────────────────────────────────────
# 5. SSH Hardening – disable password auth
# ──────────────────────────────────────────────────────────────────────────────
echo "WARNING: Next step will DISABLE password authentication over SSH."
echo "         Make sure you can log in with one of the keys from:"
echo "         $SSH_KEYS_URL"
echo ""

read -p "Disable password login? (y/N): " -r CONFIRM
echo ""

SSH_HARDENED=0

if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
    echo "→ Hardening SSH..."

    cp -v "$SSHD_CONFIG" "${SSHD_CONFIG}.bak.$(date +%Y%m%d-%H%M%S)"

    sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' "$SSHD_CONFIG"
    sed -i 's/^#*PermitEmptyPasswords.*/PermitEmptyPasswords no/'   "$SSHD_CONFIG"
    sed -i 's/^#*PubkeyAuthentication.*/PubkeyAuthentication yes/'  "$SSHD_CONFIG"

    grep -q "^PasswordAuthentication" "$SSHD_CONFIG" || echo "PasswordAuthentication no" >> "$SSHD_CONFIG"
    grep -q "^PermitEmptyPasswords"   "$SSHD_CONFIG" || echo "PermitEmptyPasswords no"   >> "$SSHD_CONFIG"
    grep -q "^PubkeyAuthentication"   "$SSHD_CONFIG" || echo "PubkeyAuthentication yes"  >> "$SSHD_CONFIG"

    echo "  → Restarting sshd..."
    if systemctl restart sshd; then
        echo "  SSH service restarted successfully."
        SSH_HARDENED=1
    else
        echo "  ERROR: Failed to restart sshd. Check $SSHD_CONFIG manually."
        exit 2
    fi
else
    echo "→ SSH hardening skipped by user."
fi

echo ""

# ──────────────────────────────────────────────────────────────────────────────
# Summary
# ──────────────────────────────────────────────────────────────────────────────
echo "┌───────────────────────────────┐"
echo "│           SUMMARY             │"
echo "└───────────────────────────────┘"
echo "• Enterprise repo disabled"
echo "• No-subscription repo enabled"
echo "• Subscription nag removed"
echo "• System updated & upgraded"
[[ $REBOOT_NEEDED -eq 1 ]] && echo "  → Reboot recommended"
echo "• SSH keys fetched from remote URL and processed"
[[ $SSH_HARDENED -eq 1 ]] && echo "• SSH hardened (password auth disabled)"
[[ $SSH_HARDENED -eq 0 ]] && echo "• SSH hardening skipped"

echo ""
echo "Done."

if [[ $REBOOT_NEEDED -eq 1 ]]; then
    echo ""
    echo "Recommended next step:"
    echo "  sudo reboot"
fi

echo ""

exit 0
