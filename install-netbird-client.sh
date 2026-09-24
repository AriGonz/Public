#!/usr/bin/env bash
# =============================================================================
# NetBird Client Installer (Debian / Ubuntu / Proxmox)
#
# Installs the official NetBird apt package and optionally enrolls the peer.
# Setup keys are accepted only via flag or env - never hard-coded.
# Enables NetBird --allow-server-ssh by default and ensures OpenSSH is running.
#
# Recommended (pipe so flags work):
#   curl -fsSL https://raw.githubusercontent.com/AriGonz/Public/refs/heads/main/install-netbird-client.sh \
#     | sudo bash -s -- --no-ui --setup-key "$NETBIRD_SETUP_KEY"
#
# Examples:
#   sudo bash install-netbird-client.sh --no-ui --no-up
#   sudo bash install-netbird-client.sh --no-ui --setup-key '....'
#   sudo NETBIRD_SETUP_KEY='....' bash install-netbird-client.sh --no-ui
#   sudo bash install-netbird-client.sh --management-url 'https://netbird.arigonz.com' --no-ui
#   sudo bash install-netbird-client.sh --no-ui --no-ssh
#
# Note: bash -c "$(curl ...)" cannot pass --flags; use bash -s -- as above.
# =============================================================================

set -euo pipefail

if [[ -t 1 ]]; then
  RED=$(tput setaf 1); GREEN=$(tput setaf 2); YELLOW=$(tput setaf 3)
  BLUE=$(tput setaf 4); RESET=$(tput sgr0)
else
  RED=""; GREEN=""; YELLOW=""; BLUE=""; RESET=""
fi

print_info()    { echo "${BLUE}-> $1${RESET}"; }
print_success() { echo "${GREEN}OK $1${RESET}"; }
print_warning() { echo "${YELLOW}WARN: $1${RESET}" >&2; }
print_error()   { echo "${RED}ERR $1${RESET}" >&2; exit 1; }

# Official NetBird apt repo (https://docs.netbird.io/how-to/installation/linux)
NETBIRD_KEY_URL="https://pkgs.netbird.io/debian/public.key"
NETBIRD_REPO_URL="https://pkgs.netbird.io/debian"
NETBIRD_KEYRING="/usr/share/keyrings/netbird-archive-keyring.gpg"
NETBIRD_LIST="/etc/apt/sources.list.d/netbird.list"

MANAGEMENT_URL_DEFAULT="https://netbird.arigonz.com"
MANAGEMENT_URL="${NETBIRD_MANAGEMENT_URL:-$MANAGEMENT_URL_DEFAULT}"
SETUP_KEY="${NETBIRD_SETUP_KEY:-}"

# Defaults: UI off on Proxmox hosts, on elsewhere (overridable)
INSTALL_UI=1
DO_UP=1
ALLOW_SERVER_SSH=1   # NetBird embedded SSH; use --no-ssh to skip
ENSURE_OPENSSH=1     # Install/enable openssh-server for SSH over the mesh
if [[ -d /etc/pve ]] || grep -qi proxmox /etc/os-release 2>/dev/null; then
  INSTALL_UI=0
fi

require_root() {
  if [[ ${EUID:-0} -ne 0 ]]; then
    print_error "Run as root (sudo bash $0 ...)"
  fi
}

have_cmd() { command -v "$1" >/dev/null 2>&1; }

mask_key() {
  local k="${1:-}"
  if [[ -z "$k" ]]; then echo "(none)"; return; fi
  if [[ ${#k} -le 8 ]]; then echo "****"; return; fi
  echo "${k:0:4}...${k: -4}"
}

disable_pve_enterprise_if_needed() {
  local ent="/etc/apt/sources.list.d/pve-enterprise.list"
  [[ -f "$ent" ]] || return 0
  if grep -qE '^[[:space:]]*deb' "$ent"; then
    print_warning "Disabling Proxmox enterprise apt repo (common 401 without subscription)"
    mkdir -p /etc/apt/sources.list.d/disabled
    mv "$ent" "/etc/apt/sources.list.d/disabled/pve-enterprise.list.bak.$(date +%Y%m%d%H%M%S)"
  fi
  if [[ -d /etc/pve ]] && ! grep -Rqs 'pve-no-subscription' /etc/apt/sources.list /etc/apt/sources.list.d 2>/dev/null; then
    local codename=""
    if [[ -r /etc/os-release ]]; then
      # shellcheck disable=SC1091
      . /etc/os-release
      codename="${VERSION_CODENAME:-}"
    fi
    if [[ -z "$codename" ]] && have_cmd pveversion; then
      local pve_major
      pve_major=$(pveversion 2>/dev/null | head -1 | cut -d'/' -f2 | cut -d'.' -f1 || true)
      case "${pve_major:-}" in
        8) codename="bookworm" ;;
        9) codename="trixie" ;;
      esac
    fi
    if [[ -n "$codename" ]]; then
      print_info "Adding pve-no-subscription repo for $codename"
      echo "deb http://download.proxmox.com/debian/pve ${codename} pve-no-subscription" \
        > /etc/apt/sources.list.d/pve-no-subscription.list
    else
      print_warning "Could not detect Debian codename; add pve-no-subscription manually if apt update fails"
    fi
  fi
}

apt_update_soft() {
  if apt-get update -qq; then
    return 0
  fi
  print_warning "apt-get update failed; checking Proxmox enterprise repo..."
  disable_pve_enterprise_if_needed
  apt-get update -qq
}

ensure_openssh() {
  [[ $ENSURE_OPENSSH -eq 1 ]] || { print_warning "Skipping OpenSSH ensure (--no-openssh)"; return 0; }
  echo ""
  echo "${BLUE}┌─────────────────────────────┐${RESET}"
  echo "${BLUE}│ OpenSSH server              │${RESET}"
  echo "${BLUE}└─────────────────────────────┘${RESET}"
  echo ""
  if ! dpkg -s openssh-server >/dev/null 2>&1; then
    print_info "Installing openssh-server..."
    DEBIAN_FRONTEND=noninteractive apt-get install -y openssh-server >/dev/null
    print_success "Installed: openssh-server"
  else
    print_success "openssh-server already installed"
  fi
  if have_cmd systemctl; then
    systemctl enable ssh.service >/dev/null 2>&1 || systemctl enable sshd.service >/dev/null 2>&1 || true
    systemctl start ssh.service >/dev/null 2>&1 || systemctl start sshd.service >/dev/null 2>&1 || true
    if systemctl is-active --quiet ssh.service 2>/dev/null || systemctl is-active --quiet sshd.service 2>/dev/null; then
      print_success "SSH service is active"
    else
      print_warning "SSH service did not report active; check: systemctl status ssh"
    fi
  else
    print_warning "systemctl not found; ensure sshd is running manually"
  fi
}

usage() {
  cat <<EOF
NetBird Client Installer (Debian/Ubuntu/Proxmox)

Options:
  --management-url <url>   Management URL (default: ${MANAGEMENT_URL_DEFAULT})
  --setup-key <key>        Setup key for unattended enroll (or NETBIRD_SETUP_KEY)
  --no-ui                  Do not install netbird-ui (default on Proxmox)
  --ui                     Install netbird-ui (desktop)
  --no-up                  Install only; do not run 'netbird up'
  --allow-server-ssh       Enable NetBird embedded SSH (default)
  --no-ssh                 Do not pass --allow-server-ssh
  --no-openssh             Do not install/enable OpenSSH server
  -h, --help               Show help

Env:
  NETBIRD_MANAGEMENT_URL   Same as --management-url
  NETBIRD_SETUP_KEY        Same as --setup-key

Proxmox tip:
  curl -fsSL https://raw.githubusercontent.com/AriGonz/Public/refs/heads/main/install-netbird-client.sh \\
    | sudo bash -s -- --no-ui --setup-key "\$NETBIRD_SETUP_KEY"
EOF
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --management-url)
        [[ $# -ge 2 ]] || print_error "--management-url requires a value"
        MANAGEMENT_URL="$2"; shift 2 ;;
      --setup-key)
        [[ $# -ge 2 ]] || print_error "--setup-key requires a value"
        SETUP_KEY="$2"; shift 2 ;;
      --no-ui) INSTALL_UI=0; shift ;;
      --ui)    INSTALL_UI=1; shift ;;
      --no-up) DO_UP=0; shift ;;
      --allow-server-ssh) ALLOW_SERVER_SSH=1; shift ;;
      --no-ssh) ALLOW_SERVER_SSH=0; shift ;;
      --no-openssh) ENSURE_OPENSSH=0; shift ;;
      -h|--help) usage; exit 0 ;;
      *) print_error "Unknown option: $1 (use --help)" ;;
    esac
  done
}

echo ""
echo "${BLUE}┌──────────────────────────────────────────────────────────────┐${RESET}"
echo "${BLUE}│              NetBird Client Install (apt-based)              │${RESET}"
echo "${BLUE}└──────────────────────────────────────────────────────────────┘${RESET}"
echo ""

require_root
parse_args "$@"

if [[ -r /etc/os-release ]]; then
  # shellcheck disable=SC1091
  . /etc/os-release
  print_info "Detected OS: ${PRETTY_NAME:-$NAME} (id=${ID:-?}, version=${VERSION_ID:-?}, codename=${VERSION_CODENAME:-n/a})"
fi

have_cmd apt-get || print_error "apt-get not found (Debian/Ubuntu/Proxmox only)"

echo ""
echo "${BLUE}┌─────────────────────────────┐${RESET}"
echo "${BLUE}│ 1. Dependencies             │${RESET}"
echo "${BLUE}└─────────────────────────────┘${RESET}"
echo ""

disable_pve_enterprise_if_needed
print_info "Updating package lists..."
apt_update_soft
print_info "Installing prerequisites (ca-certificates, curl, gnupg)..."
DEBIAN_FRONTEND=noninteractive apt-get install -y ca-certificates curl gnupg >/dev/null
print_success "Prerequisites installed"

echo ""
echo "${BLUE}┌─────────────────────────────┐${RESET}"
echo "${BLUE}│ 2. NetBird apt repository   │${RESET}"
echo "${BLUE}└─────────────────────────────┘${RESET}"
echo ""

mkdir -p "$(dirname "$NETBIRD_KEYRING")"
print_info "Installing NetBird signing key..."
tmp_key="$(mktemp)"
curl -fsSL "$NETBIRD_KEY_URL" -o "$tmp_key"
gpg --batch --yes --dearmor -o "$NETBIRD_KEYRING" "$tmp_key"
chmod 0644 "$NETBIRD_KEYRING"
rm -f "$tmp_key"
print_success "Keyring: $NETBIRD_KEYRING"

REPO_LINE="deb [signed-by=${NETBIRD_KEYRING}] ${NETBIRD_REPO_URL} stable main"
echo "$REPO_LINE" > "$NETBIRD_LIST"
print_success "Repo: $NETBIRD_LIST"

print_info "Refreshing package lists..."
apt_update_soft
print_success "Package lists refreshed"

echo ""
echo "${BLUE}┌─────────────────────────────┐${RESET}"
echo "${BLUE}│ 3. Install packages         │${RESET}"
echo "${BLUE}└─────────────────────────────┘${RESET}"
echo ""

print_info "Installing netbird..."
DEBIAN_FRONTEND=noninteractive apt-get install -y netbird >/dev/null
print_success "Installed: netbird ($(netbird version 2>/dev/null || echo unknown))"

if [[ $INSTALL_UI -eq 1 ]]; then
  print_info "Installing netbird-ui (desktop UI)..."
  if DEBIAN_FRONTEND=noninteractive apt-get install -y netbird-ui >/dev/null; then
    print_success "Installed: netbird-ui"
  else
    print_warning "netbird-ui install failed (CLI is enough on servers)"
  fi
else
  print_warning "Skipping netbird-ui (use --ui to force)"
fi

if have_cmd systemctl; then
  if systemctl list-unit-files --type=service 2>/dev/null | grep -q '^netbird\.service'; then
    print_info "Enabling netbird.service..."
    systemctl enable --now netbird.service >/dev/null 2>&1 || true
    print_success "netbird.service enable/start attempted"
  else
    print_warning "netbird.service not listed yet (netbird up will still work)"
  fi
fi

ensure_openssh

echo ""
echo "${BLUE}┌─────────────────────────────┐${RESET}"
echo "${BLUE}│ 4. netbird up               │${RESET}"
echo "${BLUE}└─────────────────────────────┘${RESET}"
echo ""

print_info "Management URL: $MANAGEMENT_URL"
print_info "Setup key: $(mask_key "$SETUP_KEY")"
if [[ $ALLOW_SERVER_SSH -eq 1 ]]; then
  print_info "NetBird SSH: enabled (--allow-server-ssh)"
else
  print_info "NetBird SSH: disabled"
fi

if [[ $DO_UP -eq 1 ]]; then
  have_cmd netbird || print_error "netbird binary missing after install"
  up_args=(up --management-url "$MANAGEMENT_URL")
  if [[ -n "$SETUP_KEY" ]]; then
    up_args+=(--setup-key "$SETUP_KEY")
  else
    print_warning "No setup key provided - NetBird may prompt for interactive/SSO login"
  fi
  if [[ $ALLOW_SERVER_SSH -eq 1 ]]; then
    up_args+=(--allow-server-ssh)
  fi
  # Mask setup key in the logged command line
  log_args=()
  for a in "${up_args[@]}"; do
    if [[ -n "$SETUP_KEY" && "$a" == "$SETUP_KEY" ]]; then
      log_args+=("(masked)")
    else
      log_args+=("$a")
    fi
  done
  print_info "Running: netbird ${log_args[*]}"
  # If already connected, bring down first so --allow-server-ssh sticks
  if netbird status >/dev/null 2>&1; then
    print_info "Existing NetBird session detected; running netbird down first"
    netbird down || true
  fi
  # Enroll as root so the daemon owns /etc/netbird on servers
  netbird "${up_args[@]}"
  print_success "netbird up finished"
  print_info "Status:"
  netbird status || true
  if [[ $ALLOW_SERVER_SSH -eq 1 ]]; then
    print_warning "Also enable SSH Access on this peer (and a NetBird SSH policy) in the NetBird dashboard"
  fi
else
  print_warning "Skipped netbird up (--no-up)"
  later="netbird up --management-url \"$MANAGEMENT_URL\""
  [[ -n "$SETUP_KEY" ]] && later+=" --setup-key '<your-key>'"
  [[ $ALLOW_SERVER_SSH -eq 1 ]] && later+=" --allow-server-ssh"
  print_info "Later: $later"
fi

echo ""
echo "${BLUE}┌───────────────────────────────┐${RESET}"
echo "${BLUE}│ SUMMARY                       │${RESET}"
echo "${BLUE}└───────────────────────────────┘${RESET}"
echo ""
print_success "Repo configured: $NETBIRD_LIST"
print_success "Installed: netbird"
[[ $INSTALL_UI -eq 1 ]] && print_success "UI: attempted netbird-ui" || print_warning "UI: skipped"
[[ $ENSURE_OPENSSH -eq 1 ]] && print_success "OpenSSH: ensured" || print_warning "OpenSSH: skipped"
[[ $ALLOW_SERVER_SSH -eq 1 ]] && print_success "NetBird SSH: --allow-server-ssh" || print_warning "NetBird SSH: off"
[[ $DO_UP -eq 1 ]] && print_success "Enroll: netbird up attempted" || print_warning "Enroll: skipped"
echo ""
echo "${GREEN}Done.${RESET}"
echo ""
