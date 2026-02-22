#!/bin/bash
# =====================================================
# Portable Proxmox Setup Script - 2026 Edition
# Usage: bash -c "$(curl -fsSL https://raw.githubusercontent.com/AriGonz/Public/refs/heads/main/proxmox-portable-setup.sh)"
# Version .47
# =====================================================

set -e

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; BLUE='\033[0;34m'; NC='\033[0m'

# ── Version Banner ──────────────────────────────────
echo -e "\n${BLUE}══════════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}   Portable Proxmox Setup Script  —  v0.47${NC}"
echo -e "${BLUE}══════════════════════════════════════════════════════════════${NC}\n"

step() { echo -e "\n${BLUE}═══ $1 ${NC}"; }
success() { echo -e "${GREEN}✔ $1${NC}"; }
warn() { echo -e "${YELLOW}⚠ $1${NC}"; }
error() { echo -e "${RED}✖ $1${NC}"; exit 1; }
die() { echo -e "${RED}✖ FATAL: $1${NC}"; exit 1; }

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

# Remove invalid .bak files from sources.list.d
find /etc/apt/sources.list.d/ \( -name '*.bak*' -o -name '*.bak-*' \) 2>/dev/null | while read -r f; do
    warn "Removing invalid apt source file: $f"
    rm -f "$f"
done

# Detect codename
PVE_CODENAME=$(grep VERSION_CODENAME /etc/os-release | cut -d= -f2)
if [[ -z "$PVE_CODENAME" ]]; then
    PVE_CODENAME="bookworm"
    warn "Could not detect VERSION_CODENAME — defaulting to bookworm"
fi

# Disable Proxmox enterprise repos (both .list and .sources formats)
while IFS= read -r f; do
    if [[ "$f" == *.sources ]]; then
        if grep -q '^Enabled:' "$f"; then
            sed -i 's/^Enabled:.*/Enabled: no/' "$f"
        else
            sed -i '/^Types:/i Enabled: no' "$f"
        fi
        warn "Disabled enterprise repo: $f"
    else
        sed -i 's/^deb/#deb/' "$f"
        warn "Disabled enterprise repo: $f"
    fi
done < <(grep -rl enterprise.proxmox.com /etc/apt/sources.list.d/ /etc/apt/sources.list 2>/dev/null || true)

# Handle pve-no-subscription:
# If proxmox.sources already has it, remove any duplicate from sources.list to avoid warnings
if grep -ql 'pve-no-subscription' /etc/apt/sources.list.d/*.sources 2>/dev/null; then
    # Remove the line from sources.list if present there too
    sed -i '/pve-no-subscription/d' /etc/apt/sources.list 2>/dev/null || true
    success "No-subscription repo present in proxmox.sources (cleaned up sources.list duplicate)"
elif ! grep -qF 'pve-no-subscription' /etc/apt/sources.list 2>/dev/null; then
    echo "deb http://download.proxmox.com/debian/pve ${PVE_CODENAME} pve-no-subscription" \
        >> /etc/apt/sources.list
    success "Added no-subscription repo for ${PVE_CODENAME}"
else
    success "No-subscription repo already present in sources.list"
fi

# Ensure standard Debian repos are present (needed for htop, git, jq, ufw etc)
# Check specifically for deb.debian.org — suite name alone is not unique enough
# (proxmox.sources also uses the same suite name e.g. "trixie")
if [[ "$PVE_CODENAME" == "trixie" ]]; then
    DEBIAN_REPOS=(
        "deb http://deb.debian.org/debian trixie main contrib non-free non-free-firmware"
        "deb http://deb.debian.org/debian trixie-updates main contrib"
        "deb http://deb.debian.org/debian-security trixie-security main contrib"
    )
else
    DEBIAN_REPOS=(
        "deb http://deb.debian.org/debian ${PVE_CODENAME} main contrib"
        "deb http://deb.debian.org/debian-security ${PVE_CODENAME}-security main contrib"
        "deb http://deb.debian.org/debian ${PVE_CODENAME}-updates main contrib"
    )
fi
for line in "${DEBIAN_REPOS[@]}"; do
    url=$(echo "$line" | awk '{print $2}')
    suite=$(echo "$line" | awk '{print $3}')
    # Check both .list format (deb http://...) and .sources format (URIs:/Suites: fields)
    if grep -rq "${url}.*${suite}\|${suite}.*${url}" \
            /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null || \
       grep -rql "deb.debian.org" /etc/apt/sources.list.d/*.sources 2>/dev/null; then
        success "Debian repo already present: $suite"
    else
        echo "$line" >> /etc/apt/sources.list
        success "Added Debian repo: $suite (${url})"
    fi
done

# Update and verify — check for htop which only comes from Debian repos (not Proxmox repos)
apt-get update -qq
if ! apt-cache show htop >/dev/null 2>&1; then
    warn "Current /etc/apt/sources.list:"
    cat /etc/apt/sources.list
    warn "Files in sources.list.d:"
    ls /etc/apt/sources.list.d/
    die "Repo setup failed — Debian packages not found. Fix sources manually and re-run."
fi
success "Repos configured and verified (${PVE_CODENAME})"


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

# Download network recovery script
curl -fsSL https://raw.githubusercontent.com/AriGonz/Public/refs/heads/main/pve-net-recover.sh \
    -o /root/pve-net-recover.sh
chmod +x /root/pve-net-recover.sh
success "Network recovery script downloaded to /root — run 'bash ~/pve-net-recover.sh' if node doesn't pick up IP"

success "System upgraded"

step "PHASE 3 — Netbird"
if [[ "$NETBIRD_CONNECTED" == true ]]; then
    # Already installed and connected — ask if re-authorize needed
    echo ""
    read -p "$(echo -e "${BYELLOW}${BOLD}Netbird is already connected (${NETBIRD_IP}). Re-authorize this node? (y/N): ${NC}")" REAUTH
    if [[ ! "${REAUTH,,}" =~ ^y$ ]]; then
        success "Netbird already connected (IP: ${NETBIRD_IP}) — skipping"
    else
        NETBIRD_CONNECTED=false
        warn "Re-authorizing Netbird on this node..."
        netbird down 2>/dev/null || true
        NETBIRD_DO_SETUP=true
        NETBIRD_SKIP_INSTALL=true   # Already installed, skip installer
    fi
elif command -v netbird >/dev/null 2>&1; then
    # Installed but not connected — skip installer, just re-run netbird up
    warn "Netbird is installed but not connected — running netbird up to get auth URL"
    NETBIRD_DO_SETUP=true
    NETBIRD_SKIP_INSTALL=true
else
    # Fresh install
    NETBIRD_DO_SETUP=true
    NETBIRD_SKIP_INSTALL=false
fi

if [[ "${NETBIRD_DO_SETUP:-false}" == true ]]; then
    if [[ "${NETBIRD_SKIP_INSTALL:-false}" == false ]]; then
        curl -fsSL https://pkgs.netbird.io/install.sh | sh
    fi

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
LOG=/var/log/ufw-lan-refresh.log
echo "$(date): ufw-lan-refresh started" >> "$LOG"

# Wait for DHCP to assign an IP — retry for up to 30s
# network-online.target can fire before DHCP completes on a new network
LOCAL_SUBNET=""
for attempt in $(seq 1 12); do
    # Method 1: kernel/dhcp route
    LOCAL_SUBNET=$(ip -4 route 2>/dev/null \
        | grep -E 'proto (kernel|dhcp)' \
        | grep -v '100\.64\.' \
        | awk '{print $1}' | grep '/' | head -1)

    # Method 2: derive from global IP if route not yet present
    if [[ -z "$LOCAL_SUBNET" ]]; then
        PRIMARY_IP=$(ip -4 addr show scope global 2>/dev/null \
            | grep -oP '(?<=inet\s)\d+(\.\d+){3}/\d+' \
            | grep -v '100\.64\.' | head -1)
        if [[ -n "$PRIMARY_IP" ]]; then
            LOCAL_SUBNET=$(python3 -c \
                "import ipaddress; n=ipaddress.ip_interface('${PRIMARY_IP}'); print(n.network)" \
                2>/dev/null || true)
        fi
    fi

    [[ -n "$LOCAL_SUBNET" ]] && break
    echo "$(date): attempt $attempt — waiting for DHCP..." >> "$LOG"
    sleep 5
done

if [[ -z "$LOCAL_SUBNET" ]]; then
    echo "$(date): could not detect local subnet after retries — giving up" >> "$LOG"
    exit 1
fi

echo "$(date): detected subnet $LOCAL_SUBNET" >> "$LOG"

# Delete all existing non-Netbird rules on ports 22 and 8006.
# Re-query rule numbers each iteration because they shift after every delete.
for port in 22 8006; do
    while true; do
        rule_num=$(ufw status numbered 2>/dev/null \
            | grep -E "^\[ *[0-9]+\].*${port}" \
            | grep -v '100\.64\.' \
            | grep -oP '^\[\s*\K[0-9]+' \
            | sort -rn | head -1)
        [[ -z "$rule_num" ]] && break
        ufw --force delete "$rule_num" 2>/dev/null && \
            echo "$(date): deleted rule $rule_num (port $port)" >> "$LOG" || break
    done
done

# Add fresh rules for the current subnet
ufw allow from "$LOCAL_SUBNET" to any port 22 proto tcp comment "LAN SSH"
ufw allow from "$LOCAL_SUBNET" to any port 8006 proto tcp comment "LAN PVE"
ufw reload

echo "$(date): rules updated for $LOCAL_SUBNET" >> "$LOG"
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
# Allow up to 90s for DHCP retry loop (12 attempts x 5s = 60s + buffer)
TimeoutStartSec=90

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
#!/bin/bash
DHCP0=$(ip -4 addr show vmbr0 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -n1 || echo "None")

# Read saved config
DOMAIN=""
HOSTNAME_CFG=""
[ -f /etc/proxmox-portable/config ] && . /etc/proxmox-portable/config

# ── Netbird ───────────────────────────────────────────────────
# Strip CIDR suffix (/16 etc) from the IP
NETBIRD_IP=$(ip -4 addr show wt0 2>/dev/null \
    | grep -oP '(?<=inet\s)100\.[0-9]+\.[0-9]+\.[0-9]+' || true)
if [[ -n "$NETBIRD_IP" ]]; then
    NETBIRD_DISPLAY="${NETBIRD_IP} (Active)"
else
    NETBIRD_DISPLAY="Disconnected"
fi

# ── Cloudflared ───────────────────────────────────────────────
CF_DISPLAY="Not installed"
if command -v cloudflared >/dev/null 2>&1; then
    CF_RUNNING=false
    for svc in cloudflared cloudflared.service; do
        systemctl is-active --quiet "$svc" 2>/dev/null && CF_RUNNING=true && break
    done
    [[ "$CF_RUNNING" == false ]] && pgrep -x cloudflared >/dev/null 2>&1 && CF_RUNNING=true

    if [[ "$CF_RUNNING" == true ]]; then
        CF_URL=""
        [[ -n "$DOMAIN" ]] && CF_URL="https://$(hostname).${DOMAIN}"

        # Find the cloudflared metrics port (varies: 2000, 20241, etc.)
        CF_METRICS_OK=false
        for port in 2000 20241 2001 8080; do
            if curl -sf --max-time 2 "http://localhost:${port}/metrics" >/dev/null 2>&1; then
                CF_METRICS_OK=true
                break
            fi
        done

        if [[ "$CF_METRICS_OK" == true ]]; then
            CF_DISPLAY="${CF_URL:-Active} (Active)"
        else
            CF_DISPLAY="${CF_URL:-Active} (Not active)"
        fi
    else
        CF_DISPLAY="Installed but not running"
    fi
fi

cat > /etc/issue << EOF

╔══════════════════════════════════════════════════════════════╗
║               Portable Proxmox HOST                          ║
╟──────────────────────────────────────────────────────────────╢
║  Hostname          :  $(hostname)
║  DHCP IP (vmbr0)   :  $DHCP0
║  Netbird IP        :  $NETBIRD_DISPLAY
║  mDNS              :  https://$(hostname).local:8006
║  Cloudflared       :  $CF_DISPLAY
╚══════════════════════════════════════════════════════════════╝

EOF

echo "$(date): DHCP=$DHCP0 NETBIRD=$NETBIRD_DISPLAY CF=$CF_DISPLAY" >> /var/log/console-issue.log
ISSUE_SCRIPT
chmod +x /usr/local/bin/update-console-issue

# Helper script to redraw tty1 — writes /etc/issue then restarts getty
# so the login prompt reappears cleanly underneath.
cat > /usr/local/bin/redraw-tty1 << 'REDRAW'
#!/bin/bash
# Update /etc/issue content first (caller may have already done this)
# Then restart getty@tty1 — it will run ExecStartPre (update-console-issue)
# and redisplay /etc/issue followed by the login prompt automatically.
systemctl restart getty@tty1
REDRAW
chmod +x /usr/local/bin/redraw-tty1

# Drop-in override for getty@tty1 — runs our script before the login prompt appears
mkdir -p /etc/systemd/system/getty@tty1.service.d
cat > /etc/systemd/system/getty@tty1.service.d/override.conf << 'SVC'
[Service]
ExecStartPre=/usr/local/bin/update-console-issue
SVC

cat > /usr/local/bin/netbird-tty-refresh << 'REFRESH_SCRIPT'
#!/bin/bash
MAX_WAIT=120
INTERVAL=5
ELAPSED=0

echo "$(date): netbird-tty-refresh started" >> /var/log/console-issue.log

netbird_active() {
    ip -4 addr show wt0 2>/dev/null | grep -q '100\.[0-9]'
}

cloudflared_active() {
    for port in 2000 20241 2001 8080; do
        curl -sf --max-time 2 "http://localhost:${port}/metrics" >/dev/null 2>&1 && return 0
    done
    return 1
}

NETBIRD_OK=false
CF_OK=false
LAST_STATE=""

while [[ $ELAPSED -lt $MAX_WAIT ]]; do
    netbird_active  && NETBIRD_OK=true  || NETBIRD_OK=false
    cloudflared_active && CF_OK=true || CF_OK=false

    CURRENT_STATE="NB=${NETBIRD_OK} CF=${CF_OK}"

    if [[ "$CURRENT_STATE" != "$LAST_STATE" ]]; then
        echo "$(date): state changed to $CURRENT_STATE at ${ELAPSED}s — redrawing TTY1" >> /var/log/console-issue.log
        /usr/local/bin/update-console-issue
        /usr/local/bin/redraw-tty1
        LAST_STATE="$CURRENT_STATE"
    fi

    if [[ "$NETBIRD_OK" == true && "$CF_OK" == true ]]; then
        echo "$(date): both services active — exiting" >> /var/log/console-issue.log
        exit 0
    fi

    sleep $INTERVAL
    ELAPSED=$(( ELAPSED + INTERVAL ))
done

echo "$(date): timed out after ${MAX_WAIT}s — final redraw" >> /var/log/console-issue.log
/usr/local/bin/update-console-issue
/usr/local/bin/redraw-tty1
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
# Check if already configured correctly (both bridges present AND vmbr0 is DHCP)
VMBR0_TYPE=$(grep -A2 'iface vmbr0' /etc/network/interfaces 2>/dev/null | grep 'inet' | awk '{print $3}' || echo "missing")
if grep -q '^auto vmbr0' /etc/network/interfaces 2>/dev/null \
    && grep -q '^auto vmbr1' /etc/network/interfaces 2>/dev/null \
    && [[ "$VMBR0_TYPE" == "dhcp" ]]; then
    warn "vmbr0 and vmbr1 already configured as DHCP — skipping network rewrite"
elif [[ "$VMBR0_TYPE" == "static" ]]; then
    warn "vmbr0 is STATIC — will rewrite to DHCP so node picks up IP on any network"
fi

if ! { grep -q '^auto vmbr0' /etc/network/interfaces 2>/dev/null \
    && grep -q '^auto vmbr1' /etc/network/interfaces 2>/dev/null \
    && [[ "$VMBR0_TYPE" == "dhcp" ]]; }; then
    # Detect physical NICs by EXCLUDING known virtual interfaces rather than
    # allowlisting by prefix — handles non-standard names like nic0, nic1 etc.
    PHYS_NICS=$(ip -o link show | awk -F': ' '{print $2}' | awk '{print $1}' \
        | grep -vE '^(lo|docker|br|vmbr|veth|bond|wg|virbr|tun|tap|wl|dummy|sit|teql|ifb|ip6tnl)' \
        | sort -u)
    NIC_ARRAY=($PHYS_NICS)

    # Fallback: read from /sys/class/net
    if [ ${#NIC_ARRAY[@]} -eq 0 ]; then
        PHYS_NICS=$(ls /sys/class/net/ \
            | grep -vE '^(lo|docker|br|vmbr|veth|bond|wg|virbr|tun|tap|wl|dummy|sit)' \
            | sort -u)
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
echo -e "\n${GREEN}SETUP COMPLETE! (v0.47)${NC}"
if [[ "$NETBIRD_CONNECTED" == false ]]; then
    echo -e "${YELLOW}⚠ Remember: Firewall was NOT enabled because Netbird did not connect.${NC}"
    echo -e "${YELLOW}  Secure your node manually before exposing it to the internet.${NC}"
fi
echo -e "\n${BLUE}══════════════════════════════════════════════════════════════${NC}"
echo -e "${BLUE}  To run on the next node, use:${NC}"
echo -e "${CYAN}  bash -c \"\$(curl -fsSL https://raw.githubusercontent.com/AriGonz/Public/refs/heads/main/proxmox-portable-setup.sh)\"${NC}"
echo -e "${BLUE}══════════════════════════════════════════════════════════════${NC}\n"
read -p "Reboot now? (y/N): " REBOOT
[[ "$REBOOT" =~ ^[Yy]$ ]] && reboot
