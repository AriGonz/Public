#!/bin/bash
# =====================================================
# Portable Proxmox Setup Script - 2026 Edition
# Usage: bash -c "$(curl -fsSL https://raw.githubusercontent.com/AriGonz/Public/refs/heads/main/proxmox-portable-setup.sh)"
# Version .18
# =====================================================

set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

# ── Version Banner ──────────────────────────────────
echo -e "\n${BLUE}══════════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}   Portable Proxmox Setup Script  —  v0.18${NC}"
echo -e "${BLUE}══════════════════════════════════════════════════════════════${NC}\n"

step() { echo -e "\n${BLUE}═══ $1 ${NC}"; }
success() { echo -e "${GREEN}✔ $1${NC}"; }
warn() { echo -e "${YELLOW}⚠ $1${NC}"; }
error() { echo -e "${RED}✖ $1${NC}"; exit 1; }

# Pre-checks
[[ $EUID -eq 0 ]] || error "Run as root"
command -v pveversion >/dev/null || error "Not on Proxmox"
ping -c1 8.8.8.8 >/dev/null 2>&1 || error "No internet"

# Netbird pre-check — skip Phase 5 if already installed and connected
NETBIRD_CONNECTED=false
NETBIRD_IP=""
BOLD='\033[1m'; CYAN='\033[0;36m'; BWHITE='\033[1;37m'; BYELLOW='\033[1;33m'; BCYAN='\033[1;36m'
if command -v netbird >/dev/null 2>&1; then
    NETBIRD_FULL=$(netbird status 2>/dev/null || true)
    if echo "$NETBIRD_FULL" | grep -qi "connected"; then
        NETBIRD_IP=$(echo "$NETBIRD_FULL" | grep -oE '100\.[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
        [[ -z "$NETBIRD_IP" ]] && NETBIRD_IP=$(ip addr show wt0 2>/dev/null | grep -oE '100\.[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
        NETBIRD_CONNECTED=true
        success "Netbird already installed and connected (IP: ${NETBIRD_IP}) — Phase 5 will be skipped"
    else
        warn "Netbird installed but not connected — Phase 5 will run normally"
    fi
fi

success "All pre-checks passed"

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


mkdir -p /root/.ssh
echo "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHgzljgx9gDLlln3EEE/vcPvr9NMz7kLiLraofNzeQoO pve-xx" >> /root/.ssh/authorized_keys
chmod 600 /root/.ssh/authorized_keys
echo 'alias ll="ls -lrt"' >> /root/.bashrc

step "PHASE 2 — User Input"
read -p "Hostname [$(hostname)]: " NEWHOST
[[ -n "$NEWHOST" ]] && hostnamectl set-hostname "$NEWHOST" && echo "$NEWHOST" > /etc/hostname



step "PHASE 3 — Proxmox Post-Install"
apt-get full-upgrade -y && apt-get autoremove -y
apt-get install -y htop curl git jq wget ufw
success "System upgraded"

step "PHASE 4 — Networking (Dual DHCP)"
# Idempotency check
if grep -q '^auto vmbr0' /etc/network/interfaces 2>/dev/null && grep -q '^auto vmbr1' /etc/network/interfaces 2>/dev/null; then
    warn "vmbr0 and vmbr1 already appear in /etc/network/interfaces — skipping network rewrite"
else
    echo -e "${RED}⚠ CRITICAL WARNING — SSH WILL DROP${NC}"
    echo -e "${RED}This will overwrite /etc/network/interfaces and apply new config.${NC}"
    echo -e "${RED}You will lose this SSH session immediately.${NC}"
    echo -e "${RED}Reconnect using the new DHCP IP on vmbr0 (check your router).${NC}"
    read -p "Continue and accept disconnect? (y/N): " CONFIRM
    if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
        warn "Networking skipped — continuing without change"
    else
        cp /etc/network/interfaces "/etc/network/interfaces.bak.$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true

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
if [[ "$NETBIRD_CONNECTED" == true ]]; then
    success "Netbird already connected (IP: ${NETBIRD_IP}) — skipping"
else
    curl -fsSL https://pkgs.netbird.io/install.sh | sh

    echo -e "Connecting to Netbird management server..."
    # Run netbird up in background and capture output for the auth URL
    NETBIRD_LOG=$(mktemp /tmp/netbird-XXXXX.log)
    netbird up --management-url https://netbird.arigonz.com > "$NETBIRD_LOG" 2>&1 &

    # Wait 10s for netbird up to print the auth URL
    echo -e "Waiting 10s for Netbird to initialize..."
    sleep 10

    # Extract auth URL from netbird up output, fall back to netbird status
    NETBIRD_AUTH_URL=$(grep -oE 'https://[^ ]+' "$NETBIRD_LOG" 2>/dev/null \
        | grep -v 'pkgs\|install\|docs' | head -1 || true)
    if [[ -z "$NETBIRD_AUTH_URL" ]]; then
        NETBIRD_AUTH_URL=$(netbird status 2>/dev/null | grep -oE 'https://[^ ]+' | head -1 || true)
    fi

    echo ""
    echo -e "${BYELLOW}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo -e "${BYELLOW}${BOLD}   ★  Netbird Authorization Required  ★${NC}"
    echo -e "${BYELLOW}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    if [[ -n "$NETBIRD_AUTH_URL" ]]; then
        echo -e "${BWHITE}${BOLD}  Open this URL to authorize this device:${NC}"
        echo -e "${BCYAN}${BOLD}  ${NETBIRD_AUTH_URL}${NC}"
    else
        echo -e "${BWHITE}${BOLD}  Run 'netbird status' to get your authorization URL${NC}"
        echo -e "${BWHITE}${BOLD}  Management URL: ${BCYAN}https://netbird.arigonz.com${NC}"
    fi
    echo -e "${BYELLOW}${BOLD}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
    echo ""

    echo -e "${BYELLOW}${BOLD}⏳ Waiting for Netbird authorization...${NC}"

    # Helper: check if netbird is connected, sets NETBIRD_CONNECTED and NETBIRD_IP
    check_netbird() {
        local NETBIRD_FULL
        NETBIRD_FULL=$(netbird status 2>/dev/null || true)
        if echo "$NETBIRD_FULL" | grep -qi "connected"; then
            NETBIRD_IP=$(echo "$NETBIRD_FULL" | grep -oE '100\.[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
            if [[ -z "$NETBIRD_IP" ]]; then
                NETBIRD_IP=$(ip addr show wt0 2>/dev/null | grep -oE '100\.[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
            fi
            NETBIRD_CONNECTED=true
            return 0
        fi
        return 1
    }

    # Wait 10 seconds before first check
    sleep 10

    # Check every 1 second for 10 seconds
    for i in {1..10}; do
        if check_netbird; then
            echo ""
            success "Netbird connected! Netbird IP: ${NETBIRD_IP}"
            break
        fi
        sleep 1
    done

    # If still not connected, ask the user
    if [[ "$NETBIRD_CONNECTED" == false ]]; then
        echo ""
        while true; do
            read -p "$(echo -e "${BYELLOW}${BOLD}Have you authorized the device at the URL above? (y/n): ${NC}")" USER_ANSWER
            if [[ "${USER_ANSWER,,}" == "y" ]]; then
                # Give it a few more seconds and check again
                echo -e "${BYELLOW}${BOLD}⏳ Checking connection...${NC}"
                for i in {1..10}; do
                    if check_netbird; then
                        echo ""
                        success "Netbird connected! Netbird IP: ${NETBIRD_IP}"
                        break
                    fi
                    sleep 1
                done
                [[ "$NETBIRD_CONNECTED" == true ]] && break
                warn "Still not connected — please check the URL and try again"
            elif [[ "${USER_ANSWER,,}" == "n" ]]; then
                warn "Netbird not authorized — skipping Netbird-dependent steps"
                break
            fi
        done
    fi
    echo ""
fi

step "PHASE 6 — Cloudflared"
mkdir -p --mode=0755 /usr/share/keyrings
curl -fsSL https://pkg.cloudflare.com/cloudflare-public-v2.gpg | tee /usr/share/keyrings/cloudflare-public-v2.gpg >/dev/null
echo 'deb [signed-by=/usr/share/keyrings/cloudflare-public-v2.gpg] https://pkg.cloudflare.com/cloudflared any main' | tee /etc/apt/sources.list.d/cloudflared.list
apt-get update && apt-get install -y cloudflared
success "Cloudflared installed — run 'cloudflared service install <token>' to configure tunnel"

step "PHASE 7 — Security + Dynamic MOTD + mDNS"
# FIX 3: Only enable UFW after confirming Netbird is connected,
# to avoid locking yourself out of SSH (port 22 is restricted to
# the Netbird CGNAT subnet 100.64.0.0/10 once UFW is enabled).
if [[ "$NETBIRD_CONNECTED" == true ]]; then
    pve-firewall enable
    ufw --force enable
    ufw allow from 100.64.0.0/10 to any port 22 proto tcp comment "Netbird SSH"
    ufw allow from 100.64.0.0/10 to any port 8006 proto tcp comment "Netbird PVE"
    ufw reload
    success "Firewall enabled — SSH and PVE UI restricted to Netbird subnet"
else
    warn "Netbird is NOT connected — skipping UFW/pve-firewall enable to avoid SSH lockout"
    warn "Once Netbird is confirmed working, run manually:"
    warn "  pve-firewall enable"
    warn "  ufw --force enable"
    warn "  ufw allow from 100.64.0.0/10 to any port 22 proto tcp"
    warn "  ufw allow from 100.64.0.0/10 to any port 8006 proto tcp"
    warn "  ufw reload"
fi

apt-get install -y avahi-daemon
sed -i 's/#enable-reflector=no/enable-reflector=yes/' /etc/avahi/avahi-daemon.conf 2>/dev/null || true
sed -i '/allow-interfaces=/d' /etc/avahi/avahi-daemon.conf 2>/dev/null || true
echo "allow-interfaces=vmbr0,vmbr1" >> /etc/avahi/avahi-daemon.conf
systemctl enable --now avahi-daemon

cat > /etc/update-motd.d/99-portable-proxmox << 'MOTD'
#!/bin/sh
DHCP0=$(ip -4 addr show vmbr0 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n1 || echo "None")
NETBIRD=$(netbird status 2>/dev/null | grep -oP 'NetBird IP:\s+\K[^\s]+' || echo "Disconnected")

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
║               Portable Proxmox HOST                          ║
╟──────────────────────────────────────────────────────────────╢
║  Hostname          :  $(hostname)
║  DHCP IP (vmbr0)   :  $DHCP0
║  Netbird IP        :  $NETBIRD
║  Cloudflared       :  $CF_NAME
║  mDNS              :  $(hostname).local:8006
╚══════════════════════════════════════════════════════════════╝
EOF
MOTD
chmod +x /etc/update-motd.d/99-portable-proxmox
rm -f /etc/motd /etc/motd.tail

step "PHASE 8 — Subscription Nag Removal"
JS="/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js"
if [[ -f "$JS" ]]; then
    cp "$JS" "${JS}.bak.$(date +%s)" 2>/dev/null || true
    sed -Ezi 's/(Ext\.Msg\.show\(\{\s+title: gettext\(.No valid sub)/void(\{ \/\/\1/g' "$JS"
    success "Subscription nag patched — will take effect after reboot"
else
    warn "proxmoxlib.js not found — skipping nag removal"
fi

step "PHASE 9 — Final Verification"
echo -e "\n${GREEN}SETUP COMPLETE! (v0.18)${NC}"
if [[ "$NETBIRD_CONNECTED" == false ]]; then
    echo -e "${YELLOW}⚠ Remember: Firewall was NOT enabled because Netbird did not connect.${NC}"
    echo -e "${YELLOW}  Secure your node manually before exposing it to the internet.${NC}"
fi
read -p "Reboot now? (y/N): " REBOOT
[[ "$REBOOT" =~ ^[Yy]$ ]] && reboot
