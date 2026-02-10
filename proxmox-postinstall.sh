#!/usr/bin/env bash
# =============================================================================
# Proxmox VE 9.x Post-Install Configuration Script – Enhanced & Fixed + 1s pauses
# =============================================================================
# SSH keys section significantly improved: better hash handling, atomic writes,
# clearer output, length validation, truncated/full hash display.
# =============================================================================
# Run with:
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/AriGonz/Public/refs/heads/main/proxmox-postinstall.sh)"
# =============================================================================

set -euo pipefail

# ──────────────────────────────────────────────────────────────────────────────
# CONFIGURATION
# ──────────────────────────────────────────────────────────────────────────────

KEYS_URL="https://raw.githubusercontent.com/AriGonz/Public/refs/heads/main/authorized_keys"
HASH_URL="https://raw.githubusercontent.com/AriGonz/Public/refs/heads/main/authorized_keys_sha256"

PVE_NOSUB_REPO="deb http://download.proxmox.com/debian/pve trixie pve-no-subscription"

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
    echo "│   Proxmox VE 9.x – Post-Install Configuration (Fixed)        │"
    echo "└──────────────────────────────────────────────────────────────┘"
    echo ""
}

print_step() { echo "→ $1"; }
print_substep() { echo "  • $1"; }
print_success() { echo "  ✓ $1"; }
print_skip() { echo "  (already done) $1"; }
print_warning() { echo "  ⚠  $1"; }
print_error() { echo "  ✗ ERROR: $1" >&2; }

# ──────────────────────────────────────────────────────────────────────────────
# START
# ──────────────────────────────────────────────────────────────────────────────

if [[ $EUID -ne 0 ]]; then
    print_error "This script must be run as root"
    exit 1
fi

print_header
sleep 1

# ──────────────────────────────────────────────────────────────────────────────
# 1. Add useful shell aliases
# ──────────────────────────────────────────────────────────────────────────────

print_step "Adding useful shell aliases to /root/.bashrc"

ALIAS_MARKER="# --- Proxmox Post-Install Aliases ---"

if grep -qF "$ALIAS_MARKER" "$BASHRC" 2>/dev/null; then
    print_skip "Aliases already present"
else
    print_substep "Appending aliases..."
    cat << 'EOF' >> "$BASHRC"

# --- Proxmox Post-Install Aliases ---
alias ll='ls -lrt'
alias la='ls -A'
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
    print_substep "Run: source /root/.bashrc  to use them now"
fi
echo ""
sleep 1

# ──────────────────────────────────────────────────────────────────────────────
# 2. Fetch, verify & add SSH public keys (IMPROVED VERSION)
# ──────────────────────────────────────────────────────────────────────────────

print_step "Fetching and verifying SSH public keys"

TMP_KEYS=$(mktemp)
TMP_HASH=$(mktemp)

print_substep "Downloading keys..."
if ! curl -fsSL --max-time "$CURL_TIMEOUT" -o "$TMP_KEYS" "$KEYS_URL"; then
    print_error "Failed to download keys from $KEYS_URL"
    rm -f "$TMP_KEYS" "$TMP_HASH"
    exit 1
fi

print_substep "Downloading expected SHA-256 hash..."
if ! curl -fsSL --max-time "$CURL_TIMEOUT" -o "$TMP_HASH" "$HASH_URL"; then
    print_error "Failed to download hash from $HASH_URL"
    rm -f "$TMP_KEYS" "$TMP_HASH"
    exit 1
fi

# Clean hash: remove all whitespace/newlines, force lowercase
EXPECTED_HASH=$(tr -d '[:space:]\n\r' < "$TMP_HASH" | tr '[:upper:]' '[:lower:]')

# Validate hash format
if [[ ${#EXPECTED_HASH} -ne 64 ]] || [[ ! "$EXPECTED_HASH" =~ ^[0-9a-f]{64}$ ]]; then
    print_error "Invalid expected hash format (must be exactly 64 lowercase hex chars)"
    print_error "Check your authorized_keys_sha256 file on GitHub"
    rm -f "$TMP_KEYS" "$TMP_HASH"
    exit 1
fi

ACTUAL_HASH=$(sha256sum "$TMP_KEYS" | cut -d' ' -f1)

print_substep "Verifying SHA-256 hash..."
echo "  Expected (short): ${EXPECTED_HASH:0:12}...${EXPECTED_HASH: -12}"
echo "  Expected (full):  $EXPECTED_HASH"
echo "  Actual   (short): ${ACTUAL_HASH:0:12}...${ACTUAL_HASH: -12}"
echo "  Actual   (full):  $ACTUAL_HASH"

KEYS_VERIFIED=0
if [[ "$EXPECTED_HASH" == "$ACTUAL_HASH" ]]; then
    print_success "Hash verification PASSED ✓ – keys are trusted"
    KEYS_VERIFIED=1
else
    print_error "Hash verification FAILED ✗ – keys NOT trusted"
    echo "  Aborting key addition for security reasons."
fi

# ── Parse keys only if verified ─────────────────────────────────────────────
valid_keys=()
if [[ $KEYS_VERIFIED -eq 1 ]]; then
    mapfile -t lines < "$TMP_KEYS"
    for line in "${lines[@]}"; do
        # Strip leading/trailing whitespace
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -z "$line" || "$line" =~ ^# ]] && continue
        if [[ "$line" =~ ^ssh-(rsa|ed25519|ecdsa)- ]]; then
            valid_keys+=("$line")
        else
            print_warning "Skipped invalid key line: ${line:0:50}..."
        fi
    done

    print_substep "Found ${#valid_keys[@]} valid SSH key(s)"
fi

rm -f "$TMP_KEYS" "$TMP_HASH"
echo ""
sleep 1

# ── Apply keys atomically only if verified ──────────────────────────────────
SSH_KEYS_ADDED_SUCCESSFULLY=0

if [[ $KEYS_VERIFIED -eq 1 && ${#valid_keys[@]} -gt 0 ]]; then
    print_step "Applying verified SSH keys"

    mkdir -p "$SSH_DIR"
    chmod 700 "$SSH_DIR"

    TEMP_AUTH_KEYS=$(mktemp)
    # Start with existing file if present
    [[ -f "$AUTHORIZED_KEYS" ]] && cp "$AUTHORIZED_KEYS" "$TEMP_AUTH_KEYS" || touch "$TEMP_AUTH_KEYS"
    chmod 600 "$TEMP_AUTH_KEYS"

    added=0
    for key in "${valid_keys[@]}"; do
        if grep -qF -- "$key" "$TEMP_AUTH_KEYS" 2>/dev/null; then
            print_substep "Already present: ${key:0:48}…"
        else
            echo "$key" >> "$TEMP_AUTH_KEYS"
            print_substep "Added new    : ${key:0:48}…"
            ((added++))
        fi
    done

    if [[ $added -gt 0 ]]; then
        mv "$TEMP_AUTH_KEYS" "$AUTHORIZED_KEYS"
        chmod 600 "$AUTHORIZED_KEYS"
        chown root:root "$AUTHORIZED_KEYS"
        print_success "$added new key(s) successfully added"
        SSH_KEYS_ADDED_SUCCESSFULLY=1
    else
        rm -f "$TEMP_AUTH_KEYS"
        print_success "No new keys needed – all were already present"
        SSH_KEYS_ADDED_SUCCESSFULLY=1
    fi
else
    print_step "SSH keys"
    print_skip "Skipped (verification failed or no valid keys)"
fi
echo ""
sleep 1

# ──────────────────────────────────────────────────────────────────────────────
# 3. Clean & configure repositories
# ──────────────────────────────────────────────────────────────────────────────

print_step "Cleaning and configuring APT repositories"

print_substep "Disabling enterprise repositories..."
find /etc/apt/sources.list /etc/apt/sources.list.d -type f -exec sed -i 's/^deb https:\/\/enterprise.proxmox.com/#deb https:\/\/enterprise.proxmox.com/' {} \;
print_success "All enterprise lines commented out"

if [[ -f /etc/apt/sources.list.d/ceph.list ]]; then
    print_substep "Commenting Ceph enterprise lines..."
    sed -i 's/^deb https:\/\/enterprise.proxmox.com/#deb https:\/\/enterprise.proxmox.com/' /etc/apt/sources.list.d/ceph.list
fi

print_substep "Configuring pve-no-subscription repo..."
if [[ ! -f "$PVE_NOSUB_LIST" ]] || ! grep -qF "$PVE_NOSUB_REPO" "$PVE_NOSUB_LIST"; then
    echo "$PVE_NOSUB_REPO" | tee "$PVE_NOSUB_LIST" >/dev/null
    print_success "PVE no-subscription repo added/updated (trixie)"
else
    print_skip "PVE no-subscription repo already correct"
fi
echo ""
sleep 1

# ──────────────────────────────────────────────────────────────────────────────
# 4. Remove subscription nag (web UI)
# ──────────────────────────────────────────────────────────────────────────────

print_step "Removing subscription nag (web UI)"
if [[ ! -f "$PROXMOXLIB_JS" ]]; then
    print_warning "proxmoxlib.js not found – skipping"
else
    if grep -q "if (false" "$PROXMOXLIB_JS"; then
        print_skip "Nag patch already applied"
    else
        BACKUP="${PROXMOXLIB_JS}.bak.$(date +%Y%m%d-%H%M%S)"
        cp -v "$PROXMOXLIB_JS" "$BACKUP"
        sed -i 's/if (res === null || res === undefined || !res || res/if (false || res === null || res === undefined || !res || res/' "$PROXMOXLIB_JS"
        print_success "Nag removed"
    fi
fi
echo ""
sleep 1

# ──────────────────────────────────────────────────────────────────────────────
# 5. Update & upgrade
# ──────────────────────────────────────────────────────────────────────────────

print_step "Updating package lists"
if ! apt update; then
    print_warning "apt update had warnings/errors – check output"
else
    print_success "Package lists updated"
fi

print_step "Upgrading system"
apt full-upgrade -y
print_success "Upgrade completed"

REBOOT_NEEDED=0
[[ -f /var/run/reboot-required ]] && REBOOT_NEEDED=1
[[ $REBOOT_NEEDED -eq 1 ]] && print_warning "Reboot recommended"
echo ""
sleep 1

# ──────────────────────────────────────────────────────────────────────────────
# 6. SSH hardening – ONLY if keys were successfully added
# ──────────────────────────────────────────────────────────────────────────────

print_step "SSH hardening (disable password login)"

if [[ $SSH_KEYS_ADDED_SUCCESSFULLY -eq 1 ]]; then
    echo "  WARNING: This will disable password authentication."
    echo "           Make sure key-based login works before confirming!"
    echo ""

    read -p "  Disable password authentication? (y/N): " -r CONFIRM
    echo ""

    SSH_HARDENED=0
    if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
        print_substep "Backing up sshd_config..."
        cp -v "$SSHD_CONFIG" "${SSHD_CONFIG}.bak.$(date +%Y%m%d-%H%M%S)"

        print_substep "Updating SSH configuration..."
        sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' "$SSHD_CONFIG"
        sed -i 's/^#*PermitEmptyPasswords.*/PermitEmptyPasswords no/' "$SSHD_CONFIG"
        sed -i 's/^#*PubkeyAuthentication.*/PubkeyAuthentication yes/' "$SSHD_CONFIG"

        grep -q "^PasswordAuthentication" "$SSHD_CONFIG" || echo "PasswordAuthentication no" >> "$SSHD_CONFIG"
        grep -q "^PermitEmptyPasswords"   "$SSHD_CONFIG" || echo "PermitEmptyPasswords no"   >> "$SSHD_CONFIG"
        grep -q "^PubkeyAuthentication"   "$SSHD_CONFIG" || echo "PubkeyAuthentication yes"  >> "$SSHD_CONFIG"

        print_substep "Restarting SSH service..."
        if systemctl restart sshd; then
            print_success "SSH restarted – password login disabled"
            SSH_HARDENED=1
        else
            print_error "Failed to restart sshd – check your config!"
            exit 2
        fi
    else
        print_skip "Password authentication remains enabled (user choice)"
    fi
else
    print_warning "Skipping SSH hardening – no keys were successfully added"
    print_substep "Reason: Either hash verification failed or no valid keys were found"
fi
echo ""
sleep 1

# ──────────────────────────────────────────────────────────────────────────────
# SUMMARY
# ──────────────────────────────────────────────────────────────────────────────

echo "┌───────────────────────────────┐"
echo "│           SUMMARY             │"
echo "└───────────────────────────────┘"

print_success "Aliases added"
print_success "Enterprise repos disabled"
print_success "PVE no-subscription repo configured"
print_success "Subscription nag removed"
print_success "System upgraded"
[[ $REBOOT_NEEDED -eq 1 ]] && print_warning "Reboot recommended"

if [[ $SSH_KEYS_ADDED_SUCCESSFULLY -eq 1 ]]; then
    print_success "SSH keys added (${#valid_keys[@]} keys) – verified"
else
    print_warning "SSH keys NOT added (verification failed or no keys)"
fi

[[ $SSH_HARDENED -eq 1 ]] && print_success "SSH hardened (password auth disabled)"
[[ $SSH_KEYS_ADDED_SUCCESSFULLY -eq 1 && $SSH_HARDENED -eq 0 ]] && print_skip "SSH hardening skipped by user"

echo ""
echo "Script finished."
if [[ $REBOOT_NEEDED -eq 1 ]]; then
    echo "Recommended next step: reboot"
fi
echo ""

sleep 1

exit 0
