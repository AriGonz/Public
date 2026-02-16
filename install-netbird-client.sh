#!/usr/bin/env bash
# =============================================================================
# NetBird Client Installer (Debian/Ubuntu/Proxmox)
#
# Usage (recommended, run as root):
#   bash -c "$(curl -fsSL https://raw.githubusercontent.com/<YOU>/<REPO>/main/install-netbird-client.sh)"
#
# Examples:
#   NETBIRD_MANAGEMENT_URL="https://netbird.arigonz.com" bash install-netbird.sh
#   bash install-netbird.sh --no-ui
#   bash install-netbird.sh --no-up
#   bash install-netbird.sh --management-url "https://netbird.example.com"
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
  RED=""; GREEN=""; YELLOW=""; BLUE=""; RESET=""
fi

print_info()    { echo "${BLUE}→ $1${RESET}"; }
print_success() { echo "${GREEN}✓ $1${RESET}"; }
print_warning() { echo "${YELLOW}⚠ $1${RESET}" >&2; }
print_error()   { echo "${RED}✗ $1${RESET}" >&2; exit 1; }

# ──── Defaults / Config ──────────────────────────────────────────────────────
NETBIRD_KEY_URL="https://pkgs.netbird.io/debian/public.key"
NETBIRD_REPO_URL="https://pkgs.netbird.io/debian"
NETBIRD_KEYRING="/usr/share/keyrings/netbird-archive-keyring.gpg"
NETBIRD_LIST="/etc/apt/sources.list.d/netbird.list"

MANAGEMENT_URL_DEFAULT="https://netbird.arigonz.com"
MANAGEMENT_URL="${NETBIRD_MANAGEMENT_URL:-$MANAGEMENT_URL_DEFAULT}"

INSTALL_UI=1
DO_UP=1

# ──── Helpers ────────────────────────────────────────────────────────────────
require_root() {
  if [[ ${EUID:-0} -ne 0 ]]; then
    print_error "This script must be run as root (try: sudo bash $0 ...)"
  fi
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

run_as_login_user() {
  # Run as the invoking user if available; otherwise root.
  local user="${SUDO_USER:-root}"
  local cmd="$*"

  if [[ "$user" == "root" ]]; then
    bash -lc "$cmd"
  else
    # Keep HOME sane for CLI login flows
    sudo -u "$user" -H bash -lc "$cmd"
  fi
}

detect_os() {
  if [[ -r /etc/os-release ]]; then
    # shellcheck disable=SC1091
    . /etc/os-release
    OS_NAME="${NAME:-unknown}"
    OS_ID="${ID:-unknown}"
    OS_VERSION="${VERSION_ID:-unknown}"
    OS_CODENAME="${VERSION_CODENAME:-}"
  else
    OS_NAME="unknown"; OS_ID="unknown"; OS_VERSION="unknown"; OS_CODENAME=""
  fi
}

usage() {
  cat <<EOF
NetBird Client Installer

Options:
  --management-url <url>   Set Management URL (default: $MANAGEMENT_URL_DEFAULT)
  --no-ui                  Do NOT install netbird-ui
  --no-up                  Do NOT run 'netbird up' (installs only)
  -h, --help               Show this help

Env:
  NETBIRD_MANAGEMENT_URL   Alternative way to set management URL

EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --management-url)
        [[ $# -ge 2 ]] || print_error "--management-url requires a value"
        MANAGEMENT_URL="$2"
        shift 2
        ;;
      --no-ui)
        INSTALL_UI=0
        shift
        ;;
      --no-up)
        DO_UP=0
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        print_error "Unknown option: $1 (use --help)"
        ;;
    esac
  done
}

# ──── Header ────────────────────────────────────────────────────────────────
echo ""
echo "${BLUE}┌──────────────────────────────────────────────────────────────┐${RESET}"
echo "${BLUE}│              NetBird Client Install (apt-based)              │${RESET}"
echo "${BLUE}└──────────────────────────────────────────────────────────────┘${RESET}"
echo ""

# ──── 0. Preflight ───────────────────────────────────────────────────────────
require_root
parse_args "$@"
detect_os

print_info "Detected OS: ${OS_NAME} (id=${OS_ID}, version=${OS_VERSION}, codename=${OS_CODENAME:-n/a})"

if ! have_cmd apt-get; then
  print_error "apt-get not found. This script supports Debian/Ubuntu/Proxmox (apt-based) only."
fi

# ──── 1. Dependencies ───────────────────────────────────────────────────────
echo ""
echo "${BLUE}┌─────────────────────────────┐${RESET}"
echo "${BLUE}│ 1. Installing Dependencies  │${RESET}"
echo "${BLUE}└─────────────────────────────┘${RESET}"
echo ""

print_info "Updating package lists..."
apt-get update -qq

print_info "Installing prerequisites (ca-certificates, curl, gnupg)..."
apt-get install -y ca-certificates curl gnupg >/dev/null
print_success "Prerequisites installed"

# ──── 2. Repo + Keyring ─────────────────────────────────────────────────────
echo ""
echo "${BLUE}┌─────────────────────────────┐${RESET}"
echo "${BLUE}│ 2. Configuring NetBird Repo │${RESET}"
echo "${BLUE}└─────────────────────────────┘${RESET}"
echo ""

# Create keyring directory if needed
mkdir -p "$(dirname "$NETBIRD_KEYRING")"

# Install keyring (idempotent)
if [[ -s "$NETBIRD_KEYRING" ]]; then
  print_success "Keyring already present: $NETBIRD_KEYRING"
else
  print_info "Downloading and installing NetBird signing key..."
  curl -fsSL "$NETBIRD_KEY_URL" | gpg --dearmor --output "$NETBIRD_KEYRING"
  chmod 0644 "$NETBIRD_KEYRING"
  print_success "Keyring installed: $NETBIRD_KEYRING"
fi

# Install repo list (idempotent)
REPO_LINE="deb [signed-by=$NETBIRD_KEYRING] $NETBIRD_REPO_URL stable main"

if [[ -f "$NETBIRD_LIST" ]] && grep -qF "$REPO_LINE" "$NETBIRD_LIST"; then
  print_success "Repo already configured: $NETBIRD_LIST"
else
  print_info "Writing repo file: $NETBIRD_LIST"
  echo "$REPO_LINE" > "$NETBIRD_LIST"
  print_success "Repo configured"
fi

print_info "Refreshing package lists..."
apt-get update -qq
print_success "Package lists refreshed"

# ──── 3. Install NetBird ────────────────────────────────────────────────────
echo ""
echo "${BLUE}┌─────────────────────────────┐${RESET}"
echo "${BLUE}│ 3. Installing NetBird       │${RESET}"
echo "${BLUE}└─────────────────────────────┘${RESET}"
echo ""

print_info "Installing netbird..."
apt-get install -y netbird >/dev/null
print_success "Installed: netbird"

if [[ $INSTALL_UI -eq 1 ]]; then
  print_info "Installing netbird-ui..."
  apt-get install -y netbird-ui >/dev/null
  print_success "Installed: netbird-ui"
else
  print_warning "Skipping netbird-ui (--no-ui set)"
fi

# Enable/start service if present (best-effort)
if have_cmd systemctl; then
  if systemctl list-unit-files | grep -q '^netbird\.service'; then
    print_info "Enabling and starting netbird.service..."
    systemctl enable --now netbird.service >/dev/null 2>&1 || true
    print_success "netbird.service enable/start attempted"
  else
    print_warning "netbird.service not found in systemd unit list (may still work via 'netbird up')"
  fi
else
  print_warning "systemctl not found (container without systemd?). You can still run 'netbird up'."
fi

# ──── 4. Bring up (optional) ────────────────────────────────────────────────
echo ""
echo "${BLUE}┌─────────────────────────────┐${RESET}"
echo "${BLUE}│ 4. netbird up               │${RESET}"
echo "${BLUE}└─────────────────────────────┘${RESET}"
echo ""

print_info "Management URL: $MANAGEMENT_URL"

if [[ $DO_UP -eq 1 ]]; then
  if have_cmd netbird; then
    print_info "Running: netbird up --management-url \"$MANAGEMENT_URL\""
    print_warning "If this is a headless machine, NetBird may output a login link/code in the terminal."
    run_as_login_user "netbird up --management-url \"$MANAGEMENT_URL\""
    print_success "netbird up completed (or provided login instructions)"
  else
    print_error "netbird binary not found after install (unexpected)"
  fi
else
  print_warning "Skipping 'netbird up' (--no-up set)"
fi

# ──── Summary ───────────────────────────────────────────────────────────────
echo ""
echo "${BLUE}┌───────────────────────────────┐${RESET}"
echo "${BLUE}│ SUMMARY                       │${RESET}"
echo "${BLUE}└───────────────────────────────┘${RESET}"
echo ""

print_success "Repo configured: $NETBIRD_LIST"
print_success "Installed: netbird"
[[ $INSTALL_UI -eq 1 ]] && print_success "Installed: netbird-ui" || print_warning "netbird-ui not installed"
[[ $DO_UP -eq 1 ]] && print_success "Attempted: netbird up" || print_warning "netbird up skipped"

echo ""
echo "${GREEN}Done.${RESET}"
echo ""
