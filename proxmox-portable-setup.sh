#!/bin/bash
# =====================================================
# Portable Proxmox Setup Script - 2026 Edition
# Usage: bash -c "$(curl -fsSL https://raw.githubusercontent.com/AriGonz/Public/refs/heads/main/proxmox-portable-setup.sh)"
# Version .30
# =====================================================

set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

# ── Version Banner ──────────────────────────────────
echo -e "\n${BLUE}══════════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}   Portable Proxmox Setup Script  —  v0.30${NC}"
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

step "PHASE 1 — User Input"

# Auto-detect FQDN from /etc/hosts (set during Proxmox install as 'pve-00.arigonz.com')
DETECTED_FQDN=$(grep -v '^#' /etc/hosts | grep -v '^127\.' | grep -v '^::' \
    | awk '{for(i=2;i<=NF;i++) if($i~/\./) {print $i; exit}}')
DETECTED_HOST="${DETECTED_FQDN%%.*}"
DETECTED_DOMAIN="${DETECTED_FQDN#*.}"

if [[ -n "$DETECTED_FQDN" && "$DETECTED_HOST" != "$DETECTED_FQDN" ]]; then
    echo "Detected FQDN from /etc/hosts: ${DETECTED_FQDN}"
    read -p "Hostname [${DETECTED_HOST}]: " NEWHOST
    NEWHOST="${NEWHOST:-$DETECTED_HOST}"
    read -p "Domain [${DETECTED_DOMAIN}]: " USER_DOMAIN
    USER_DOMAIN="${USER_DOMAIN:-$DETECTED_DOMAIN}"
else
    warn "Could not detect FQDN from /etc/hosts — please enter manually"
    read -p "Hostname [$(hostname)]: " NEWHOST
    NEWHOST="${NEWHOST:-$(hostname)}"
    read -p "Your domain (e.g. arigonz.com): " USER_DOMAIN
    USER_DOMAIN="${USER_DOMAIN:-}"
fi

hostnamectl set-hostname "$NEWHOST" && echo "$NEWHOST" > /etc/hostname

# Save to persistent config so boot-time scripts can read it
mkdir -p /etc/proxmox-portable
cat > /etc/proxmox-portable/config << EOF
HOSTNAME=${NEWHOST}
DOMAIN=${USER_DOMAIN}
EOF
success "Detected FQDN: ${NEWHOST}.${USER_DOMAIN} — config saved"



step "PHASE 2 — Proxmox Post-Install"
apt-get full-upgrade -y && apt-get autoremove -y
apt-get install -y htop curl git jq wget ufw
success "System upgraded"

step "PHASE 3 — Netbird"
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

step "PHASE 4 — Cloudflared"
mkdir -p --mode=0755 /usr/share/keyrings
curl -fsSL https://pkg.cloudflare.com/cloudflare-public-v2.gpg | tee /usr/share/keyrings/cloudflare-public-v2.gpg >/dev/null
echo 'deb [signed-by=/usr/share/keyrings/cloudflare-public-v2.gpg] https://pkg.cloudflare.com/cloudflared any main' | tee /etc/apt/sources.list.d/cloudflared.list
apt-get update && apt-get install -y cloudflared
success "Cloudflared installed — run 'cloudflared service install <token>' to configure tunnel"

step "PHASE 5 — Security + Dynamic MOTD + mDNS"
# Only enable UFW after confirming Netbird is connected,
# to avoid locking yourself out of SSH.
if [[ "$NETBIRD_CONNECTED" == true ]]; then
    pve-firewall start
    ufw --force enable
    # Permanent: allow from Netbird subnet on any network
    ufw allow from 100.64.0.0/10 to any port 22 proto tcp comment "Netbird SSH"
    ufw allow from 100.64.0.0/10 to any port 8006 proto tcp comment "Netbird PVE"
    ufw reload
    success "Firewall enabled — Netbird rules applied"
else
    warn "Netbird is NOT connected — skipping UFW/pve-firewall start to avoid SSH lockout"
    warn "Once Netbird is confirmed working, run manually:"
    warn "  pve-firewall start"
    warn "  ufw --force enable"
    warn "  ufw allow from 100.64.0.0/10 to any port 22 proto tcp"
    warn "  ufw allow from 100.64.0.0/10 to any port 8006 proto tcp"
    warn "  ufw reload"
fi

# Dynamic LAN UFW refresh — runs on every boot after network is up.
# Detects the current subnet (works on any network), flushes old LAN rules,
# and adds fresh rules for ports 22 and 8006 from the current local subnet.
cat > /usr/local/bin/ufw-lan-refresh << 'LAN_SCRIPT'
#!/bin/bash
# Detect current LAN subnet, excluding Netbird CGNAT range
LOCAL_SUBNET=$(ip -4 route | grep -E 'proto (kernel|dhcp)' \
    | grep -v '100\.64\.' \
    | awk '{print $1}' | grep '/' | head -1)

# Fallback: derive from primary global IP
if [[ -z "$LOCAL_SUBNET" ]]; then
    PRIMARY_IP=$(ip -4 addr show scope global \
        | grep -oP '(?<=inet\s)\d+(\.\d+){3}/\d+' \
        | grep -v '100\.64\.' | head -1)
    LOCAL_SUBNET=$(python3 -c \
        "import ipaddress; n=ipaddress.ip_interface('${PRIMARY_IP}'); print(n.network)" \
        2>/dev/null || true)
fi

if [[ -z "$LOCAL_SUBNET" ]]; then
    echo "ufw-lan-refresh: could not detect local subnet, skipping"
    exit 0
fi

echo "ufw-lan-refresh: detected subnet $LOCAL_SUBNET"

# Delete all existing LAN rules (tagged with "LAN SSH" / "LAN PVE" comments)
# UFW doesn't support deleting by comment, so we delete by rule spec
ufw delete allow from 0.0.0.0/0 to any port 22 proto tcp 2>/dev/null || true
ufw delete allow from 0.0.0.0/0 to any port 8006 proto tcp 2>/dev/null || true
# More targeted: remove any non-Netbird rules on ports 22 and 8006
while IFS= read -r rule_num; do
    ufw --force delete "$rule_num" 2>/dev/null || true
done < <(ufw status numbered 2>/dev/null \
    | grep -E '(22|8006)' \
    | grep -v '100\.64\.' \
    | grep -oP '^\[\s*\K[0-9]+' \
    | sort -rn)

# Add fresh rules for the current subnet
ufw allow from "$LOCAL_SUBNET" to any port 22 proto tcp comment "LAN SSH"
ufw allow from "$LOCAL_SUBNET" to any port 8006 proto tcp comment "LAN PVE"
ufw reload

echo "ufw-lan-refresh: rules updated for $LOCAL_SUBNET"
LAN_SCRIPT
chmod +x /usr/local/bin/ufw-lan-refresh

cat > /etc/systemd/system/ufw-lan-refresh.service << 'SVC'
[Unit]
Description=Refresh UFW LAN rules for current subnet
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/ufw-lan-refresh
RemainAfterExit=no

[Install]
WantedBy=multi-user.target
SVC

systemctl daemon-reload
systemctl enable ufw-lan-refresh
# Run it now for the current network too
/usr/local/bin/ufw-lan-refresh
success "Dynamic LAN UFW refresh configured — will update on every boot"

apt-get install -y avahi-daemon
sed -i 's/#enable-reflector=no/enable-reflector=yes/' /etc/avahi/avahi-daemon.conf 2>/dev/null || true
# Remove interface restriction — avahi will bind to whatever is up at boot time
sed -i '/allow-interfaces=/d' /etc/avahi/avahi-daemon.conf 2>/dev/null || true
sed -i '/deny-interfaces=/d' /etc/avahi/avahi-daemon.conf 2>/dev/null || true
# Disable IPv6 so Windows resolves .local to an IPv4 address, not a link-local IPv6
sed -i 's/#use-ipv6=yes/use-ipv6=no/' /etc/avahi/avahi-daemon.conf 2>/dev/null || true
sed -i 's/use-ipv6=yes/use-ipv6=no/' /etc/avahi/avahi-daemon.conf 2>/dev/null || true
systemctl enable --now avahi-daemon
success "Avahi mDNS configured (IPv4 only)"

# MOTD — shown over SSH
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

# Physical console/TTY screen — shown on the physical monitor and IPMI/remote console
# We override getty@tty1 to run our script immediately before displaying the login prompt,
# so the box info always shows fresh IPs at the time the TTY is rendered.

cat > /usr/local/bin/update-console-issue << 'ISSUE_SCRIPT'
#!/bin/sh
DHCP0=$(ip -4 addr show vmbr0 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n1 || echo "None")
NETBIRD=$(netbird status 2>/dev/null | grep -oP 'NetBird IP:\s+\K[^\s]+' || echo "Disconnected")

# Read saved config
DOMAIN=""
if [ -f /etc/proxmox-portable/config ]; then
    . /etc/proxmox-portable/config
fi

CF_NAME="Not installed"
CF_URL=""
if command -v cloudflared >/dev/null 2>&1; then
    if systemctl is-active --quiet cloudflared 2>/dev/null; then
        CF_NAME="Active"
        [ -n "$DOMAIN" ] && CF_URL="https://$(hostname).${DOMAIN}"
    else
        CF_NAME="Installed but not running"
    fi
fi

cat > /etc/issue << EOF

╔══════════════════════════════════════════════════════════════╗
║               Portable Proxmox HOST                          ║
╟──────────────────────────────────────────────────────────────╢
║  Hostname          :  $(hostname)
║  DHCP IP (vmbr0)   :  $DHCP0
║  Netbird IP        :  $NETBIRD
║  mDNS              :  https://$(hostname).local:8006
║  Cloudflared       :  ${CF_URL:-$CF_NAME}
╚══════════════════════════════════════════════════════════════╝

EOF
ISSUE_SCRIPT
chmod +x /usr/local/bin/update-console-issue

# Drop-in override for getty@tty1 — runs our script before the login prompt appears
mkdir -p /etc/systemd/system/getty@tty1.service.d
cat > /etc/systemd/system/getty@tty1.service.d/override.conf << 'SVC'
[Service]
ExecStartPre=/usr/local/bin/update-console-issue
SVC

# Netbird TTY refresh — polls until Netbird connects, then restarts getty@tty1
# which triggers ExecStartPre (update-console-issue) with the real Netbird IP.
cat > /usr/local/bin/netbird-tty-refresh << 'REFRESH_SCRIPT'
#!/bin/bash
MAX_WAIT=180  # seconds
INTERVAL=5
ELAPSED=0

while [[ $ELAPSED -lt $MAX_WAIT ]]; do
    if netbird status 2>/dev/null | grep -qi "connected"; then
        # Netbird is connected — update /etc/issue with real IP
        /usr/local/bin/update-console-issue
        # Restart getty@tty1 which will re-run ExecStartPre and redisplay the screen
        systemctl restart getty@tty1
        echo "netbird-tty-refresh: TTY1 refreshed with Netbird IP at ${ELAPSED}s"
        exit 0
    fi
    sleep $INTERVAL
    ELAPSED=$(( ELAPSED + INTERVAL ))
done

# Timed out — do a final update with whatever state we have
echo "netbird-tty-refresh: timed out after ${MAX_WAIT}s, refreshing with current state"
/usr/local/bin/update-console-issue
systemctl restart getty@tty1
REFRESH_SCRIPT
chmod +x /usr/local/bin/netbird-tty-refresh

cat > /etc/systemd/system/netbird-tty-refresh.service << 'SVC'
[Unit]
Description=Refresh TTY1 console once Netbird connects
# Run after basic network is up — we poll for Netbird ourselves
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/netbird-tty-refresh
RemainAfterExit=no
# Give it enough time to poll the full MAX_WAIT duration
TimeoutStartSec=240

[Install]
WantedBy=multi-user.target
SVC

systemctl daemon-reload
systemctl enable netbird-tty-refresh
success "TTY console issue screen configured (will refresh once Netbird connects, up to 180s)"

step "PHASE 6 — Subscription Nag Removal"
JS="/usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js"
if [[ -f "$JS" ]]; then
    cp "$JS" "${JS}.bak.$(date +%s)" 2>/dev/null || true
    sed -Ezi 's/(Ext\.Msg\.show\(\{\s+title: gettext\(.No valid sub)/void(\{ \/\/\1/g' "$JS"
    success "Subscription nag patched — will take effect after reboot"
else
    warn "proxmoxlib.js not found — skipping nag removal"
fi

step "PHASE 7 — Networking (Dual DHCP)"
# Idempotency check
if grep -q '^auto vmbr0' /etc/network/interfaces 2>/dev/null && grep -q '^auto vmbr1' /etc/network/interfaces 2>/dev/null; then
    warn "vmbr0 and vmbr1 already appear in /etc/network/interfaces — skipping network rewrite"
else
    # Detect all physical NICs — include down and bridge-enslaved ones
    PHYS_NICS=$(ip -o link show | awk -F': ' '{print $2}' | awk '{print $1}' \
        | grep -E '^(en|eth|em|eno|ens|enp|enx)' \
        | grep -vE '^(lo|docker|br|vmbr|veth|bond|wg|virbr|tun|tap)' \
        | sort -u)
    NIC_ARRAY=($PHYS_NICS)

    # Fallback: read directly from /sys/class/net if ip link found nothing
    if [ ${#NIC_ARRAY[@]} -eq 0 ]; then
        PHYS_NICS=$(ls /sys/class/net/ | grep -E '^(en|eth|em|eno|ens|enp|enx)' | sort -u)
        NIC_ARRAY=($PHYS_NICS)
    fi

    echo "Detected physical NICs: ${NIC_ARRAY[*]:-none}"

    if [ ${#NIC_ARRAY[@]} -eq 0 ]; then
        warn "No physical ethernet interfaces detected — skipping bridge creation"
    else
        echo -e "${RED}⚠ CRITICAL WARNING — this will rewrite /etc/network/interfaces${NC}"
        echo -e "${RED}The new config will take effect on reboot.${NC}"
        read -p "Apply networking config? (y/N): " CONFIRM
        if [[ ! "$CONFIRM" =~ ^[Yy]$ ]]; then
            warn "Networking skipped — continuing without change"
        else
            cp /etc/network/interfaces "/etc/network/interfaces.bak.$(date +%Y%m%d-%H%M%S)" 2>/dev/null || true
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
            success "Network config written — bridges will come up on reboot"
        fi
    fi
fi

step "PHASE 8 — Complete"
echo -e "\n${GREEN}SETUP COMPLETE! (v0.30)${NC}"
if [[ "$NETBIRD_CONNECTED" == false ]]; then
    echo -e "${YELLOW}⚠ Remember: Firewall was NOT enabled because Netbird did not connect.${NC}"
    echo -e "${YELLOW}  Secure your node manually before exposing it to the internet.${NC}"
fi
read -p "Reboot now? (y/N): " REBOOT
[[ "$REBOOT" =~ ^[Yy]$ ]] && reboot
