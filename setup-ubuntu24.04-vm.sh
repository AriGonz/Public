#!/usr/bin/env bash
# =============================================================================
# Ubuntu 24.04 Post-Install Script – Clean & Secure Base
# =============================================================================
# Follows strict project standard for Ubuntu 24.04 VMs
# Main user: itadmin (non-root)
# Idempotent – safe to re-run
# Usage: bash -c "$(curl -fsSL https://raw.githubusercontent.com/AriGonz/Public/refs/heads/main/setup-ubuntu24.04-vm.sh)"
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

# ─── Select Sections ─────────────────────────────────────────────────────────
echo "Please select which sections to run by placing an 'X' in the brackets for yes (e.g., [X]), or leave [ ] for no."
echo "Copy the following template, edit it in your text editor or mentally, and paste the edited version back here."
echo "After pasting all lines, press Enter on an empty line to proceed."
echo ""

cat << EOF
1. System Update & Upgrade [ ]
2. Install Essential Tools [ ]
3. Harden SSH & Add Authorized Keys [ ]
4. Set Timezone [ ]
5. Enable Time Synchronization [ ]
6. Basic Firewall (ufw) [ ]
EOF

echo ""
echo "Paste your edited selections now (end with an empty line):"

declare -A RUN_SECTION
while read -r line; do
    if [[ -z "$line" ]]; then
        break
    fi
    # Parse line: expect format like "1. Some title [X]" or "[ ]"
    if [[ $line =~ ^([1-6])\.[[:space:]]+.*\[[[:space:]]*(X|x)[[:space:]]*\]$ ]]; then
        section_num="${BASH_REMATCH[1]}"
        RUN_SECTION[$section_num]="yes"
    elif [[ $line =~ ^([1-6])\.[[:space:]]+.*\[[[:space:]]*\]$ ]]; then
        # Explicit [ ] means no, but since we default to no, optional
        :
    else
        warning "Invalid line: $line – skipping"
    fi
done

# If no sections selected, warn
if [[ ${#RUN_SECTION[@]} -eq 0 ]]; then
    warning "No sections selected – exiting"
    exit 0
fi

# ──────────────────────────────────────────────────────────────────────────────
# 1. System Update & Upgrade
# ──────────────────────────────────────────────────────────────────────────────
if [[ "${RUN_SECTION[1]}" == "yes" ]]; then
    print_section "1" "System Update & Upgrade"

    apt update -qq
    apt upgrade -y
    apt dist-upgrade -y
    apt autoremove -y
    apt autoclean
    success "System packages updated"
    pause
fi

# ──────────────────────────────────────────────────────────────────────────────
# 2. Install Essential Tools
# ──────────────────────────────────────────────────────────────────────────────
if [[ "${RUN_SECTION[2]}" == "yes" ]]; then
    print_section "2" "Install Essential Tools"

    ESSENTIALS="vim nano curl"
    if ! dpkg -s openssh-server >/dev/null 2>&1; then
        ESSENTIALS="$ESSENTIALS openssh-server"
    fi

    apt install -y $ESSENTIALS
    success "Essential tools installed"
    pause
fi

# ──────────────────────────────────────────────────────────────────────────────
# 3. Harden SSH & Add Authorized Keys
# ──────────────────────────────────────────────────────────────────────────────
if [[ "${RUN_SECTION[3]}" == "yes" ]]; then
    print_section "3" "Harden SSH & Add Authorized Keys"

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
fi

# ──────────────────────────────────────────────────────────────────────────────
# 4. Set Timezone
# ──────────────────────────────────────────────────────────────────────────────
if [[ "${RUN_SECTION[4]}" == "yes" ]]; then
    print_section "4" "Set Timezone to US/Central"

    timedatectl set-timezone "$TIMEZONE" || true
    timedatectl
    success "Timezone set to $TIMEZONE"
    pause
fi

# ──────────────────────────────────────────────────────────────────────────────
# 5. Enable Time Synchronization
# ──────────────────────────────────────────────────────────────────────────────
if [[ "${RUN_SECTION[5]}" == "yes" ]]; then
    print_section "5" "Enable Time Synchronization"

    # Ubuntu: systemd-timesyncd
    timedatectl set-ntp true 2>/dev/null || true
    success "systemd-timesyncd enabled"
    pause
fi

# ──────────────────────────────────────────────────────────────────────────────
# 6. Basic Firewall (ufw)
# ──────────────────────────────────────────────────────────────────────────────
if [[ "${RUN_SECTION[6]}" == "yes" ]]; then
    print_section "6" "Enable Basic Firewall"

    if command -v ufw >/dev/null 2>&1; then
        ufw allow OpenSSH 2>/dev/null || true
        echo "y" | ufw --force enable 2>/dev/null || true
        if ufw status | grep -q "Status: active"; then
            success "UFW enabled and OpenSSH allowed"
        else
            warning "UFW enable failed – check manually"
        fi
    else
        apt install -y ufw
        ufw allow OpenSSH 2>/dev/null || true
        echo "y" | ufw --force enable 2>/dev/null || true
        if ufw status | grep -q "Status: active"; then
            success "UFW installed, enabled, and OpenSSH allowed"
        else
            warning "UFW enable failed – check manually"
        fi
    fi
    pause
fi

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
echo "  • Reboot if needed:      reboot"
echo ""
