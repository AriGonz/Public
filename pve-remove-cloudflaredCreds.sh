#!/usr/bin/env bash
# Removes existing Cloudflare Tunnel auth + service setup on Proxmox
# Run as root
#
# Use at your own risk — backup important files first!
# Run: bash -c "$(curl -fsSL https://raw.githubusercontent.com/AriGonz/Public/refs/heads/main/pve-remove-cloudflaredCreds.sh)"
# Flow: Uninstall & clean → systemd refresh → Reinstall package (official repo) → systemd refresh + start → final instructions

set -euo pipefail
echo "===================================================="
echo "     Version .01
echo "===================================================="



echo "===================================================="
echo "     Cloudflared Reset + Reinstall Script (Root)"
echo "===================================================="
echo "This will:"
echo "  - Stop/uninstall existing service & clean credentials"
echo "  - Refresh systemd"
echo "  - Re-add official Cloudflare repo + reinstall cloudflared"
echo "  - Refresh systemd again & attempt to start"
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

# Remove unit files
rm -f /etc/systemd/system/cloudflared.service
rm -f /etc/systemd/system/cloudflared@*.service

# Remove repo files & keys (both old and current names)
rm -f /etc/apt/sources.list.d/cloudflared.list
rm -f /usr/share/keyrings/cloudflare-public-v2.gpg
rm -f /usr/share/keyrings/cloudflare-main.gpg

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
# Phase 2: Reinstall cloudflared package (official method, no sudo)
# ────────────────────────────────────────────────
echo "→ Phase 2: Re-adding Cloudflare repo & reinstalling cloudflared..."

mkdir -p --mode=0755 /usr/share/keyrings
curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg | tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null

echo 'deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main' | tee /etc/apt/sources.list.d/cloudflared.list

apt-get update -qq
apt-get install --reinstall -y cloudflared

echo "→ cloudflared reinstalled (version: $(cloudflared --version 2>/dev/null || echo 'unknown'))"

# ────────────────────────────────────────────────
# Phase 3: Final systemd refresh + start
# ────────────────────────────────────────────────
echo "→ Phase 3: Final systemd refresh & service start..."

systemctl daemon-reload
systemctl reset-failed

systemctl enable cloudflared >/dev/null 2>&1 || true
systemctl restart cloudflared >/dev/null 2>&1 || true

echo "→ Service restart attempted."

# ────────────────────────────────────────────────
# Final on-screen instructions (the only "prompt")
# ────────────────────────────────────────────────
echo ""
echo "===================================================="
echo "          RESET & REINSTALL COMPLETE"
echo "===================================================="
echo ""
echo "The service is reinstalled and running, but it probably needs authentication."
echo "To finish the process manually:"
echo ""
echo "1. Authenticate with Cloudflare (if needed):"
echo "   cloudflared tunnel login"
echo "   # (browser will open → log in)"
echo ""
echo "2. Set up the tunnel (you choose one):"
echo ""
echo "   OPTION A – Token (recommended, headless):"
echo "     • Go to: https://one.dash.cloudflare.com → Zero Trust → Networks → Tunnels"
echo "     • Create or select tunnel → copy the TOKEN"
echo "     • Run:  cloudflared service install YOUR_TOKEN_HERE"
echo ""
echo "   OPTION B – Legacy (uses cert.pem):"
echo "     cloudflared service install"
echo ""
echo "3. Check status:"
echo "   systemctl status cloudflared"
echo "   journalctl -u cloudflared -e -n 80"
echo ""
echo "4. Verify in Cloudflare dashboard:"
echo "   Zero Trust → Networks → Tunnels → connector should show Healthy"
echo ""
echo "If it still fails: rm -rf /root/.cloudflared/* and repeat from step 1."
echo "===================================================="
echo ""

exit 0
