#!/usr/bin/env bash
# =============================================================================
# Synology Active Backup for Business Installer – Ubuntu 24.04
# =============================================================================
# Installs Synology ABB Agent on Ubuntu 24.04
# Main features: Dynamically fetches top 10 versions, user selects via whiptail, downloads & installs
# Idempotent where possible – safe to re-run
# Usage: bash -c "$(curl -fsSL https://raw.githubusercontent.com/AriGonz/Public/refs/heads/main/synology-abb-installer_ubuntu24.04.sh)"
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
DEFAULT_VERSION=""  # No default – user must select

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

# ─── Install Dependencies ────────────────────────────────────────────────────
# Install whiptail if not present
if ! command -v whiptail >/dev/null 2>&1; then
    apt update -qq
    apt install -y whiptail
    success "Installed whiptail for interactive input"
fi

# Install curl if not present
if ! command -v curl >/dev/null 2>&1; then
    apt update -qq
    apt install -y curl
    success "Installed curl for fetching versions"
fi

# Install wget if not present
if ! command -v wget >/dev/null 2>&1; then
    apt update -qq
    apt install -y wget
    success "Installed wget for downloading packages"
fi

# Install unzip if not present
if ! command -v unzip >/dev/null 2>&1; then
    apt update -qq
    apt install -y unzip
    success "Installed unzip for extracting packages"
fi

# No multi-section selection – single-purpose script
# Proceed directly

# ──────────────────────────────────────────────────────────────────────────────
# 1. Fetch and Select ABB Version
# ──────────────────────────────────────────────────────────────────────────────
print_section "1" "Fetch and Select ABB Version"

echo "Fetching available versions from Synology archive..."
VERSIONS=$(curl -fs -m 30 --user-agent "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0.0.0 Safari/537.36" https://archive.synology.com/download/Utility/ActiveBackupBusinessAgent | grep -o 'href="[^/]\+/"' | sed 's/href="//;s/\/"//' | grep -E '^\d+\.\d+\.\d+-\d+$' | sort -Vr | head -n 10)

if [ -z "$VERSIONS" ]; then
    warning "Failed to fetch versions – check internet connection or URL"
    exit 1
fi

# Build choices for whiptail menu
CHOICES=()
for v in $VERSIONS; do
    CHOICES+=("$v" "$v")
done

VERSION=$(whiptail --title "Select Version" --menu "Choose a version of Synology Active Backup for Business Agent:" 20 60 10 "${CHOICES[@]}" 3>&1 1>&2 2>&3)

exitstatus=$?
if [ $exitstatus != 0 ]; then
    echo "Installation cancelled."
    exit 1
fi

if [ -z "$VERSION" ]; then
    warning "No version selected – exiting"
    exit 1
fi

success "Version selected: $VERSION"
sleep 1

# ──────────────────────────────────────────────────────────────────────────────
# 2. Download ABB Package
# ──────────────────────────────────────────────────────────────────────────────
print_section "2" "Download ABB Package"

FILE_NAME="Synology Active Backup for Business Agent-${VERSION}-x64-deb.zip"
URL="https://archive.synology.com/download/Utility/ActiveBackupBusinessAgent/${VERSION}/${FILE_NAME// /%20}"

if [[ -f "$FILE_NAME" ]]; then
    success "File already exists – skipping download"
else
    echo "Downloading ${FILE_NAME} from ${URL}..."
    wget -O "${FILE_NAME}" "${URL}"
    if [ $? -ne 0 ]; then
        warning "Failed to download the file. Please check the version and try again."
        exit 1
    fi
    success "Download complete"
fi
sleep 1

# ──────────────────────────────────────────────────────────────────────────────
# 3. Extract and Install
# ──────────────────────────────────────────────────────────────────────────────
print_section "3" "Extract and Install"

if [[ -f "install.run" ]]; then
    success "Extracted files exist – skipping unzip"
else
    echo "Unzipping ${FILE_NAME}..."
    unzip "${FILE_NAME}"
    if [ $? -ne 0 ]; then
        warning "Failed to unzip the file."
        exit 1
    fi
    success "Unzip complete"
fi

echo "Installing the agent..."
sudo ./install.run
if [ $? -ne 0 ]; then
    warning "Installation failed."
    exit 1
fi

success "Installation completed"
sleep 1

# ──────────────────────────────────────────────────────────────────────────────
# 4. Clean Up
# ──────────────────────────────────────────────────────────────────────────────
print_section "4" "Clean Up"

rm -f "${FILE_NAME}" install.run README.txt
success "Cleaned up temporary files"

# ──────────────────────────────────────────────────────────────────────────────
# Finish
# ──────────────────────────────────────────────────────────────────────────────
echo ""
echo "# ──────────────────────────────────────────────────────────────────────────────"
echo "# Installation Complete"
echo "# ──────────────────────────────────────────────────────────────────────────────"
echo ""
echo "Synology Active Backup for Business Agent v$VERSION installed successfully."
