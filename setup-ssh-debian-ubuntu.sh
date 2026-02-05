#!/usr/bin/env bash
# =============================================================================
# Script: setup-ssh-debian-ubuntu-multi-keys.sh
# Purpose: Install OpenSSH server (if missing) + add multiple public keys
#          to ~/.ssh/authorized_keys on Debian/Ubuntu
# Usage:   bash -c "$(curl -fsSL https://raw.githubusercontent.com/AriGonz/Public/refs/heads/main/setup-ssh-debian-ubuntu.sh)"
# =============================================================================

set -euo pipefail

# ──────────────────────────────────────────────────────────────────────────────
# Public keys to add (add more lines as needed)
# ──────────────────────────────────────────────────────────────────────────────
declare -a PUBLIC_KEYS=(
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAx0vHaUQfDPrVPLt8GhC8aCwRDVAZWa8wGL9/aPb7dQ eddsa-key-20260205"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDwF69AFzU724Y+F875vRApoudqQkuOhVZti65kyfNzK eddsa-key-20260205"
    # Add more keys here if needed, one per line
    # "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAI... another-key comment"
)

# ──────────────────────────────────────────────────────────────────────────────
# Helper functions
# ──────────────────────────────────────────────────────────────────────────────

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

# ──────────────────────────────────────────────────────────────────────────────
# Install OpenSSH server if needed
# ──────────────────────────────────────────────────────────────────────────────

echo "→ Checking for OpenSSH server..."

if ! command_exists sshd; then
    echo "→ Installing OpenSSH server..."
    sudo apt-get update -qq
    sudo apt-get install -y openssh-server
    echo "→ Enabling and starting ssh service..."
    sudo systemctl enable --now ssh >/dev/null 2>&1 || sudo systemctl enable --now sshd >/dev/null 2>&1
    echo "→ OpenSSH server installed and started."
else
    echo "→ OpenSSH server already installed."
fi

# ──────────────────────────────────────────────────────────────────────────────
# Prepare ~/.ssh and authorized_keys
# ──────────────────────────────────────────────────────────────────────────────

SSH_DIR="$HOME/.ssh"
AUTH_FILE="$SSH_DIR/authorized_keys"

echo "→ Preparing SSH directory..."

mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"

touch "$AUTH_FILE"
chmod 600 "$AUTH_FILE"

# ──────────────────────────────────────────────────────────────────────────────
# Add each public key if not already present
# ──────────────────────────────────────────────────────────────────────────────

echo "→ Checking and adding public keys..."

added_count=0

for key in "${PUBLIC_KEYS[@]}"; do
    # Use the base64 part to detect duplicates reliably
    key_fingerprint=$(echo "$key" | awk '{print $2}')
    
    if [ -z "$key_fingerprint" ]; then
        echo "Warning: Invalid key format → $key"
        continue
    fi

    if grep -qF "$key_fingerprint" "$AUTH_FILE"; then
        echo "  Already present : ${key:0:40}..."
    else
        echo "  Adding key      : ${key:0:40}..."
        echo "$key" >> "$AUTH_FILE"
        ((added_count++))
    fi
done

if [ "$added_count" -eq 0 ]; then
    echo "→ No new keys added (all keys already present)."
else
    echo "→ Successfully added $added_count new key(s)."
fi

echo ""
echo "Setup complete!"
echo "You should now be able to connect using any of the added private keys."
echo ""
echo "Current machine IP(s):"
hostname -I
echo ""
echo "Example connection command:"
echo "  ssh -i ~/.ssh/your-private-key $(whoami)@$(hostname -I | awk '{print $1}')"
