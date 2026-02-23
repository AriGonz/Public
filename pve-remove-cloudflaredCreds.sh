#!/usr/bin/env bash
# Removes existing Cloudflare Tunnel auth + service setup on Proxmox
# Run as root
#
# Use at your own risk — backup important files first!
# Run: bash -c "$(curl -fsSL https://raw.githubusercontent.com/AriGonz/Public/refs/heads/main/pve-remove-cloudflaredCreds.sh)"


set -euo pipefail

echo "===================================================="
echo "     Cloudflared Reset + Reinstall Script"
echo "===================================================="
echo "This script will:"
echo "  - Stop/uninstall existing cloudflared service & clean credentials"
echo "  - Refresh systemd"
echo "  - Re-add official Cloudflare repo + install/upgrade cloudflared"
echo "  - Refresh systemd again & attempt to start the service"
echo "  - Show instructions to complete setup"
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

# Remove unit files
rm -f /etc/systemd/system/cloudflared.service
rm -f /etc/systemd/system/cloudflared@*.service

# Remove repo file & key (to allow clean reinstall)
rm -f /etc/apt/sources.list.d/cloudflared.list
rm -f /usr/share/keyrings/cloudflare-public-v2.gpg  # old key name you used
rm -f /usr/share/keyrings/cloudflare-main.gpg       # current key name (post-2025 rollover)

# Aggressive credential/config cleanup
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
echo "→ Phase 2: Re-adding Cloudflare repo & installing cloudflared..."

# Use current official key & repo (updated post-2025 rollover)
sudo mkdir -p --mode=0755 /usr/share/keyrings
curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg | sudo tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null

echo 'deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main' | sudo tee /etc/apt/sources.list.d/cloudflared.list

sudo apt-get update -qq
sudo apt-get install --reinstall -y cloudflared

echo "→ cloudflared installed/upgraded (version: $(cloudflared --version 2>/dev/null || echo 'unknown'))"

# ────────────────────────────────────────────────
# Phase 3: Final systemd refresh + start attempt
# ────────────────────────────────────────────────
echo "→ Phase 3: Final systemd refresh & service start..."

systemctl daemon-reload
systemctl reset-failed

systemctl enable cloudflared >/dev/null 2>&1 || true
systemctl restart cloudflared >/dev/null 2>&1 || true

echo "→ Service restart attempted."

# ────────────────────────────────────────────────
# Final user prompt / instructions
# ────────────────────────────────────────────────
echo ""
echo "===================================================="
echo "          RESET & REINSTALL COMPLETE"
echo "===================================================="
echo ""
echo "The service has been reinstalled, but it probably won't connect yet."
echo "To finish the process, do the following manually:"
echo ""
echo "1. Authenticate (if cert.pem is gone):"
echo "   cloudflared tunnel login"
echo "   # → browser opens, log in to Cloudflare"
echo ""
echo "2. Either use a token (recommended for headless):"
echo "   - Go to: https://one.dash.cloudflare.com → Zero Trust → Networks → Tunnels"
echo "   - Select/create tunnel → copy the TOKEN from the install command"
echo "   - Run:"
echo "     sudo cloudflared service install YOUR_TOKEN_HERE"
echo ""
echo "   Or (if using local config / legacy flow):"
echo "     cloudflared service install"
echo "     # (uses existing ~/.cloudflared/cert.pem + config.yml)"
echo ""
echo "3. Check everything:"
echo "   systemctl status cloudflared"
echo "   journalctl -u cloudflared -e -n 80"
echo ""
echo "4. Verify in dashboard:"
echo "   Zero Trust → Networks → Tunnels → check connector 'Healthy'"
echo ""
echo "If issues persist: remove /root/.cloudflared/* and start over with tunnel login."
echo "===================================================="
echo ""

exit 0
