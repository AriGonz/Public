#!/usr/bin/env bash
# =============================================================================
# Proxmox VE 9.1.x Post-Install Configuration Script – Enhanced Visibility
# =============================================================================
# Security improvement:
#   - Fetches SSH keys from GitHub
#   - Verifies SHA-256 hash before using them
#   - Only adds keys if hash matches
#
# Recommended run command:
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/AriGonz/Public/refs/heads/main/proxmox-postinstall.sh)"
# =============================================================================

set -euo pipefail

# ──────────────────────────────────────────────────────────────────────────────
# CONFIGURATION
# ──────────────────────────────────────────────────────────────────────────────

KEYS_URL="https://raw.githubusercontent.com/AriGonz/Public/refs/heads/main/authorized_keys"
HASH_URL="https://raw.githubusercontent.com/AriGonz/Public/refs/heads/main/authorized_keys_sha256"

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
# 1. Add useful shell aliases (first so they're available early)
# ──────────────────────────────────────────────────────────────────────────────

print_step "Adding useful shell aliases to /root/.bashrc"

ALIAS_MARKER="# --- Proxmox Post-Install Aliases (added $(date +%Y-%m-%d)) ---"

if grep -qF "$ALIAS_MARKER" "$BASHRC" 2>/dev/null; then
    print_skip "Aliases already present"
else
    print_substep "Appending aliases block..."
    cat << 'EOF' >> "$BASHRC"

# --- Proxmox Post-Install Aliases (added $(date +%Y-%m-%d)) ---
alias ll='ls -lrt'               # Long listing, newest last
alias la='ls -A'                 # Almost all files
alias l='ls -CF'
alias cls='clear && ls -lrt'
alias dfh='df -h'
alias duh='du -sh * | sort -hr'
alias aptu='apt update && apt list --upgradable'
alias aptup='apt update && apt full-upgrade -y'
alias j='journalctl -xe --no-pager'
alias pvev='pveversion -v'
EOF
    print_success "Aliases added"
    print_substep "Run 'source /root/.bashrc' or open new shell to use them"
fi
echo ""

# ──────────────────────────────────────────────────────────────────────────────
# 2. Fetch & verify SSH public keys (with hash check)
# ──────────────────────────────────────────────────────────────────────────────

print_step "Fetching and verifying SSH public keys"

TMP_KEYS=$(mktemp)
TMP_HASH=$(mktemp)

print_substep "Downloading keys: $KEYS_URL"
if ! curl -fsSL --max-time "$CURL_TIMEOUT" -o "$TMP_KEYS" "$KEYS_URL"; then
    print_error "Failed to download keys file"
    rm -f "$TMP_KEYS" "$TMP_HASH"
    exit 1
fi

print_substep "Downloading expected SHA-256 hash: $HASH_URL"
if ! curl -fsSL --max-time "$CURL_TIMEOUT" -o "$TMP_HASH" "$HASH_URL"; then
    print_error "Failed to download hash file"
    rm -f "$TMP_KEYS" "$TMP_HASH"
    exit 1
fi

# Clean the expected hash (remove whitespace, newlines, etc.)
EXPECTED_HASH=$(tr -d '[:space:]\n\r' < "$TMP_HASH" | tr '[:upper:]' '[:lower:]')

# Compute actual hash of the downloaded keys file
ACTUAL_HASH=$(sha256sum "$TMP_KEYS" | cut -d' ' -f1 | tr '[:upper:]' '[:lower:]')

print_substep "Verifying SHA-256..."
echo "  Expected: $EXPECTED_HASH"
echo "  Actual:   $ACTUAL_HASH"

if [[ "$EXPECTED_HASH" == "$ACTUAL_HASH" ]]; then
    print_success "Hash verification PASSED – keys are trusted"
    KEYS_VERIFIED=1
else
    print_error "Hash verification FAILED – keys NOT trusted"
    echo "  The downloaded keys do NOT match the published hash."
    echo "  Possible reasons: file changed, MITM attack, wrong repo/branch"
    echo ""
    echo "  Aborting key addition for security reasons."
    rm -f "$TMP_KEYS" "$TMP_HASH"
    KEYS_VERIFIED=0
fi

# ──────────────────────────────────────────────────────────────────────────────
# Only proceed to parse keys if verification passed
# ──────────────────────────────────────────────────────────────────────────────

valid_keys=()
if [[ $KEYS_VERIFIED -eq 1 ]]; then
    mapfile -t PUBLIC_KEYS < "$TMP_KEYS"

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
        print_error "No valid SSH public keys found after parsing"
        KEYS_VERIFIED=0
    else
        print_success "Found ${#valid_keys[@]} valid public key(s)"
    fi
fi

rm -f "$TMP_KEYS" "$TMP_HASH"
echo ""

if [[ $KEYS_VERIFIED -ne 1 ]]; then
    print_warning "Skipping SSH key addition due to failed verification or no valid keys"
fi

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
    print_warning "Reboot is recommended after this upgrade"
fi
echo ""

# ──────────────────────────────────────────────────────────────────────────────
# 6. Add SSH keys (only if verified)
# ──────────────────────────────────────────────────────────────────────────────

if [[ $KEYS_VERIFIED -eq 1 && ${#valid_keys[@]} -gt 0 ]]; then

    print_step "Adding verified SSH public keys to root account"

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
else
    print_step "SSH key addition"
    print_skip "Skipped (keys not verified or no valid keys)"
fi
echo ""

# ──────────────────────────────────────────────────────────────────────────────
# 7. SSH Hardening (optional)
# ──────────────────────────────────────────────────────────────────────────────

print_step "SSH security hardening"
echo "  WARNING: This disables password login over SSH."
echo "           Only continue if you already have key access!"
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

print_success "Useful aliases added"
print_success "Repositories configured"
print_success "Subscription nag removed"
print_success "System updated & upgraded"
[[ $REBOOT_NEEDED -eq 1 ]] && print_warning "Reboot recommended"
if [[ $KEYS_VERIFIED -eq 1 && ${#valid_keys[@]} -gt 0 ]]; then
    print_success "SSH keys added (${#valid_keys[@]} keys) – verified by SHA-256"
else
    print_warning "SSH keys NOT added (verification failed or no keys)"
fi
[[ $SSH_HARDENED -eq 1 ]] && print_success "SSH hardened (password auth disabled)"

echo ""
echo "Script finished."
echo ""

if [[ $REBOOT_NEEDED -eq 1 ]]; then
    echo "Recommended next step: reboot"
fi

exit 0
