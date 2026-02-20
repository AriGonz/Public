#!/bin/bash
# =====================================================
# Portable Proxmox Setup Script - 2026 Edition
# Usage: bash -c "$(curl -fsSL https://raw.githubusercontent.com/AriGonz/Public/refs/heads/main/proxmox-portable-setup.sh)"
# Version .11
# =====================================================

set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

# ── Version Banner + Important Warning ─────────────
echo -e "\n${BLUE}══════════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}   Portable Proxmox Setup Script  —  v0.11${NC}"
echo -e "${BLUE}══════════════════════════════════════════════════════════════${NC}\n"

echo -e "${YELLOW}SECURITY NOTE: This script adds a hardcoded SSH public key to root.${NC}"
echo -e "${YELLOW}Only use on trusted/personal devices. Edit/remove if not desired.${NC}\n"

step() { echo -e "\n${BLUE}═══ $1 ${NC}"; }
success() { echo -e "${GREEN}Success $1${NC}"; }
warn() { echo -e "${YELLOW}Warning $1${NC}"; }
error() { echo -e "${RED}Error $1${NC}"; exit 1; }

# Pre-checks
[[ $EUID -eq 0 ]] || error "Run as root"
command -v pveversion >/dev/null || error "Not on Proxmox"
ping -c1 8.8.8.8 >/dev/null 2>&1 || error "No internet"
step "All pre-checks passed"

step "PHASE 0 — Repository Setup"
while IFS= read -r f; do
    if [[ $f == *.sources ]]; then
        if grep -q '^Enabled:' "$f"; then
            sed -i 's/^Enabled:.*/Enabled: no/' "$f"
        else
            sed -i '/^Types:/i Enabled: no' "$f"
        fi
    else
        sed -i 's/^deb/#deb/' "$f"
    fi
done < <(grep -rl enterprise.proxmox.com /etc/apt/sources.list* 2>/dev/null || true)

PVE_CODENAME=$(grep VERSION_CODENAME /etc/os-release | cut -d= -f2)
if ! grep -q 'pve-no-subscription' /etc/apt/sources.list 2>/dev/null; then
    echo "deb http://download.proxmox.com/debian/pve ${PVE_CODENAME} pve-no-subscription" >> /etc/apt/sources.list
fi
apt-get update -qq
success "Repos configured"

# PHASE 1 — Nag removal
JS="/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js"
if [[ -f "$JS" ]]; then
    cp "$JS" "${JS}.bak.$(date +%s)" 2>/dev/null || true
    sed -Ezi 's/(Ext\.Msg\.show\(\{\s+title: gettext\(.No valid sub)/void(\{ \/\/\1/g' "$JS"
    echo "→ Restarting pveproxy..."
    systemctl stop pveproxy 2>/dev/null || true; sleep 2; pkill -9 -f pveproxy 2>/dev/null || true
    systemctl start pveproxy
    success "Subscription nag removed"
fi

mkdir -p /root/.ssh
echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHgzljgx9gDLlln3EEE/vcPvr9NMz7kLiLraofNzeQoO pve-xx" >> /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys
echo 'alias ll="ls -lrt"' >> /root/.bashrc

step "PHASE 2 — User Input"
read -p "Hostname [$(hostname)]: " NEWHOST
[[ -n "$NEWHOST" ]] && hostnamectl set-hostname "$NEWHOST" && echo "$NEWHOST" > /etc/hostname

read -p "Netbird Setup Key: " NETBIRD_KEY
[[ -z "$NETBIRD_KEY" ]] && error "Netbird key required"

read -p "Cloudflared Tunnel Token (optional): " CLOUDFLARED_TOKEN

step "PHASE 3 — Proxmox Post-Install"
apt-get full-upgrade -y && apt-get autoremove -y
apt-get install -y htop curl git jq wget ufw
success "System upgraded"

step "PHASE 4 — Networking (Dual DHCP)"
# Idempotency check
if grep -q '^auto vmbr0' /etc/network/interfaces 2>/dev/null && grep -q '^auto vmbr1' /etc/network/interfaces 2>/dev/null; then
    warn "vmbr0 and vmbr1 already appear in /etc/network/interfaces — skipping network rewrite"
else
    echo -e "${RED}Warning CRITICAL WARNING — SSH WILL DROP${NC}"
    echo -e "${RED}This will overwrite /etc/network/interfaces and apply new config.${NC}"
    echo -e "${RED}You will lose this SSH session immediately.${NC}"
    echo -e "${RED}Reconnect using the new DHCP IP on vmbr0 (check your router).${NC}"
    read -p "Continue and accept disconnect? (y/N): " CONFIRM
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        warn "Networking skipped — continuing without change"
    else
        cp /etc/network/interfaces "/etc/network/interfaces.bak.$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true

        # Improved NIC detection: modern names (ens, eno, enp, end, enx, etc.)
        PHYS_NICS=$(ip -o link show up | awk -F': ' '{print $2}' | grep '^e' | grep -vE '^(lo|docker|br|vmbr|veth|bond|wg|virbr|tun|tap)' | sort -u)
        NIC_ARRAY=($PHYS_NICS)

        if [ ${#NIC_ARRAY[@]} -eq 0 ]; then
            warn "No physical ethernet interfaces detected — skipping bridge creation"
        else
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
            echo "Applying network config..."
            if command -v ifreload >/dev/null 2>&1; then
                ifreload -a || true
            else
                warn "'ifreload' not found — install ifupdown2 if needed"
            fi

            warn "Network config applied."
            warn "If bridges (vmbr0/vmbr1) did not come up:"
            warn "  → Run 'ifreload -a' manually after reconnect"
            warn "  → Or reboot the node"
            success "Dual DHCP bridges configured (SSH likely dropped)"
        fi
    fi
fi

step "PHASE 5 — Netbird"
curl -fsSL https://pkgs.netbird.io/install.sh | sh
netbird up --management-url https://netbird.arigonz.com --setup-key "$NETBIRD_KEY" --accept-routes
sleep 12
netbird status | grep -q Connected && success "Netbird connected" || warn "Netbird status not Connected — check manually"

step "PHASE 6 — Cloudflared"
mkdir -p --mode=0755 /usr/share/keyrings
curl -fsSL https://pkg.cloudflare.com/cloudflare-public-v2.gpg | tee /usr/share/keyrings/cloudflare-public-v2.gpg >/dev/null
echo 'deb [signed-by=/usr/share/keyrings/cloudflare-public-v2.gpg] https://pkg.cloudflare.com/cloudflared any main' | tee /etc/apt/sources.list.d/cloudflared.list
apt-get update && apt-get install -y cloudflared
if [[ -n "$CLOUDFLARED_TOKEN" ]]; then
    cloudflared service install "$CLOUDFLARED_TOKEN"
    systemctl restart cloudflared 2>/dev/null || true
    success "Cloudflared installed & service created"
fi

step "PHASE 7 — Security + Dynamic MOTD + mDNS"
pve-firewall enable
ufw --force enable
ufw allow from 100.64.0.0/10 to any port 22 proto tcp comment "Netbird SSH"
ufw allow from 100.64.0.0/10 to any port 8006 proto tcp comment "Netbird PVE"
ufw reload
apt-get install -y avahi-daemon
sed -i 's/#enable-reflector=no/enable-reflector=yes/' /etc/avahi/avahi-daemon.conf 2>/dev/null || true
sed -i '/allow-interfaces=/d' /etc/avahi/avahi-daemon.conf 2>/dev/null || true
echo "allow-interfaces=vmbr0,vmbr1" >> /etc/avahi/avahi-daemon.conf
systemctl enable --now avahi-daemon

cat > /etc/update-motd.d/99-portable-proxmox << 'MOTD'
#!/bin/sh
DHCP0=$(ip -4 addr show vmbr0 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n1 || echo "None")
NETBIRD=$(netbird status 2>/dev/null | grep -oP 'NetBird IP:\s+\K[^\s]+' || echo "Disconnected")

# Improved Cloudflared status
CF_NAME="Not installed"
if command -v cloudflared >/dev/null 2>&1; then
    if systemctl is-active --quiet cloudflared 2>/dev/null; then
        CF_NAME="Active"
    else
        CF_NAME="Installed but not running"
    fi
fi

cat <<EOF
╔══════════════════════════════════════════════════════════════╗
║               Portable Proxmox HOST                      ║
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

step "PHASE 8 — Final Verification"
echo -e "\n${GREEN}SETUP COMPLETE! (v0.11)${NC}"
echo "If SSH dropped → reconnect to the new vmbr0 DHCP IP"
read -p "Reboot now? (y/N): " REBOOT
[[ "$REBOOT" =~ ^[Yy]$ ]] && reboot
