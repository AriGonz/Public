#!/usr/bin/env bash
# =============================================================================
# Proxmox VE 9.1.x Post-Install Configuration Script – Enhanced Visibility
# =============================================================================
# Features:
#   - Very clear step-by-step output with progress indicators
#   - Visual boxes and separators
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
# 1. Fetch SSH public keys
# ──────────────────────────────────────────────────────────────────────────────

print_step "Fetching your SSH public keys"
echo "  From: $SSH_KEYS_URL"

TMP_KEYS=$(mktemp)

if curl -fsSL --max-time "$CURL_TIMEOUT" -o "$TMP_KEYS" "$SSH_KEYS_URL"; then
    print_success "Keys downloaded successfully"
else
    print_error "Failed to download keys from $SSH_KEYS_URL"
    echo "  → Check your internet, the URL, or GitHub status."
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
    print_error "No valid SSH public keys found in the file"
    exit 1
fi

print_success "Found ${#valid_keys[@]} valid public key(s)"
echo ""

# ──────────────────────────────────────────────────────────────────────────────
# 2. Repositories
# ──────────────────────────────────────────────────────────────────────────────

print_step "Configuring APT repositories"

# Disable enterprise repo
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

# Add no-subscription repo
if [[ ! -f "$PVE_NOSUB_LIST" ]] || ! grep -qF "$PVE_NOSUBSCRIPTION_REPO" "$PVE_NOSUB_LIST"; then
    print_substep "Adding no-subscription repository..."
    echo "$PVE_NOSUBSCRIPTION_REPO" | tee "$PVE_NOSUB_LIST" >/dev/null
    print_success "No-subscription repo added"
else
    print_skip "No-subscription repo already configured"
fi

echo ""

# ──────────────────────────────────────────────────────────────────────────────
# 3. Remove subscription nag
# ──────────────────────────────────────────────────────────────────────────────

print_step "Removing subscription nag popup (web UI)"

if [[ ! -f "$PROXMOXLIB_JS" ]]; then
    print_warning "proxmoxlib.js not found — skipping this step"
else
    if grep -q "return false;" "$PROXMOXLIB_JS" && grep -q "if (false" "$PROXMOXLIB_JS"; then
        print_skip "Nag patch already applied"
    else
        BACKUP="${PROXMOXLIB_JS}.bak.$(date +%Y%m%d-%H%M%S)"
        print_substep "Backing up original file → $BACKUP"
        cp -v "$PROXMOXLIB_JS" "$BACKUP"

        print_substep "Applying patch..."
        sed -i 's/if (res === null || res === undefined || !res || res/if (false || res === null || res === undefined || !res || res/' "$PROXMOXLIB_JS"
        print_success "Subscription nag removed"
    fi
fi

echo ""

# ──────────────────────────────────────────────────────────────────────────────
# 4. System update & upgrade
# ──────────────────────────────────────────────────────────────────────────────

print_step "Updating package lists"
apt update -qq
print_success "Package lists updated"

print_step "Upgrading installed packages (this may take a while)"
apt full-upgrade -y
print_success "System upgrade completed"

REBOOT_NEEDED=0
[[ -f /var/run/reboot-required ]] && REBOOT_NEEDED=1

if [[ $REBOOT_NEEDED -eq 1 ]]; then
    print_warning "Reboot is recommended after this upgrade"
fi
echo ""

# ──────────────────────────────────────────────────────────────────────────────
# 5. Add SSH keys
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
# 6. SSH Hardening (optional)
# ──────────────────────────────────────────────────────────────────────────────

print_step "SSH security hardening"
echo "  WARNING: This will disable password login over SSH."
echo "           Make sure key-based login works first!"
echo "           Keys used: $SSH_KEYS_URL"
echo ""

read -p "  Disable password authentication? (y/N): " -r CONFIRM
echo ""

SSH_HARDENED=0

if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
    print_substep "Creating backup of sshd_config..."
    cp -v "$SSHD_CONFIG" "${SSHD_CONFIG}.bak.$(date +%Y%m%d-%H%M%S)"

    print_substep "Updating SSH configuration..."
    sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' "$SSHD_CONFIG"
    sed -i 's/^#*PermitEmptyPasswords.*/PermitEmptyPasswords no/'   "$SSHD_CONFIG"
    sed -i 's/^#*PubkeyAuthentication.*/PubkeyAuthentication yes/'  "$SSHD_CONFIG"

    # Ensure lines exist
    grep -q "^PasswordAuthentication" "$SSHD_CONFIG" || echo "PasswordAuthentication no" >> "$SSHD_CONFIG"
    grep -q "^PermitEmptyPasswords"   "$SSHD_CONFIG" || echo "PermitEmptyPasswords no"   >> "$SSHD_CONFIG"
    grep -q "^PubkeyAuthentication"   "$SSHD_CONFIG" || echo "PubkeyAuthentication yes"  >> "$SSHD_CONFIG"

    print_substep "Restarting SSH service..."
    if systemctl restart sshd; then
        print_success "SSH service restarted – password login disabled"
        SSH_HARDENED=1
    else
        print_error "Failed to restart sshd – check config manually!"
        exit 2
    fi
else
    print_skip "Password authentication remains enabled (user choice)"
fi

echo ""

# ──────────────────────────────────────────────────────────────────────────────
# FINAL SUMMARY
# ──────────────────────────────────────────────────────────────────────────────

echo "┌───────────────────────────────┐"
echo "│           SUMMARY             │"
echo "└───────────────────────────────┘"

print_success "Repositories configured"
print_success "Subscription nag removed"
print_success "System fully updated/upgraded"
[[ $REBOOT_NEEDED -eq 1 ]] && print_warning "Reboot recommended"
print_success "SSH keys added (${#valid_keys[@]} keys processed)"
[[ $SSH_HARDENED -eq 1 ]] && print_success "SSH hardened (password auth disabled)"
[[ $SSH_HARDENED -eq 0 ]] && print_skip "SSH hardening skipped"

echo ""
echo "Script finished successfully."
echo ""

if [[ $REBOOT_NEEDED -eq 1 ]]; then
    echo "Recommended next step:"
    echo "  sudo reboot"
    echo ""
fi

exit 0
