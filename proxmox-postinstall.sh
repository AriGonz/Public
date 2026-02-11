#!/usr/bin/env bash
# =============================================================================
# Run as root on a fresh Proxmox VE installation.
#
# Usage: bash -c "$(curl -fsSL https://raw.githubusercontent.com/AriGonz/Public/refs/heads/main/proxmox-postinstall.sh)"
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

print_info()    { echo "${BLUE}→ $1${RESET}"; }
print_success() { echo "${GREEN}✓ $1${RESET}"; }
print_warning() { echo "${YELLOW}⚠ $1${RESET}" >&2; }
print_error()   { echo "${RED}✗ $1${RESET}" >&2; exit 1; }

# ──── CONFIGURATION VARIABLES ────────────────────────────────────────────────
PUBLIC_KEYS=(
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAx0vHaUQfDPrVPLt8GhC8aCwRDVAZWa8wGL9/aPb7dQ eddsa-key-20260205"
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIDwF69AFzU724Y+F875vRApoudqQkuOhVZti65kyfNzK eddsa-key-20260205"
    # Add more keys here if needed
)

PROXMOXLIB_JS="/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js"

SSH_DIR="/root/.ssh"
AUTHORIZED_KEYS="${SSH_DIR}/authorized_keys"
SSHD_CONFIG="/etc/ssh/sshd_config"

# ──── END OF CONFIGURATION ───────────────────────────────────────────────────

echo ""
echo "${BLUE}┌──────────────────────────────────────────────────────────────┐${RESET}"
echo "${BLUE}│   Proxmox VE 9.x Post-Install Configuration Script           │${RESET}"
echo "${BLUE}└──────────────────────────────────────────────────────────────┘${RESET}"
echo ""

# ──────────────────────────────────────────────────────────────────────────────
# 0. Root check
# ──────────────────────────────────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    print_error "This script must be run as root"
fi

# ──────────────────────────────────────────────────────────────────────────────
# 1. Repository configuration
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "${BLUE}┌─────────────────────────────┐${RESET}"
echo "${BLUE}│ 1. Configuring Repositories │${RESET}"
echo "${BLUE}└─────────────────────────────┘${RESET}"
echo ""

# Detect actual codename (Proxmox VE 9.x = trixie)
if [[ -f /etc/os-release ]]; then
    CODENAME=$(grep VERSION_CODENAME /etc/os-release | cut -d= -f2 | tr -d '"')
    [[ -z "$CODENAME" ]] && CODENAME="trixie"
else
    CODENAME="trixie"
fi

NOSUB_REPO="deb http://download.proxmox.com/debian/pve $CODENAME pve-no-subscription"
print_info "Detected codename: $CODENAME"

# Disable enterprise repo (both .list and .sources styles)
print_info "Disabling enterprise repositories..."

find /etc/apt/sources.list /etc/apt/sources.list.d -type f -name "*.list" -print0 2>/dev/null | \
while IFS= read -r -d '' file; do
    if grep -q "enterprise.proxmox.com" "$file"; then
        sed -i '/enterprise.proxmox.com/s/^deb[[:space:]]/#deb /' "$file"
        print_success "Commented enterprise in $file"
    fi
done

find /etc/apt/sources.list.d -type f -name "*.sources" -print0 2>/dev/null | \
while IFS= read -r -d '' file; do
    if grep -q "enterprise.proxmox.com" "$file"; then
        sed -i '/URIs:.*enterprise.proxmox.com/{n;s/Enabled: yes/Enabled: no/}' "$file"
        print_success "Disabled enterprise in deb822 file $file"
    fi
done

# Add/update no-subscription repo
NOSUB_FILE="/etc/apt/sources.list.d/pve-no-subscription.list"
if [[ ! -f "$NOSUB_FILE" ]] || ! grep -qF "$NOSUB_REPO" "$NOSUB_FILE"; then
    print_info "Adding no-subscription repository..."
    echo "$NOSUB_REPO" > "$NOSUB_FILE"
    print_success "No-subscription repo added"
else
    print_success "No-subscription repo already configured"
fi

# Refresh package lists after repo changes
print_info "Refreshing package lists..."
apt update -qq

# ──────────────────────────────────────────────────────────────────────────────
# 2. Remove subscription nag
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "${BLUE}┌─────────────────────────────┐${RESET}"
echo "${BLUE}│ 2. Removing Subscription Nag│${RESET}"
echo "${BLUE}└─────────────────────────────┘${RESET}"
echo ""

if [[ ! -f "$PROXMOXLIB_JS" ]]; then
    print_warning "$PROXMOXLIB_JS not found — skipping nag removal"
else
    if grep -q "if (false || res" "$PROXMOXLIB_JS"; then
        print_success "Nag patch already applied"
    else
        BACKUP="${PROXMOXLIB_JS}.bak.$(date +%Y%m%d-%H%M%S)"
        print_info "Backing up → $BACKUP"
        cp -v "$PROXMOXLIB_JS" "$BACKUP"

        print_info "Applying nag removal..."
        sed -i '/res\.data\.status\s*!==\s*"Active"/s/if (res === null.*res/if (false || res === null || res === undefined || !res || res/' "$PROXMOXLIB_JS"

        if grep -q "if (false || res" "$PROXMOXLIB_JS"; then
            print_success "Nag removal applied"
        else
            print_warning "Patch may have failed — check $PROXMOXLIB_JS"
        fi
    fi
fi

# ──────────────────────────────────────────────────────────────────────────────
# 3. System full upgrade
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "${BLUE}┌─────────────────────────────┐${RESET}"
echo "${BLUE}│ 3. System Full Upgrade      │${RESET}"
echo "${BLUE}└─────────────────────────────┘${RESET}"
echo ""

print_info "Performing full system upgrade..."
apt full-upgrade -y

if [[ -f /var/run/reboot-required ]]; then
    print_warning "Reboot recommended after upgrade"
    cat /var/run/reboot-required.pkgs 2>/dev/null || true
fi

# ──────────────────────────────────────────────────────────────────────────────
# 4. Add SSH public keys
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "${BLUE}┌─────────────────────────────┐${RESET}"
echo "${BLUE}│ 4. Adding SSH Public Keys   │${RESET}"
echo "${BLUE}└─────────────────────────────┘${RESET}"
echo ""

mkdir -p "$SSH_DIR"
chmod 700 "$SSH_DIR"

added=0
for key in "${PUBLIC_KEYS[@]}"; do
    [[ -z "$key" || "$key" =~ ^[[:space:]]*# ]] && continue
    if ! grep -qF -- "$key" "$AUTHORIZED_KEYS" 2>/dev/null; then
        echo "$key" >> "$AUTHORIZED_KEYS"
        print_success "Added: ${key:0:50}..."
        ((added++))
    else
        print_success "Already present: ${key:0:50}..."
    fi
done

[[ $added -eq 0 ]] && print_info "All keys were already present"

chmod 600 "$AUTHORIZED_KEYS"
chown root:root "$SSH_DIR" "$AUTHORIZED_KEYS"

SSH_KEYS_PRESENT=0
if [[ -s "$AUTHORIZED_KEYS" ]] && grep -qE "^ssh-(rsa|ed25519|ecdsa)" "$AUTHORIZED_KEYS"; then
    SSH_KEYS_PRESENT=1
    print_success "Valid SSH key(s) detected"
else
    print_warning "No valid SSH public keys found"
fi

# ──────────────────────────────────────────────────────────────────────────────
# 5. SSH Hardening (only if keys present)
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "${BLUE}┌─────────────────────────────┐${RESET}"
echo "${BLUE}│ 5. SSH Hardening            │${RESET}"
echo "${BLUE}└─────────────────────────────┘${RESET}"
echo ""

if [[ $SSH_KEYS_PRESENT -eq 1 ]]; then
    print_warning "This will DISABLE password authentication"
    read -p "  Proceed? (y/N): " -r CONFIRM
    if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
        print_info "Hardening SSH..."
        cp -v "$SSHD_CONFIG" "${SSHD_CONFIG}.bak.$(date +%Y%m%d-%H%M%S)"

        sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication no/' "$SSHD_CONFIG"
        sed -i 's/^#*PermitEmptyPasswords.*/PermitEmptyPasswords no/' "$SSHD_CONFIG"
        sed -i 's/^#*PubkeyAuthentication.*/PubkeyAuthentication yes/' "$SSHD_CONFIG"

        grep -q "^PasswordAuthentication" "$SSHD_CONFIG" || echo "PasswordAuthentication no" >> "$SSHD_CONFIG"
        grep -q "^PermitEmptyPasswords" "$SSHD_CONFIG" || echo "PermitEmptyPasswords no" >> "$SSHD_CONFIG"
        grep -q "^PubkeyAuthentication" "$SSHD_CONFIG" || echo "PubkeyAuthentication yes" >> "$SSHD_CONFIG"

        if systemctl restart sshd; then
            print_success "SSH hardened & service restarted"
        else
            print_error "Failed to restart sshd — check config"
        fi
    else
        print_info "SSH hardening skipped"
    fi
else
    print_warning "Skipping hardening — no valid SSH keys present"
fi

# ──────────────────────────────────────────────────────────────────────────────
# Summary
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "${BLUE}┌───────────────────────────────┐${RESET}"
echo "${BLUE}│           SUMMARY             │${RESET}"
echo "${BLUE}└───────────────────────────────┘${RESET}"
echo ""
print_success "Repositories configured"
print_success "Subscription nag removal attempted"
print_success "System fully upgraded"
[[ -f /var/run/reboot-required ]] && print_warning "Reboot recommended"
print_success "SSH keys processed (${#PUBLIC_KEYS[@]} defined)"
[[ $SSH_KEYS_PRESENT -eq 1 ]] && print_success "Valid SSH key(s) present"
[[ $SSH_KEYS_PRESENT -eq 0 ]] && print_warning "No valid SSH keys — hardening skipped"

echo ""
echo "${GREEN}Script completed successfully.${RESET}"
echo ""
if [[ -f /var/run/reboot-required ]]; then
    echo "Recommended next step: ${YELLOW}reboot${RESET}"
fi
echo ""

exit 0
