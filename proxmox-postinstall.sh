#!/usr/bin/env bash
# =============================================================================
# Proxmox VE 9.1.x Post-Install Configuration Script – Enhanced Visibility
# =============================================================================
# Features:
#   - Very clear step-by-step output with progress indicators
#   - Aliases added FIRST so they're available even if script is interrupted
#   - Skips already-done actions when safe
#   - Confirmation before SSH hardening
#
# Recommended run command:
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/AriGonz/Public/refs/heads/main/proxmox-postinstall.sh)"
# =============================================================================

set -euo pipefail

# ──────────────────────────────────────────────────────────────────────────────
# CONFIGURATION
# ──────────────────────────────────────────────────────────────────────────────

SSH_KEYS_URL="https://raw.githubusercontent.com/AriGonz/Public/refs/heads/main/authorized_keys"
PVE_NOSUBSCRIPTION_REPO="deb http://download.proxmox.com/debian/pve bookworm pve-no-subscription"

PVE_ENTERPRISE_LIST="/etc/apt/sources.list.d/pve-enterprise.list"
PVE_NOSUB_LIST="/etc/apt/sources.list.d/pve-no-subscription.list"
PROXMOXLIB_JS="/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js"

SSH_DIR="/root/.ssh"
AUTHORIZED_KEYS="${SSH_DIR}/authorized_keys"
SSHD_CONFIG="/etc/ssh/sshd_config"

BASHRC="/root/.bashrc"

CURL_TIMEOUT=15

# ──────────────────────────────────────────────────────────────────────────────
# HELPER FUNCTIONS
# ──────────────────────────────────────────────────────────────────────────────

print_header() {
    echo ""
    echo "┌──────────────────────────────────────────────────────────────┐"
    echo "│   Proxmox VE 9.1.x – Post-Install Configuration (Enhanced)   │"
    echo "└──────────────────────────────────────────────────────────────┘"
    echo ""
}

print_step() {
    echo "→ $1"
}

print_substep() {
    echo "  • $1"
}

print_success() {
    echo "  ✓ $1"
}

print_skip() {
    echo "  (already done) $1"
}

print_warning() {
    echo "  ⚠  $1"
}

print_error() {
    echo "  ✗ ERROR: $1" >&2
}

# ──────────────────────────────────────────────────────────────────────────────
# START
# ──────────────────────────────────────────────────────────────────────────────

if [[ $EUID -ne 0 ]]; then
    print_error "This script must be run as root"
    echo "       Try: sudo bash $0"
    exit 1
fi

print_header

# ──────────────────────────────────────────────────────────────────────────────
# 1. Add useful shell aliases (moved to first position)
# ──────────────────────────────────────────────────────────────────────────────

print_step "Adding useful shell aliases to /root/.bashrc (step 1)"

ALIAS_MARKER="# --- Proxmox Post-Install Aliases (added $(date +%Y-%m-%d)) ---"

if grep -qF "$ALIAS_MARKER" "$BASHRC" 2>/dev/null; then
    print_skip "Aliases already present"
else
    print_substep "Appending aliases block..."

    cat << 'EOF' >> "$BASHRC"

# --- Proxmox Post-Install Aliases (added $(date +%Y-%m-%d)) ---
alias ll='ls -lrt'               # Long listing, sorted by modification time (newest last)
alias la='ls -A'                 # Show almost all files (including hidden)
alias l='ls -CF'                 # Classic ls with file type indicators
alias cls='clear && ls -lrt'     # Clear screen + recent files first
alias dfh='df -h'                # Human-readable disk usage
alias duh='du -sh * | sort -hr'  # Summarize dir sizes, sorted by size (largest first)
alias aptu='apt update && apt list --upgradable'   # Quick check for updates
alias aptup='apt update && apt full-upgrade -y'    # Full system upgrade
alias j='journalctl -xe --no-pager'                # Last journal errors
alias pvev='pveversion -v'                         # Show Proxmox version details
# Add your own aliases below this line if needed
EOF

    print_success "Aliases added"
    print_substep "To use them immediately, run: source /root/.bashrc"
fi

echo ""

# ──────────────────────────────────────────────────────────────────────────────
# 2. Fetch SSH public keys
# ──────────────────────────────────────────────────────────────────────────────

print_step "Fetching your SSH public keys"
echo "  From: $SSH_KEYS_URL"

TMP_KEYS=$(mktemp)

if curl -fsSL --max-time "$CURL_TIMEOUT" -o "$TMP_KEYS" "$SSH_KEYS_URL"; then
    print_success "Keys downloaded successfully"
else
    print_error "Failed to download keys from $SSH_KEYS_URL"
    rm -f "$TMP_KEYS"
    exit 1
fi

mapfile -t PUBLIC_KEYS < "$TMP_KEYS"
rm -f "$TMP_KEYS"

valid_keys=()
for key in "${PUBLIC_KEYS[@]}"; do
    key="${key#"${key%%[![:space:]]*}"}"   # trim leading whitespace
    [[ -z "$key" || "$key" =~ ^# ]] && continue
    if [[ "$key" =~ ^ssh- ]]; then
        valid_keys+=("$key")
    else
        print_warning "Skipping invalid line: ${key:0:60}..."
    fi
done

if [[ ${#valid_keys[@]} -eq 0 ]]; then
    print_error "No valid SSH public keys found"
    exit 1
fi

print_success "Found ${#valid_keys[@]} valid public key(s)"
echo ""

# ──────────────────────────────────────────────────────────────────────────────
# 3. Repositories
# ──────────────────────────────────────────────────────────────────────────────

print_step "Configuring APT repositories"

if [[ -f "$PVE_ENTERPRISE_LIST" ]]; then
    if grep -q "^deb https://enterprise.proxmox.com" "$PVE_ENTERPRISE_LIST"; then
        print_substep "Disabling enterprise repository..."
        sed -i 's/^deb /#deb /' "$PVE_ENTERPRISE_LIST"
        print_success "Enterprise repo commented out"
    else
        print_skip "Enterprise repo already disabled"
    fi
else
    print_skip "Enterprise repo file not present"
fi

if [[ ! -f "$PVE_NOSUB_LIST" ]] || ! grep -qF "$PVE_NOSUBSCRIPTION_REPO" "$PVE_NOSUB_LIST"; then
    print_substep "Adding no-subscription repository..."
    echo "$PVE_NOSUBSCRIPTION_REPO" | tee "$PVE_NOSUB_LIST" >/dev/null
    print_success "No-subscription repo added"
else
    print_skip "No-subscription repo already configured"
fi

echo ""

# ──────────────────────────────────────────────────────────────────────────────
# 4. Remove subscription nag
# ──────────────────────────────────────────────────────────────────────────────

print_step "Removing subscription nag popup (web UI)"

if [[ ! -f "$PROXMOXLIB_JS" ]]; then
    print_warning "proxmoxlib.js not found — skipping"
else
    if grep -q "return false;" "$PROXMOXLIB_JS" && grep -q "if (false" "$PROXMOXLIB_JS"; then
        print_skip "Nag patch already applied"
    else
        BACKUP="${PROXMOXLIB_JS}.bak.$(date +%Y%m%d-%H%M%S)"
        print_substep "Backing up → $BACKUP"
        cp -v "$PROXMOXLIB_JS" "$BACKUP"

        print_substep "Applying patch..."
        sed -i 's/if (res === null || res === undefined || !res || res/if (false || res === null || res === undefined || !res || res/' "$PROXMOXLIB_JS"
        print_success "Subscription nag removed"
    fi
fi

echo ""

# ──────────────────────────────────────────────────────────────────────────────
# 5. System update & upgrade
# ──────────────────────────────────────────────────────────────────────────────

print_step "Updating package lists"
apt update -qq
print_success "Package lists updated"

print_step "Upgrading installed packages (may take several minutes)"
apt full-upgrade -y
print_success "System upgrade completed"

REBOOT_NEEDED=0
[[ -f /var/run/reboot-required ]] && REBOOT_NEEDED=1

if [[ $REBOOT_NEEDED -eq 1 ]]; then
    print_warning "A reboot is recommended after this upgrade"
fi
echo ""

# ──────────────────────────────────────────────────────────────────────────────
# 6. Add SSH keys
# ──────────────────────────────────────────────────────────────────────────────

print_step "Adding SSH public keys to root account"

mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"

touch "$AUTHORIZED_KEYS"
chmod 600 "$AUTHORIZED_KEYS"

added=0
for key in "${valid_keys[@]}"; do
    if grep -qF -- "$key" "$AUTHORIZED_KEYS" 2>/dev/null; then
        print_substep "Key already present: ${key:0:50}..."
    else
        echo "$key" >> "$AUTHORIZED_KEYS"
        print_substep "Added new key: ${key:0:50}..."
        ((added++))
    fi
done

if [[ $added -gt 0 ]]; then
    print_success "$added new key(s) added"
else
    print_success "All keys were already present"
fi

chown root:root "$SSH_DIR" "$AUTHORIZED_KEYS"
echo ""

# ──────────────────────────────────────────────────────────────────────────────
# 7. SSH Hardening (optional)
# ──────────────────────────────────────────────────────────────────────────────

print_step "SSH security hardening"
echo "  WARNING: This will disable password login over SSH."
echo "           Make sure your key works before confirming!"
echo ""

read -p "  Disable password authentication? (y/N): " -r CONFIRM
echo ""

SSH_HARDENED=0

if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
    print_substep "Backing up sshd_config..."
    cp -v "$SSHD_CONFIG" "${SSHD_CONFIG}.bak.$(date +%Y%m%d-%H%M%S)"

    print_substep "Updating SSH configuration..."
    sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' "$SSHD_CONFIG"
    sed -i 's/^#*PermitEmptyPasswords.*/PermitEmptyPasswords no/'   "$SSHD_CONFIG"
    sed -i 's/^#*PubkeyAuthentication.*/PubkeyAuthentication yes/'  "$SSHD_CONFIG"

    grep -q "^PasswordAuthentication" "$SSHD_CONFIG" || echo "PasswordAuthentication no" >> "$SSHD_CONFIG"
    grep -q "^PermitEmptyPasswords"   "$SSHD_CONFIG" || echo "PermitEmptyPasswords no"   >> "$SSHD_CONFIG"
    grep -q "^PubkeyAuthentication"   "$SSHD_CONFIG" || echo "PubkeyAuthentication yes"  >> "$SSHD_CONFIG"

    print_substep "Restarting SSH service..."
    if systemctl restart sshd; then
        print_success "SSH restarted – password login disabled"
        SSH_HARDENED=1
    else
        print_error "Failed to restart sshd – check config manually!"
        exit 2
    fi
else
    print_skip "Password authentication remains enabled"
fi

echo ""

# ──────────────────────────────────────────────────────────────────────────────
# FINAL SUMMARY
# ──────────────────────────────────────────────────────────────────────────────

echo "┌───────────────────────────────┐"
echo "│           SUMMARY             │"
echo "└───────────────────────────────┘"

print_success "Useful aliases added first (ll, cls, dfh, etc.)"
print_success "Repositories configured"
print_success "Subscription nag removed"
print_success "System updated & upgraded"
[[ $REBOOT_NEEDED -eq 1 ]] && print_warning "Reboot recommended"
print_success "SSH keys added (${#valid_keys[@]} keys)"
[[ $SSH_HARDENED -eq 1 ]] && print_success "SSH hardened (password auth disabled)"

echo ""
echo "Script finished successfully."
echo ""

if [[ $REBOOT_NEEDED -eq 1 ]]; then
    echo "Recommended next step:"
    echo "  reboot"
    echo ""
fi

echo "Tip: Run 'source /root/.bashrc' or open a new shell to use the new aliases right away."
echo "     Try: ll    (to see files sorted by date)"

exit 0
