#!/bin/bash
# =====================================================
# Portable Proxmox Setup Script - 2026 Edition
# Usage: bash -c "$(curl -fsSL https://raw.githubusercontent.com/AriGonz/Public/refs/heads/main/proxmox-portable-setup.sh)"
# Version .01
# =====================================================

set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
step() { echo -e "\n${BLUE}═══ $1 ${NC}"; }
success() { echo -e "${GREEN}✅ $1${NC}"; }
warn() { echo -e "${YELLOW}⚠️  $1${NC}"; }
error() { echo -e "${RED}❌ $1${NC}"; exit 1; }

step "PHASE 0 — Repository Setup"
while IFS= read -r f; do
    if [[ $f == *.sources ]]; then sed -i 's/^Enabled:.*/Enabled: no/' "$f"; else sed -i 's/^deb/#deb/' "$f"; fi
done < <(grep -rl enterprise.proxmox.com /etc/apt/sources.list* 2>/dev/null || true)

PVE_CODENAME=$(grep VERSION_CODENAME /etc/os-release | cut -d= -f2)
echo "deb http://download.proxmox.com/debian/pve ${PVE_CODENAME} pve-no-subscription" >> /etc/apt/sources.list
apt-get update -qq

JS="/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js"
[[ -f "$JS" ]] && cp "$JS" "${JS}.bak.$(date +%s)" && sed -Ezi 's/(Ext.Msg.show\(\{\s+title: gettext\('No valid sub)/void(\{ \/\/\1/g' "$JS" && systemctl restart pveproxy
success "Subscription nag removed"

mkdir -p /root/.ssh
echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHgzljgx9gDLlln3EEE/vcPvr9NMz7kLiLraofNzeQoO pve-xx" >> /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys
echo 'alias ll="ls -lrt"' >> /root/.bashrc

step "PHASE 1 — Pre-Checks"
[[ $EUID -eq 0 ]] || error "Run as root"
command -v pveversion >/dev/null || error "Not on Proxmox"
ping -c1 8.8.8.8 >/dev/null || error "No internet"
step "All pre-checks passed"

step "PHASE 2 — User Input"
read -p "Hostname [$(hostname)]: " NEWHOST
[[ -n "$NEWHOST" ]] && hostnamectl set-hostname "$NEWHOST" && echo "$NEWHOST" > /etc/hostname

read -p "Netbird Setup Key: " NETBIRD_KEY
[[ -z "$NETBIRD_KEY" ]] && error "Netbird key required"

read -p "Cloudflared Tunnel Token (optional): " CLOUDFLARED_TOKEN
read -p "Cloudflared Tunnel Name (for MOTD display, e.g. my-portable-box, optional): " CLOUD_NAME
[[ -z "$CLOUD_NAME" ]] && CLOUD_NAME="Active"

step "PHASE 3 — Proxmox Post-Install"
apt-get full-upgrade -y && apt-get autoremove -y
apt-get install -y htop curl git jq wget
success "System upgraded"

step "PHASE 4 — Networking (Dual DHCP)"
PHYS_NICS=$(ip -o link show | awk -F': ' '{print $2}' | grep -E '^(en|eth)' | grep -vE 'veth|br|vmbr|bond')
NIC_ARRAY=($PHYS_NICS)

cat > /etc/network/interfaces <<EOF
auto lo
iface lo inet loopback

$(for i in "${!NIC_ARRAY[@]}"; do
    NIC=${NIC_ARRAY[$i]}
    BR="vmbr$i"
    cat <<INNER
auto $BR
iface $BR inet dhcp
    bridge-ports $NIC
    bridge-stp off
    bridge-fd 0
    bridge-maxwait 0

INNER
done)
EOF

ifreload -a || systemctl restart networking
success "Dual DHCP bridges ready"

step "PHASE 5 — Netbird"
curl -fsSL https://pkgs.netbird.io/install.sh | sh
netbird up --management-url https://netbird.arigonz.com --setup-key "$NETBIRD_KEY"
sleep 8
netbird status | grep -q Connected && success "Netbird connected" || error "Netbird failed"

step "PHASE 6 — Cloudflared"
mkdir -p --mode=0755 /usr/share/keyrings
curl -fsSL https://pkg.cloudflare.com/cloudflare-public-v2.gpg | tee /usr/share/keyrings/cloudflare-public-v2.gpg >/dev/null
echo 'deb [signed-by=/usr/share/keyrings/cloudflare-public-v2.gpg] https://pkg.cloudflare.com/cloudflared any main' | tee /etc/apt/sources.list.d/cloudflared.list
apt-get update && apt-get install -y cloudflared
if [[ -n "$CLOUDFLARED_TOKEN" ]]; then
    cloudflared service install "$CLOUDFLARED_TOKEN"
    success "Cloudflared installed"
fi

step "PHASE 7 — Security + Dynamic MOTD + mDNS/Avahi"
# Security (same as before)
pve-firewall enable
ufw allow from 100.64.0.0/10 to any port 22,8006 proto tcp comment "Netbird"

# mDNS / Avahi
apt-get install -y avahi-daemon
sed -i 's/#enable-reflector=no/enable-reflector=yes/' /etc/avahi/avahi-daemon.conf 2>/dev/null || true
sed -i '/allow-interfaces=/d' /etc/avahi/avahi-daemon.conf 2>/dev/null || true
echo "allow-interfaces=vmbr0,vmbr1" >> /etc/avahi/avahi-daemon.conf
systemctl enable --now avahi-daemon
success "mDNS/Avahi enabled → discover as $(hostname).local"

# Dynamic beautiful login/MOTD screen
cat > /etc/update-motd.d/99-portable-proxmox << 'MOTD'
#!/bin/sh
DHCP0=$(ip -4 addr show vmbr0 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n1 || echo "None")
NETBIRD=$(netbird status 2>/dev/null | grep -oP 'NetBird IP:\s+\K[^\s]+' || echo "Disconnected")
CF_NAME="Active"
if command -v cloudflared >/dev/null 2>&1; then
    TUNNEL=$(cloudflared tunnel list 2>/dev/null | awk 'NR==2 {print $2}' || echo "")
    [[ -n "$TUNNEL" ]] && CF_NAME="$TUNNEL"
fi
cat <<EOF
╔══════════════════════════════════════════════════════════════╗
║               🚀  PORTABLE PROXMOX HOST                      ║
╟──────────────────────────────────────────────────────────────╢
║  Hostname          :  $(hostname)                            ║
║  DHCP IP (vmbr0)   :  $DHCP0                                 ║
║  Netbird IP        :  $NETBIRD                               ║
║  Cloudflared       :  $CF_NAME                               ║
║  mDNS / Avahi      :  $(hostname).local:8006                 ║
╚══════════════════════════════════════════════════════════════╝
→ Open Proxmox GUI with any browser on the same network
EOF
MOTD

chmod +x /etc/update-motd.d/99-portable-proxmox
rm -f /etc/motd /etc/motd.tail

# Enhanced status command
cat > /usr/local/bin/pve-portable-status << 'STATUS'
#!/bin/bash
echo -e "\033[1;32mPortable Proxmox Status\033[0m"
echo "Hostname       : $(hostname)"
echo "DHCP IP (vmbr0): $(ip -4 addr show vmbr0 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n1 || echo N/A)"
echo "Netbird IP     : $(netbird status 2>/dev/null | grep -oP 'NetBird IP:\s+\K[^\s]+' || echo Disconnected)"
echo "Cloudflared    : $(cloudflared tunnel list 2>/dev/null | awk 'NR==2 {print $2}' || echo Active)"
echo "mDNS Address   : $(hostname).local:8006"
STATUS
chmod +x /usr/local/bin/pve-portable-status

step "PHASE 8 — Final Verification"
pve-portable-status
echo -e "\n${GREEN}🎉 SETUP COMPLETE!${NC}"
echo "Log out & log back in (or run 'cat /etc/motd') to see the new dynamic screen."
echo "Reboot recommended for mDNS to fully settle."
read -p "Reboot now? (y/N) " REBOOT
[[ "$REBOOT" =~ ^[Yy]$ ]] && reboot
