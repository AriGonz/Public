#!/usr/bin/env bash
# =============================================================================
# Proxmox Guest Post-Install Script – Clean & Secure Base (Ubuntu 24.04 / Debian 12)
# =============================================================================
# Follows strict project standard for Proxmox VE 9.1.1 guests
# Main user: itadmin (non-root)
# Idempotent – safe to re-run
# Usage: bash -c "$(curl -fsSL https://raw.githubusercontent.com/AriGonz/Public/refs/heads/main/proxmox-vm.sh)"
# =============================================================================

set -euo pipefail

# ──── Colors (if terminal supports them) ─────────────────────────────────────
if [[ -t 1 ]]; then
    RED=$(tput setaf 1)
    GREEN=$(tput setaf 2)
    YELLOW=$(tput setaf 3)
    BLUE=$(tput setaf 4)
    RESET=$(tput sgr0)
else
    RED="" GREEN="" YELLOW="" BLUE="" RESET=""
fi

# ─── Configuration ───────────────────────────────────────────────────────────
TIMEZONE="America/Chicago"

AUTHORIZED_KEYS=(
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAx0vHaUQfDPrVPLt8GhC8aCwRDVAZWa8wGL9/aPb7dQ eddsa-key-20260205"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDwF69AFzU724Y+F875vRApoudqQkuOhVZti65kyfNzK eddsa-key-20260205"
)

MAIN_USER="itadmin"
SSH_HOME="/home/$MAIN_USER"
SSH_DIR="$SSH_HOME/.ssh"
AUTHORIZED_KEYS_FILE="$SSH_DIR/authorized_keys"

# ─── Helper Functions ────────────────────────────────────────────────────────
print_section() {
    local number="$1"
    local title="$2"
    echo ""
    echo "# ──────────────────────────────────────────────────────────────────────────────"
    echo "# $number. $title"
    echo "# ──────────────────────────────────────────────────────────────────────────────"
    echo ""
}

success() {
    echo -e "${GREEN}→ $1${RESET}"
}

warning() {
    echo -e "${YELLOW}Warning: $1${RESET}"
}

pause() {
    sleep 1
}

# ──────────────────────────────────────────────────────────────────────────────
# 1. System Update & Upgrade
# ──────────────────────────────────────────────────────────────────────────────
print_section "1" "System Update & Upgrade"

apt update -qq
apt upgrade -y
apt dist-upgrade -y
apt autoremove -y
apt autoclean
success "System packages updated"
pause

# ──────────────────────────────────────────────────────────────────────────────
# 2. Install Essential Tools
# ──────────────────────────────────────────────────────────────────────────────
print_section "2" "Install Essential Tools"

ESSENTIALS="vim nano curl"
if ! dpkg -s openssh-server >/dev/null 2>&1; then
    ESSENTIALS="$ESSENTIALS openssh-server"
fi
if ! dpkg -s qemu-guest-agent >/dev/null 2>&1; then
    ESSENTIALS="$ESSENTIALS qemu-guest-agent"
fi

apt install -y $ESSENTIALS
success "Essential tools installed"
pause

# ──────────────────────────────────────────────────────────────────────────────
# 3. Enable QEMU Guest Agent
# ──────────────────────────────────────────────────────────────────────────────
print_section "3" "Enable QEMU Guest Agent"

systemctl enable --now qemu-guest-agent 2>/dev/null || true
if systemctl is-active --quiet qemu-guest-agent; then
    success "QEMU Guest Agent is active"
else
    warning "QEMU Guest Agent failed to start (check logs if needed)"
fi
pause

# ──────────────────────────────────────────────────────────────────────────────
# 4. Harden SSH & Add Authorized Keys
# ──────────────────────────────────────────────────────────────────────────────
print_section "4" "Harden SSH & Add Authorized Keys"

# Create .ssh directory for itadmin
if [[ ! -d "$SSH_DIR" ]]; then
    mkdir -p "$SSH_DIR"
    chown "$MAIN_USER":"$MAIN_USER" "$SSH_DIR"
    chmod 700 "$SSH_DIR"
    success "Created .ssh directory for $MAIN_USER"
fi

# Add public keys (idempotent)
touch "$AUTHORIZED_KEYS_FILE"
chown "$MAIN_USER":"$MAIN_USER" "$AUTHORIZED_KEYS_FILE"
chmod 600 "$AUTHORIZED_KEYS_FILE"

for key in "${AUTHORIZED_KEYS[@]}"; do
    if ! grep -qF -- "$key" "$AUTHORIZED_KEYS_FILE"; then
        echo "$key" >> "$AUTHORIZED_KEYS_FILE"
        echo -e "${GREEN}→ Added SSH key:${RESET} ${key:0:50}..."
    fi
done

# Harden sshd_config
SSHD_CONFIG="/etc/ssh/sshd_config"
[[ ! -f "${SSHD_CONFIG}.bak" ]] && cp "$SSHD_CONFIG" "${SSHD_CONFIG}.bak"

sed -i 's/^#*PermitRootLogin.*/PermitRootLogin prohibit-password/' "$SSHD_CONFIG"
sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/'   "$SSHD_CONFIG"
sed -i 's/^#*PubkeyAuthentication.*/PubkeyAuthentication yes/'      "$SSHD_CONFIG"
sed -i 's/^#*ChallengeResponseAuthentication.*/ChallengeResponseAuthentication no/' "$SSHD_CONFIG"

# Ensure settings exist
grep -q "^PermitRootLogin" "$SSHD_CONFIG" || echo "PermitRootLogin prohibit-password" >> "$SSHD_CONFIG"
grep -q "^PasswordAuthentication" "$SSHD_CONFIG" || echo "PasswordAuthentication no" >> "$SSHD_CONFIG"
grep -q "^PubkeyAuthentication" "$SSHD_CONFIG" || echo "PubkeyAuthentication yes" >> "$SSHD_CONFIG"
grep -q "^ChallengeResponseAuthentication" "$SSHD_CONFIG" || echo "ChallengeResponseAuthentication no" >> "$SSHD_CONFIG"

systemctl restart ssh || systemctl restart sshd
success "SSH hardened (password login disabled, pubkey only)"
pause

# ──────────────────────────────────────────────────────────────────────────────
# 5. Set Timezone
# ──────────────────────────────────────────────────────────────────────────────
print_section "5" "Set Timezone to US/Central"

timedatectl set-timezone "$TIMEZONE" || true
timedatectl
success "Timezone set to $TIMEZONE"
pause

# ──────────────────────────────────────────────────────────────────────────────
# 6. Enable Time Synchronization
# ──────────────────────────────────────────────────────────────────────────────
print_section "6" "Enable Time Synchronization"

if grep -q '^ID=debian' /etc/os-release 2>/dev/null; then
    # Debian preference: chrony
    if ! command -v chronyd >/dev/null 2>&1; then
        apt install -y chrony
    fi
    systemctl enable --now chrony 2>/dev/null || true
    success "chrony enabled (Debian)"
else
    # Ubuntu: systemd-timesyncd
    timedatectl set-ntp true 2>/dev/null || true
    success "systemd-timesyncd enabled (Ubuntu)"
fi
pause

# ──────────────────────────────────────────────────────────────────────────────
# 7. Basic Firewall (Ubuntu: ufw)
# ──────────────────────────────────────────────────────────────────────────────
print_section "7" "Enable Basic Firewall"

if command -v ufw >/dev/null 2>&1; then
    ufw allow OpenSSH 2>/dev/null || true
    echo "y" | ufw --force enable 2>/dev/null || true
    if ufw status | grep -q "Status: active"; then
        success "UFW enabled and OpenSSH allowed"
    else
        warning "UFW enable failed – check manually"
    fi
else
    echo -e "${YELLOW}→ ufw not found (likely Debian). Skipping automatic firewall setup.${RESET}"
    echo "   You may want to configure nftables or iptables-persistent later."
fi
pause

# ──────────────────────────────────────────────────────────────────────────────
# Finish
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "# ──────────────────────────────────────────────────────────────────────────────"
echo "#               CONFIGURATION COMPLETED SUCCESSFULLY"
echo "# ──────────────────────────────────────────────────────────────────────────────"
echo ""
echo "Next recommended steps:"
echo "  • Test SSH key login:   ssh $MAIN_USER@<vm-ip>"
echo "  • If kernel was updated, consider:   sudo reboot"
echo ""
echo "Script finished."
echo ""

exit 0
