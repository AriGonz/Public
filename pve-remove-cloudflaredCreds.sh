#!/usr/bin/env bash
# Removes existing Cloudflare Tunnel auth + service setup on Proxmox
# Run as root
#
# Use at your own risk — backup important files first!
# Run: bash -c "$(curl -fsSL https://raw.githubusercontent.com/AriGonz/Public/refs/heads/main/pve-remove-cloudflaredCreds.sh)"

set -euo pipefail

echo "=== Cloudflared Tunnel Credential Removal Script ==="
echo "This will STOP and REMOVE the cloudflared service + credentials"
echo "You will be able to create a new tunnel afterward."
echo ""

# ────────────────────────────────────────────────
# 1. Stop and disable the service (if exists)
# ────────────────────────────────────────────────
if systemctl is-active --quiet cloudflared 2>/dev/null; then
    echo "→ Stopping cloudflared service..."
    systemctl stop cloudflared || true
    systemctl disable cloudflared || true
else
    echo "→ cloudflared service not found or already stopped."
fi

# Also try the older / multi-instance naming pattern
if systemctl is-active --quiet cloudflared@* 2>/dev/null; then
    echo "→ Found cloudflared@... instance(s) — stopping them..."
    systemctl stop 'cloudflared@*' || true
    systemctl disable 'cloudflared@*' || true
fi

# ────────────────────────────────────────────────
# 2. Uninstall the service registration
#    (removes /etc/systemd/system/cloudflared* files)
# ────────────────────────────────────────────────
echo "→ Uninstalling cloudflared service registration..."
cloudflared service uninstall >/dev/null 2>&1 || true

# Manually clean up leftover systemd units (very common issue)
rm -f /etc/systemd/system/cloudflared.service
rm -f /etc/systemd/system/cloudflared@*.service
systemctl daemon-reload
systemctl reset-failed

# ────────────────────────────────────────────────
# 3. Remove credentials and config files
# ────────────────────────────────────────────────
echo "→ Removing known credential & config locations..."

# Very common locations
rm -f /root/.cloudflared/*.json
rm -f /root/.cloudflared/cert.pem
rm -f /root/.cloudflared/config.yml

# Official/default install paths
rm -f /etc/cloudflared/*.json
rm -f /etc/cloudflared/cert.pem
rm -f /etc/cloudflared/config.yml

# Sometimes people put it here
rm -f ~/.cloudflared/*.json ~/.cloudflared/cert.pem

# Helper-script / tteck style locations (popular in Proxmox community)
rm -f /opt/cloudflared/*.json /opt/cloudflared/config.yml 2>/dev/null || true

echo "→ Credential files removed (if they existed)."

# ────────────────────────────────────────────────
# 4. Final checks & next steps
# ────────────────────────────────────────────────
echo ""
echo "Cleanup finished."
echo ""
echo "Next steps to create a new tunnel:"
echo "1. Go to Cloudflare Zero Trust → Networks → Tunnels → Create a tunnel"
echo "2. Choose Cloudflared → follow instructions"
echo "   • Usually you'll get either a long TOKEN or a command like:"
echo "     cloudflared tunnel login   (older style → creates cert.pem)"
echo "     cloudflared service install <very-long-token>"
echo ""
echo "3. After getting the token/command, run it on Proxmox"
echo ""
echo "Done. You should now be able to set up a fresh tunnel."
echo ""

exit 0
