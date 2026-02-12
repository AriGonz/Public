#!/usr/bin/env bash
# =============================================================================
# Synology Active Backup for Business Installer – Ubuntu 24.04
# =============================================================================
# Installs Synology ABB Agent on Ubuntu 24.04
# Main features: Dynamically fetches top 10 versions, user selects via whiptail, downloads & installs
# Idempotent where possible – safe to re-run
# Usage: bash -c "$(curl -fsSL https://raw.githubusercontent.com/AriGonz/Public/refs/heads/main/synology-abb-installer_ubuntu24.04.sh)"
# =============================================================================
echo "V4"





set -euo pipefail

# ──── Colors ─────────────────────────────────────────────────────────────────
if [[ -t 1 ]]; then
    RED=$(tput setaf 1)
    GREEN=$(tput setaf 2)
    YELLOW=$(tput setaf 3)
    BLUE=$(tput setaf 4)
    RESET=$(tput sgr0)
else
    RED="" GREEN="" YELLOW="" BLUE="" RESET=""
fi

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

success() { echo -e "${GREEN}→ $1${RESET}"; }
warning()  { echo -e "${YELLOW}Warning: $1${RESET}"; }
error()    { echo -e "${RED}Error: $1${RESET}"; }

# ─── Install Dependencies ────────────────────────────────────────────────────
for cmd in whiptail curl wget unzip; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
        apt update -qq
        apt install -y "$cmd"
        success "Installed $cmd"
    fi
done

# ──────────────────────────────────────────────────────────────────────────────
# 1. Fetch and Select ABB Version
# ──────────────────────────────────────────────────────────────────────────────
print_section "1" "Fetch and Select ABB Version"

URL="https://archive.synology.com/download/Utility/ActiveBackupBusinessAgent"
UA="Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0.0.0 Safari/537.36"

echo "Fetching directory listing from Synology archive..."

# Try curl first (more reliable timeouts)
HTML=""
if command -v curl >/dev/null 2>&1; then
    echo "  → Trying curl (timeout 60s)..."
    HTML=$(curl -4 -fs --max-time 60 --connect-timeout 15 --user-agent "$UA" "$URL" 2>&1) || true
fi

# Fallback to wget if curl failed/empty
if [ -z "$HTML" ] && command -v wget >/dev/null 2>&1; then
    echo "  → curl failed or returned nothing – trying wget (timeout 60s)..."
    HTML=$(wget -4 -q -O- --timeout=60 --connect-timeout=15 --user-agent="$UA" "$URL" 2>&1) || true
fi

# If still nothing → show clear diagnostics
if [ -z "$HTML" ]; then
    error "Failed to fetch the version list (both curl and wget returned empty/no data)."
    echo ""
    echo "Common causes and fixes:"
    echo "  • No internet / firewall blocking archive.synology.com"
    echo "  • DNS issues (try: ping 8.8.8.8 and nslookup archive.synology.com)"
    echo "  • Corporate/proxy/VPN interference"
    echo ""
    echo "Manual test commands (run these yourself):"
    echo "  curl -I --user-agent \"$UA\" $URL"
    echo "  wget --spider --user-agent=\"$UA\" $URL"
    echo ""
    exit 1
fi

echo "  → Successfully fetched HTML (${#HTML} bytes)"

# Improved parsing for current Synology HTML (href="/.../3.1.0-4967" – no trailing /)
VERSIONS=$(echo "$HTML" | grep -o 'href="[^"]*"' | sed 's/.*href="//;s/"$//' | grep -o '[^/]*$' | grep -E '^\d+\.\d+\.\d+-\d+$' | sort -Vr | head -n 10)

# Hardcoded fallback if parsing produced nothing (e.g. page changed again)
if [ -z "$VERSIONS" ]; then
    warning "Parsing failed – using hardcoded recent versions (may be slightly outdated)"
    VERSIONS="3.1.0-4967 3.1.0-4960 3.1.0-4957 3.1.0-4948 3.0.0-4638 2.7.1-3235 2.7.0-3221 2.6.3-3101 2.6.2-3081 2.6.1-3052"
fi

echo "  → Found versions: $VERSIONS"

# Build whiptail menu
CHOICES=()
for v in $VERSIONS; do
    CHOICES+=("$v" "$v")
done

VERSION=$(whiptail --title "Select Version" --menu "Choose Synology Active Backup for Business Agent version:" 20 70 10 "${CHOICES[@]}" 3>&1 1>&2 2>&3)

if [ $? -ne 0 ] || [ -z "$VERSION" ]; then
    echo "Installation cancelled."
    exit 1
fi

success "Selected version: $VERSION"
sleep 1

# ──────────────────────────────────────────────────────────────────────────────
# 2. Download Package
# ──────────────────────────────────────────────────────────────────────────────
print_section "2" "Download Package"

FILE_NAME="Synology Active Backup for Business Agent-${VERSION}-x64-deb.zip"
DL_URL="https://archive.synology.com/download/Utility/ActiveBackupBusinessAgent/${VERSION}/${FILE_NAME// /%20}"

if [[ -f "$FILE_NAME" ]] && [[ -s "$FILE_NAME" ]]; then
    success "File already exists – skipping download"
else
    echo "Downloading $FILE_NAME ..."
    DOWNLOADED=0

    # Try wget first
    if command -v wget >/dev/null 2>&1; then
        wget -4 -O "$FILE_NAME" --timeout=120 --connect-timeout=30 --user-agent="$UA" "$DL_URL" && DOWNLOADED=1
    fi

    # Fallback to curl
    if [ $DOWNLOADED -eq 0 ] && command -v curl >/dev/null 2>&1; then
        curl -4 -f --max-time 120 --connect-timeout 30 --user-agent "$UA" -o "$FILE_NAME" "$DL_URL" && DOWNLOADED=1
    fi

    if [ $DOWNLOADED -eq 0 ] || [ ! -s "$FILE_NAME" ]; then
        error "Download failed (file empty or missing)."
        echo "Try manually: $DL_URL"
        exit 1
    fi
    success "Download complete"
fi
sleep 1

# ──────────────────────────────────────────────────────────────────────────────
# 3. Extract & Install
# ──────────────────────────────────────────────────────────────────────────────
print_section "3" "Extract and Install"

if [[ -f "install.run" ]]; then
    success "install.run already present – skipping unzip"
else
    echo "Unzipping $FILE_NAME ..."
    unzip "$FILE_NAME"
    if [ $? -ne 0 ]; then
        error "Unzip failed."
        exit 1
    fi
    success "Unzip complete"
fi

echo "Running installer (requires sudo)..."
sudo ./install.run
if [ $? -ne 0 ]; then
    error "Installation failed."
    exit 1
fi
success "Installation completed"
sleep 1

# ──────────────────────────────────────────────────────────────────────────────
# 4. Clean Up
# ──────────────────────────────────────────────────────────────────────────────
print_section "4" "Clean Up"
rm -f "$FILE_NAME" install.run README.txt
success "Temporary files removed"

# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "# ──────────────────────────────────────────────────────────────────────────────"
echo "# Installation Complete – Version $VERSION"
echo "# ──────────────────────────────────────────────────────────────────────────────"
echo ""
