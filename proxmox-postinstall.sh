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
  RED=""
  GREEN=""
  YELLOW=""
  BLUE=""
  RESET=""
fi

print_info()    { echo "${BLUE}→ $1${RESET}"; }
print_success() { echo "${GREEN}✓ $1${RESET}"; }
print_warning() { echo "${YELLOW}⚠ $1${RESET}" >&2; }
print_error()   { echo "${RED}✗ $1${RESET}" >&2; exit 1; }

section_box() {
  local n="$1" title="$2"
  echo ""
  echo "${BLUE}┌─────────────────────────────┐${RESET}"
  printf "${BLUE}│ %s. %-26s│${RESET}\n" "$n" "$title"
  echo "${BLUE}└─────────────────────────────┘${RESET}"
  echo ""
}

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
PVE_SOURCES_FILE="/etc/apt/sources.list.d/pve-no-subscription.sources"

# ─────────────────────────────────────────────────────────────────────────────
# 0. Root check
# ─────────────────────────────────────────────────────────────────────────────
if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
  print_error "This script must be run as root"
fi

echo ""
echo "${BLUE}┌──────────────────────────────────────────────────────────────┐${RESET}"
echo "${BLUE}│ Proxmox VE 9.x Post-Install Configuration Script              │${RESET}"
echo "${BLUE}└──────────────────────────────────────────────────────────────┘${RESET}"
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Install whiptail if not present
# ─────────────────────────────────────────────────────────────────────────────
if ! command -v whiptail >/dev/null 2>&1; then
  print_info "Installing whiptail for interactive selection..."
  apt update -qq || true
  apt install -y whiptail
  print_success "Installed whiptail"
fi

# ─────────────────────────────────────────────────────────────────────────────
# Interactive Section Selection
# ─────────────────────────────────────────────────────────────────────────────
SELECTED=$(
  whiptail --title "Proxmox Post-Install" --checklist \
  "Choose which sections to run (space to toggle, arrows to move, Enter to confirm)" \
  20 78 8 \
  "1" "Configure Repositories (disable enterprise, enable no-subscription)" ON \
  "2" "Remove Subscription Nag (patch proxmoxlib.js)" ON \
  "3" "System Full Upgrade (apt full-upgrade)" ON \
  "4" "Add SSH Public Keys to /root/.ssh/authorized_keys" ON \
  "5" "SSH Hardening (disable password auth if keys present)" OFF \
  3>&1 1>&2 2>&3
) || { echo "Selection canceled. Exiting."; exit 0; }

declare -A RUN_SECTION=()
for sec in $SELECTED; do
  RUN_SECTION[${sec//\"/}]="yes"
done

if [[ ${#RUN_SECTION[@]} -eq 0 ]]; then
  print_warning "No sections selected – exiting"
  exit 0
fi

# ─────────────────────────────────────────────────────────────────────────────
# Helpers
# ─────────────────────────────────────────────────────────────────────────────
detect_codename() {
  local c="trixie"
  if [[ -f /etc/os-release ]]; then
    c="$(grep -E '^VERSION_CODENAME=' /etc/os-release | cut -d= -f2 | tr -d '"')"
    [[ -z "$c" ]] && c="trixie"
  fi
  echo "$c"
}

restart_ssh_service() {
  # Debian/Proxmox typically uses "ssh", but some systems use "sshd"
  if systemctl list-unit-files | grep -qE '^ssh\.service'; then
    systemctl restart ssh
    return 0
  fi
  if systemctl list-unit-files | grep -qE '^sshd\.service'; then
    systemctl restart sshd
    return 0
  fi
  return 1
}

# ─────────────────────────────────────────────────────────────────────────────
# 1. Repository configuration
# ─────────────────────────────────────────────────────────────────────────────
if [[ "${RUN_SECTION[1]:-}" == "yes" ]]; then
  section_box "1" "Configuring Repositories"

  CODENAME="$(detect_codename)"
  print_info "Detected codename: $CODENAME"

  print_info "Disabling enterprise repositories..."

  # Handle classic .list files (just in case)
  find /etc/apt/sources.list /etc/apt/sources.list.d -type f -name "*.list" -print0 2>/dev/null | \
  while IFS= read -r -d '' file; do
    if grep -qi "enterprise.proxmox.com" "$file"; then
      sed -i '/enterprise.proxmox.com/ s/^deb[[:space:]]/#deb /' "$file"
      print_success "Commented enterprise lines in $file"
    fi
  done

  # Handle deb822 .sources files — disable any block containing enterprise
  find /etc/apt/sources.list.d -type f -name "*.sources" -print0 2>/dev/null | \
  while IFS= read -r -d '' file; do
    if grep -qi "enterprise.proxmox.com" "$file"; then
      awk -v RS= -v ORS='\n\n' '
        /URIs:.*enterprise\.proxmox\.com/ {
          gsub(/Enabled: yes/, "Enabled: no")
          if (!/Enabled:/) { $0 = $0 "\nEnabled: no" }
        }
        { print }
      ' "$file" > "${file}.tmp" && mv "${file}.tmp" "$file"
      print_success "Disabled enterprise entries in $file"
    fi
  done

  # Remove any leftover conflicting pve-enterprise.list (old style)
  rm -f /etc/apt/sources.list.d/pve-enterprise.list 2>/dev/null || true

  print_info "Configuring pve-no-subscription repository..."
  cat > "$PVE_SOURCES_FILE" <<EOF
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: $CODENAME
Components: pve-no-subscription
Signed-By: /usr/share/keyrings/proxmox-archive-keyring.gpg
EOF
  print_success "No-subscription repo configured ($PVE_SOURCES_FILE)"

  print_info "Refreshing package lists..."
  apt update -qq || true
fi

# ─────────────────────────────────────────────────────────────────────────────
# 2. Remove subscription nag
# ─────────────────────────────────────────────────────────────────────────────
if [[ "${RUN_SECTION[2]:-}" == "yes" ]]; then
  section_box "2" "Removing Subscription Nag"

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
fi

# ─────────────────────────────────────────────────────────────────────────────
# 3. System full upgrade
# ─────────────────────────────────────────────────────────────────────────────
if [[ "${RUN_SECTION[3]:-}" == "yes" ]]; then
  section_box "3" "System Full Upgrade"

  print_info "Performing full system upgrade..."
  apt full-upgrade -y

  if [[ -f /var/run/reboot-required ]]; then
    print_warning "Reboot recommended after upgrade"
    cat /var/run/reboot-required.pkgs 2>/dev/null || true
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# 4. Add SSH public keys
# ─────────────────────────────────────────────────────────────────────────────
SSH_KEYS_PRESENT=0
if [[ "${RUN_SECTION[4]:-}" == "yes" ]]; then
  section_box "4" "Adding SSH Public Keys"

  mkdir -p "$SSH_DIR"
  chmod 700 "$SSH_DIR"
  touch "$AUTHORIZED_KEYS"
  chmod 600 "$AUTHORIZED_KEYS"

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

  if ! chown root:root "$SSH_DIR" "$AUTHORIZED_KEYS" 2>/dev/null; then
    print_warning "chown failed - checking current permissions"
    ls -ld "$SSH_DIR" "$AUTHORIZED_KEYS" || true
  else
    print_success "Permissions set correctly for SSH directory and keys"
  fi

  if [[ -s "$AUTHORIZED_KEYS" ]] && grep -qE "^ssh-(rsa|ed25519|ecdsa)" "$AUTHORIZED_KEYS"; then
    SSH_KEYS_PRESENT=1
    print_success "Valid SSH key(s) detected"
  else
    SSH_KEYS_PRESENT=0
    print_warning "No valid SSH public keys found"
  fi
else
  # Still detect whether keys exist, for the hardening step if selected
  if [[ -s "$AUTHORIZED_KEYS" ]] && grep -qE "^ssh-(rsa|ed25519|ecdsa)" "$AUTHORIZED_KEYS" 2>/dev/null; then
    SSH_KEYS_PRESENT=1
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# 5. SSH Hardening (only if keys present)
# ─────────────────────────────────────────────────────────────────────────────
if [[ "${RUN_SECTION[5]:-}" == "yes" ]]; then
  section_box "5" "SSH Hardening"

  if [[ $SSH_KEYS_PRESENT -ne 1 ]]; then
    print_warning "Skipping hardening — no valid SSH keys present"
  else
    if (whiptail --title "SSH Hardening" --yesno "This will DISABLE password authentication for SSH.\n\nProceed?" 12 68); then
      print_info "Hardening SSH..."

      if [[ ! -f "$SSHD_CONFIG" ]]; then
        print_error "Missing $SSHD_CONFIG — cannot harden SSH"
      fi

      cp -v "$SSHD_CONFIG" "${SSHD_CONFIG}.bak.$(date +%Y%m%d-%H%M%S)"

      # Update or add required settings
      if grep -qE '^[#[:space:]]*PasswordAuthentication[[:space:]]+' "$SSHD_CONFIG"; then
        sed -i 's/^[#[:space:]]*PasswordAuthentication[[:space:]].*/PasswordAuthentication no/' "$SSHD_CONFIG"
      else
        echo "PasswordAuthentication no" >> "$SSHD_CONFIG"
      fi

      if grep -qE '^[#[:space:]]*PermitEmptyPasswords[[:space:]]+' "$SSHD_CONFIG"; then
        sed -i 's/^[#[:space:]]*PermitEmptyPasswords[[:space:]].*/PermitEmptyPasswords no/' "$SSHD_CONFIG"
      else
        echo "PermitEmptyPasswords no" >> "$SSHD_CONFIG"
      fi

      if grep -qE '^[#[:space:]]*PubkeyAuthentication[[:space:]]+' "$SSHD_CONFIG"; then
        sed -i 's/^[#[:space:]]*PubkeyAuthentication[[:space:]].*/PubkeyAuthentication yes/' "$SSHD_CONFIG"
      else
        echo "PubkeyAuthentication yes" >> "$SSHD_CONFIG"
      fi

      # Validate config before restarting
      if command -v sshd >/dev/null 2>&1; then
        if ! sshd -t; then
          print_error "sshd_config validation failed. Restore the backup and re-check."
        fi
      fi

      if restart_ssh_service; then
        print_success "SSH hardened & service restarted"
      else
        print_error "Failed to restart SSH service (ssh/sshd not found?) — check manually"
      fi
    else
      print_info "SSH hardening skipped"
    fi
  fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# Summary
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo "${BLUE}┌───────────────────────────────┐${RESET}"
echo "${BLUE}│ SUMMARY                       │${RESET}"
echo "${BLUE}└───────────────────────────────┘${RESET}"
echo ""

[[ "${RUN_SECTION[1]:-}" == "yes" ]] && print_success "Repositories configured"
[[ "${RUN_SECTION[2]:-}" == "yes" ]] && print_success "Subscription nag removal attempted"
[[ "${RUN_SECTION[3]:-}" == "yes" ]] && print_success "System fully upgraded"
[[ "${RUN_SECTION[4]:-}" == "yes" ]] && print_success "SSH keys processed (${#PUBLIC_KEYS[@]} defined)"
[[ "${RUN_SECTION[5]:-}" == "yes" ]] && print_success "SSH hardening attempted"

[[ -f /var/run/reboot-required ]] && print_warning "Reboot recommended"

if [[ $SSH_KEYS_PRESENT -eq 1 ]]; then
  print_success "Valid SSH key(s) present"
else
  print_warning "No valid SSH keys detected (hardening disabled/skipped)"
fi

echo ""
echo "${GREEN}Script completed successfully.${RESET}"
echo ""
if [[ -f /var/run/reboot-required ]]; then
  echo "Recommended next step: ${YELLOW}reboot${RESET}"
fi
echo ""

exit 0
