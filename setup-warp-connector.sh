#!/usr/bin/env bash
#
# Improved Cloudflare WARP (cloudflare-warp) installer for Debian/Ubuntu
# Features:
#   - Root check
#   - Dependency checks & installation
#   - Better error handling
#   - Modern signed-by syntax (no deprecated trusted=yes)
#   - Architecture awareness (amd64 only officially supported)
#   - Post-install instructions
#   - Optional: enable IP forwarding (with confirmation)

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "${GREEN}Cloudflare WARP Installer (improved version)${NC}\n"

# ────────────────────────────────────────────────
# 1. Must run as root
# ────────────────────────────────────────────────
if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}Error: This script must be run as root${NC}"
    echo "Try: sudo bash $0"
    exit 1
fi

# ────────────────────────────────────────────────
# 2. Install required tools if missing
# ────────────────────────────────────────────────
echo "Checking for required tools..."

REQUIRED_PKGS="curl gnupg lsb-release apt-transport-https ca-certificates"

missing=()
for pkg in $REQUIRED_PKGS; do
    if ! dpkg -s "$pkg" &>/dev/null; then
        missing+=("$pkg")
    fi
done

if [[ ${#missing[@]} -gt 0 ]]; then
    echo "Installing missing packages: ${missing[*]}"
    apt-get update -qq
    apt-get install -y --no-install-recommends "${missing[@]}"
    echo -e "${GREEN}Dependencies installed.${NC}"
else
    echo "All required tools are already installed."
fi

# ────────────────────────────────────────────────
# 3. Detect architecture (official support is amd64 / x86_64)
# ────────────────────────────────────────────────
ARCH=$(dpkg --print-architecture)
if [[ "$ARCH" != "amd64" ]]; then
    echo -e "${YELLOW}Warning: Cloudflare WARP officially supports amd64 only.${NC}"
    echo "Detected architecture: $ARCH"
    echo "Installation may fail. Continuing anyway..."
    sleep 3
fi

# ────────────────────────────────────────────────
# 4. Add Cloudflare GPG key
# ────────────────────────────────────────────────
KEYRING="/usr/share/keyrings/cloudflare-warp-archive-keyring.gpg"

echo "Adding Cloudflare GPG key..."
curl -fsSL https://pkg.cloudflareclient.com/pubkey.gpg \
    | gpg --yes --dearmor --output "$KEYRING"

chmod 644 "$KEYRING"

# ────────────────────────────────────────────────
# 5. Add the repository
# ────────────────────────────────────────────────
CODENAME=$(lsb_release -cs 2>/dev/null || echo "unknown")

if [[ "$CODENAME" == "unknown" ]]; then
    echo -e "${RED}Error: Could not determine codename with lsb_release${NC}"
    echo "Falling back to /etc/os-release..."
    . /etc/os-release 2>/dev/null || true
    CODENAME="${VERSION_CODENAME:-${UBUNTU_CODENAME:-}}"
    if [[ -z "$CODENAME" ]]; then
        echo -e "${RED}Failed to detect codename. Cannot continue.${NC}"
        exit 1
    fi
fi

REPO_LINE="deb [arch=amd64 signed-by=$KEYRING] https://pkg.cloudflareclient.com/ $CODENAME main"

LIST_FILE="/etc/apt/sources.list.d/cloudflare-client.list"

echo "Adding repository for $CODENAME ..."
echo "$REPO_LINE" | tee "$LIST_FILE" >/dev/null

# ────────────────────────────────────────────────
# 6. Update package lists & install cloudflare-warp
# ────────────────────────────────────────────────
echo "Updating package index..."
apt-get update

echo "Installing cloudflare-warp..."
if ! apt-get install -y cloudflare-warp; then
    echo -e "${RED}Installation failed.${NC}"
    echo "Possible reasons:"
    echo "  • Your distribution codename ($CODENAME) may not be supported"
    echo "  • Missing dependencies or network issue"
    echo "Check https://pkg.cloudflareclient.com/ for supported releases"
    exit 1
fi

echo -e "${GREEN}cloudflare-warp installed successfully.${NC}"

# ────────────────────────────────────────────────
# 7. Optional: Enable IP forwarding (common for routing setups)
# ────────────────────────────────────────────────
echo
read -p "Do you want to enable IP forwarding (net.ipv4.ip_forward=1)? [y/N] " -n 1 -r
echo
if [[ $REPLY =~ ^[Yy]$ ]]; then
    echo "Enabling IP forwarding..."
    sysctl -w net.ipv4.ip_forward=1

    # Make it persistent
    if grep -q "^#net.ipv4.ip_forward" /etc/sysctl.conf || ! grep -q "net.ipv4.ip_forward" /etc/sysctl.conf; then
        echo "net.ipv4.ip_forward=1" >> /etc/sysctl.conf
        echo -e "${GREEN}IP forwarding enabled persistently.${NC}"
    else
        echo "IP forwarding already configured in sysctl.conf"
    fi
else
    echo "Skipping IP forwarding."
fi

# ────────────────────────────────────────────────
# 8. Final instructions
# ────────────────────────────────────────────────
echo -e "\n${GREEN}Installation complete!${NC}\n"

cat << 'EOF'
Next steps:

1. Register the client:
   warp-cli registration new

2. Connect to WARP:
   warp-cli connect

   (or use one of these modes:)
   warp-cli enable-always-on    # auto-connect on boot
   warp-cli set-mode proxy      # SOCKS5 proxy mode
   warp-cli set-mode tunnel     # tunnel only (no DNS)

3. Verify it's working:
   curl https://www.cloudflare.com/cdn-cgi/trace/

   Look for: warp=on

4. Useful commands:
   warp-cli --help
   warp-cli status
   warp-cli disconnect

For more documentation: https://developers.cloudflare.com/warp-client/get-started/linux/
EOF

echo -e "\n${GREEN}Done!${NC}"
