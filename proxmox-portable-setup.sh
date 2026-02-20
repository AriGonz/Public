#!/bin/bash
# =====================================================
# Portable Proxmox Setup Script - 2026 Edition
# Version .03
# Usage: bash -c "$(curl -fsSL https://raw.githubusercontent.com/AriGonz/Public/refs/heads/main/proxmox-portable-setup.sh)"
# =====================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'
step() { echo -e "\n${BLUE}═══ $1 ${NC}"; }
success() { echo -e "${GREEN}✅ $1${NC}"; }
warn() { echo -e "${YELLOW}⚠️  $1${NC}"; }
error() { echo -e "${RED}❌ $1${NC}"; exit 1; }

# ── Pre-checks ─────────────────────────────────────
[[ $EUID -eq 0 ]] || error "Run as root"
command -v pveversion >/dev/null || error "This is not Proxmox VE"
ping -c1 8.8.8.8 >/dev/null 2>&1 || error "No internet"
PVE_VER=$(pveversion | cut -d/ -f2)
step "All pre-checks passed (Proxmox VE ${PVE_VER})"

# ── PHASE 0 — Repository Setup ─────────────────────
step "PHASE 0 — Repository Setup"

echo "→ Disabling enterprise repositories..."
find /etc/apt -name "*.list" -o -name "*.sources" 2>/dev/null | xargs -r grep -l "enterprise.proxmox.com" 2>/dev/null | while read -r f; do
    if [[ $f == *.sources ]]; then
        sed -i '/^Types:/i Enabled: no' "$f" 2>/dev/null || true
        sed -i 's/^Enabled:.*/Enabled: no/' "$f" 2>/dev/null || true
    else
        sed -i 's/^\(deb.*enterprise.proxmox.com\)/#\1/' "$f"
    fi
done

PVE_CODENAME=$(grep VERSION_CODENAME /etc/os-release | cut -d= -f2)

echo "→ Adding no-subscription repo (deb822 format for PVE 9)..."
cat > /etc/apt/sources.list.d/pve-no-subscription.sources <<EOF
Types: deb
URIs: http://download.proxmox.com/debian/pve
Suites: ${PVE_CODENAME}
Components: pve-no-subscription
Enabled: yes
EOF

echo "→ Running apt update (first run can take 30-90s)..."
apt-get update -q
success "Repos configured"

# ── PHASE 1 — Subscription Nag Removal ─────────────
step "PHASE 1 — Remove Subscription Nag"
JS="/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js"

if [[ -f "$JS" ]]; then
    echo "→ Backing up and patching JS file..."
    cp "$JS" "${JS}.bak.$(date +%s)"
    sed -Ezi 's/(Ext\.Msg\.show\(\{\s*title:\s*gettext\([^)]*No valid sub)/void(\{ \/\/\1/g' "$JS"
    
    echo "→ Restarting pveproxy (this takes 10-40 seconds on fresh 9.1.1 — please wait)..."
    systemctl restart pveproxy.service
    sleep 5
    if systemctl is-active --quiet pveproxy.service; then
        success "Subscription nag removed"
    else
        warn "pveproxy restart failed — run 'journalctl -u pveproxy -e' if GUI still shows nag"
    fi
else
    warn "proxmoxlib.js not found — skipping nag removal"
fi

# ── Quick convenience bits ─────────────────────────
mkdir -p /root/.ssh
echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHgzljgx9gDLlln3EEE/vcPvr9NMz7kLiLraofNzeQoO pve-xx" >> /root/.ssh/authorized_keys 2>/dev/null || true
chmod 600 /root/.ssh/authorized_keys 2>/dev/null || true
echo 'alias ll="ls -la --color=auto"' >> /root/.bashrc

# ── PHASE 2 — User Input ───────────────────────────
step "PHASE 2 — Configuration"
read -p "Hostname [$(hostname)]: " NEWHOST
[[ -n "$NEWHOST" ]] && hostnamectl set-hostname "$NEWHOST" && echo "$NEWHOST" > /etc/hostname && success "Hostname updated"

read -p "Netbird Setup Key (required): " NETBIRD_KEY
[[ -z "$NETBIRD_KEY" ]] && error "Netbird key is required"

read -p "Cloudflared Tunnel Token (optional — press Enter to skip): " CLOUDFLARED_TOKEN
read -p "Cloudflared Tunnel Name (optional): " CLOUD_NAME
[[ -z "$CLOUD_NAME" ]] && CLOUD_NAME="Portable-Box"

# ── PHASE 3 — Upgrade + Tools ──────────────────────
step "PHASE 3 — System Upgrade & Tools"
export DEBIAN_FRONTEND=noninteractive
apt-get full-upgrade -y -o Dpkg::Options::="--force-confdef" -o Dpkg::Options::="--force-confold"
apt-get install -y htop curl git jq wget net-tools ufw avahi-daemon
success "System upgraded + essential tools installed"

# ── PHASE 4 — Networking ───────────────────────────
step "PHASE 4 — Networking (Dual DHCP)"
read -p "Overwrite /etc/network/interfaces with DHCP bridges on ALL physical NICs? (y/N): " CONFIRM
if [[ "$CONFIRM" =~ ^[Yy]$ ]]; then
    cp /etc/network/interfaces /etc/network/interfaces.bak.$(date +%s) 2>/dev/null || true
    PHYS_NICS=$(ip -o link show | awk -F': ' '{print $2}' | grep -E '^(en|eth)' | grep -vE 'veth|br|vmbr|bond|lo')
    {
        echo "auto lo"
        echo "iface lo inet loopback"
        echo
        i=0
        for NIC in $PHYS_NICS; do
            BR="vmbr$i"
            echo "auto $BR"
            echo "iface $BR inet dhcp"
            echo "    bridge-ports $NIC"
            echo "    bridge-stp off"
            echo "    bridge-fd 0"
            echo
            ((i++))
        done
    } > /etc/network/interfaces
    ifreload -a 2>/dev/null || systemctl restart networking
    success "Network bridges created (vmbr0, vmbr1...)"
else
    success "Network config left unchanged"
fi

# ── PHASE 5 — Netbird ──────────────────────────────
step "PHASE 5 — Netbird"
curl -fsSL https://pkgs.netbird.io/install.sh | sh
netbird up --management-url https://netbird.arigonz.com --setup-key "$NETBIRD_KEY"
sleep 10
netbird status | grep -q "Connected" && success "Netbird connected" || error "Netbird failed to connect"

# ── PHASE 6 — Cloudflared ──────────────────────────
step "PHASE 6 — Cloudflared"
mkdir -p --mode=0755 /usr/share/keyrings
curl -fsSL https://pkg.cloudflare.com/cloudflare-public-v2.gpg | tee /usr/share/keyrings/cloudflare-public-v2.gpg >/dev/null
echo 'deb [signed-by=/usr/share/keyrings/cloudflare-public-v2.gpg] https://pkg.cloudflare.com/cloudflared any main' > /etc/apt/sources.list.d/cloudflared.list
apt-get update && apt-get install -y cloudflared
if [[ -n "$CLOUDFLARED_TOKEN" ]]; then
    cloudflared service install "$CLOUDFLARED_TOKEN"
    success "Cloudflared tunnel installed"
else
    success "Cloudflared installed (no tunnel token provided)"
fi

# ── PHASE 7 — Security + MOTD ──────────────────────
step "PHASE 7 — Security + Dynamic MOTD"
ufw --force reset
ufw allow from 100.64.0.0/10 to any port 22 proto tcp comment "Netbird SSH"
ufw allow from 100.64.0.0/10 to any port 8006 proto tcp comment "Netbird GUI"
ufw --force enable

# mDNS
sed -i 's/#enable-reflector=no/enable-reflector=yes/' /etc/avahi/avahi-daemon.conf 2>/dev/null || true
sed -i '/allow-interfaces=/d' /etc/avahi/avahi-daemon.conf 2>/dev/null || true
echo "allow-interfaces=vmbr0,vmbr1" >> /etc/avahi/avahi-daemon.conf
systemctl enable --now avahi-daemon

# Beautiful dynamic MOTD
cat > /etc/update-motd.d/99-portable-proxmox << 'MOTD'
#!/bin/sh
DHCP0=$(ip -4 addr show vmbr0 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n1 || echo "None")
NETBIRD=$(netbird status 2>/dev/null | grep -oP 'NetBird IP:\s+\K[^\s]+' || echo "Disconnected")
CF_NAME="None"
command -v cloudflared >/dev/null && CF_NAME=$(cloudflared tunnel list 2>/dev/null | awk 'NR==2 {print $2}' || echo "Active")
cat <<EOF
╔══════════════════════════════════════════════════════════════╗
║               🚀  PORTABLE PROXMOX HOST                      ║
╟──────────────────────────────────────────────────────────────╢
║  Hostname          :  $(hostname)                            ║
║  DHCP IP (vmbr0)   :  $DHCP0                                 ║
║  Netbird IP        :  $NETBIRD                               ║
║  Cloudflared       :  $CF_NAME                               ║
║  mDNS              :  $(hostname).local:8006                 ║
╚══════════════════════════════════════════════════════════════╝
EOF
MOTD
chmod +x /etc/update-motd.d/99-portable-proxmox
rm -f /etc/motd /etc/motd.tail

# Status command
cat > /usr/local/bin/pve-status << 'STATUS'
#!/bin/bash
echo -e "\033[1;32mPortable Proxmox Status\033[0m"
echo "Hostname       : $(hostname)"
echo "DHCP IP (vmbr0): $(ip -4 addr show vmbr0 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n1 || echo N/A)"
echo "Netbird IP     : $(netbird status 2>/dev/null | grep -oP 'NetBird IP:\s+\K[^\s]+' || echo Disconnected)"
echo "Cloudflared    : $(cloudflared tunnel list 2>/dev/null | awk 'NR==2 {print $2}' 2>/dev/null || echo None)"
echo "mDNS           : $(hostname).local:8006"
STATUS
chmod +x /usr/local/bin/pve-status

# ── PHASE 8 — Final Verification ───────────────────
step "PHASE 8 — Final Verification"
pve-status
echo -e "\n${GREEN}🎉 SETUP COMPLETE!${NC}"
echo "→ Run 'pve-status' anytime for this summary"
echo "→ Reboot recommended for full mDNS / network settling"
read -p "Reboot now? (y/N): " REBOOT
[[ "$REBOOT" =~ ^[Yy]$ ]] && reboot
