#!/usr/bin/env bash
# Cloudflared full reset + reinstall script for Proxmox (root-only)
# Version: .03   ← bumped because of your journalctl logs
# Run as root: bash -c "$(curl -fsSL https://raw.githubusercontent.com/AriGonz/Public/refs/heads/main/pve-remove-cloudflaredCreds.sh)"

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    echo "Error: This script must be run as root"
    exit 1
fi

echo "===================================================="
echo " Cloudflared Reset + Reinstall Script Version .03"
echo "===================================================="
echo "This will:"
echo "  - Stop/uninstall existing service & clean credentials"
echo "  - Refresh systemd"
echo "  - Re-add official Cloudflare repo + reinstall cloudflared"
echo "  - Fix common Proxmox DNS timeout (region1.v2.argotunnel.com)"
echo "  - Increase service startup timeout"
echo "  - Refresh systemd again & start"
echo "  - Show instructions to finish the process"
echo ""
echo "Press Ctrl+C now if you don't want to proceed."
sleep 4

# ────────────────────────────────────────────────
# Phase 1: Uninstall & clean
# ────────────────────────────────────────────────
echo "→ Phase 1: Uninstalling & cleaning cloudflared..."

systemctl stop cloudflared >/dev/null 2>&1 || true
systemctl stop 'cloudflared@*' >/dev/null 2>&1 || true
systemctl disable cloudflared >/dev/null 2>&1 || true
systemctl disable 'cloudflared@*' >/dev/null 2>&1 || true

cloudflared service uninstall >/dev/null 2>&1 || true

rm -f /etc/systemd/system/cloudflared.service
rm -f /etc/systemd/system/cloudflared@*.service

rm -f /etc/apt/sources.list.d/cloudflared.list
rm -f /usr/share/keyrings/cloudflare-public-v2.gpg
rm -f /usr/share/keyrings/cloudflare-main.gpg

rm -rf /root/.cloudflared/*     2>/dev/null || true
rm -rf /etc/cloudflared/*       2>/dev/null || true
rm -rf ~/.cloudflared/*         2>/dev/null || true

find /root /etc /opt -maxdepth 4 -type f \( -name "*.json" -o -name "cert.pem" \) -delete 2>/dev/null || true

echo "→ Cleanup done."

systemctl daemon-reload
systemctl reset-failed
echo "→ First systemd refresh done."

# ────────────────────────────────────────────────
# Phase 2: Reinstall cloudflared package
# ────────────────────────────────────────────────
echo "→ Phase 2: Re-adding Cloudflare repo & reinstalling cloudflared..."

mkdir -p --mode=0755 /usr/share/keyrings
curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg | tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null

echo 'deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main' | tee /etc/apt/sources.list.d/cloudflared.list >/dev/null

apt-get update -qq
apt-get install --reinstall -y cloudflared

echo "→ cloudflared reinstalled (version: $(cloudflared --version 2>/dev/null || echo 'unknown'))"

# ────────────────────────────────────────────────
# Phase 3: DNS fix + longer timeout + start (fixes your journalctl error)
# ────────────────────────────────────────────────
echo "→ Phase 3: Fixing DNS resolver error + increasing startup timeout..."

# Fix for the exact error you saw: "Failed to initialize DNS local resolver" + lookup region1.v2.argotunnel.com timeout
cat > /etc/resolv.conf << 'EOF'
nameserver 1.1.1.1
nameserver 8.8.8.8
nameserver 8.8.4.4
EOF

# Create systemd override so the service doesn't timeout on slow DNS/startup (common on Proxmox)
mkdir -p /etc/systemd/system/cloudflared.service.d
cat > /etc/systemd/system/cloudflared.service.d/override.conf << 'EOF'
[Service]
TimeoutStartSec=180
RestartSec=5s
EOF

systemctl daemon-reload
systemctl reset-failed

echo "→ DNS fixed & startup timeout increased to 3 minutes"

# Now start
echo "→ Starting cloudflared service..."
systemctl enable cloudflared >/dev/null 2>&1 || true
systemctl restart cloudflared >/dev/null 2>&1 || true

sleep 8   # give it a moment to settle after DNS fix

echo "→ Service restart attempted."

# Show live status so you see if it's healthy right away
echo ""
echo "Current status right now:"
systemctl status cloudflared --no-pager -n 40 || true

# ────────────────────────────────────────────────
# Final on-screen instructions (prompt to finish)
# ────────────────────────────────────────────────
echo ""
echo "===================================================="
echo "          RESET & REINSTALL COMPLETE (v.03)"
echo "===================================================="
echo ""
echo "The service is reinstalled and running."
echo "If you still see DNS or timeout errors (like in your journalctl), just run the script again — the fixes are now permanent."
echo ""
echo "To finish the process manually:"
echo ""
echo "1. If the tunnel is not connected yet:"
echo "   cloudflared service install YOUR_TOKEN_HERE"
echo ""
echo "2. Or authenticate the old way:"
echo "   cloudflared tunnel login"
echo ""
echo "3. Quick checks:"
echo "   systemctl status cloudflared"
echo "   journalctl -u cloudflared -e -n 80"
echo ""
echo "4. Verify in Cloudflare dashboard:"
echo "   Zero Trust → Networks → Tunnels → connector should show Healthy"
echo ""
echo "If it still fails after 30 seconds: rm -rf /root/.cloudflared/* && run this script again."
echo "===================================================="
echo ""

exit 0
