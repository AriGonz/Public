#!/bin/bash
# =============================================================================
# Proxmox Backup Server Portable Setup Script v0.01
# Fully portable PBS node: DHCP on any network + Netbird + Cloudflared + mDNS
# Idempotent — safe to re-run
#
# Run: bash -c "$(curl -fsSL https://raw.githubusercontent.com/AriGonz/Public/refs/heads/main/pbs-portable-setup.sh)"
# =============================================================================

SETUP_SCRIPT_URL="https://raw.githubusercontent.com/AriGonz/Public/refs/heads/main/pbs-portable-setup.sh"

SSH_KEYS=(
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHgzljgx9gDLlln3EEE/vcPvr9NMz7kLiLraofNzeQoO pve-xx"
)

NETBIRD_URL="https://netbird.arigonz.com"
USER_DOMAIN_DEFAULT="arigonz.com"
HOSTNAME_PREFIX="pbs"
PBS_PORT=8007

# RECAP
RECAP_HOSTNAME="-" RECAP_DOMAIN="-" RECAP_REPOS="-" RECAP_UPGRADE="-"
RECAP_NETBIRD="-" RECAP_CLOUDFLARED="-" RECAP_FIREWALL="-"
RECAP_MOTD="-" RECAP_MDNS="-" RECAP_NAG="-" RECAP_NETWORK="-" RECAP_SSH_KEYS="-"

success() { echo -e "\e[32m[✔] $1\e[0m"; }
warn() { echo -e "\e[33m[⚠] $1\e[0m"; }
error() { echo -e "\e[31m[✖] $1\e[0m"; exit 1; }
info() { echo -e "\e[34m[i] $1\e[0m"; }

print_recap_box() {
    echo
    echo -e "\e[34m╔══════════════════════════════════════════════════════════════╗\e[0m"
    echo -e "\e[34m║               PBS PORTABLE SETUP RECAP (v0.58)               ║\e[0m"
    echo -e "\e[34m╟──────────────────────────────────────────────────────────────╢\e[0m"
    printf "\e[34m║  %-20s  %s\e[0m\n" "Hostname:" "$RECAP_HOSTNAME"
    printf "\e[34m║  %-20s  %s\e[0m\n" "Domain:" "$RECAP_DOMAIN"
    printf "\e[34m║  %-20s  %s\e[0m\n" "SSH Keys:" "$RECAP_SSH_KEYS"
    printf "\e[34m║  %-20s  %s\e[0m\n" "Repos:" "$RECAP_REPOS"
    printf "\e[34m║  %-20s  %s\e[0m\n" "Upgrade:" "$RECAP_UPGRADE"
    printf "\e[34m║  %-20s  %s\e[0m\n" "Netbird:" "$RECAP_NETBIRD"
    printf "\e[34m║  %-20s  %s\e[0m\n" "Cloudflared:" "$RECAP_CLOUDFLARED"
    printf "\e[34m║  %-20s  %s\e[0m\n" "Firewall:" "$RECAP_FIREWALL"
    printf "\e[34m║  %-20s  %s\e[0m\n" "mDNS:" "$RECAP_MDNS"
    printf "\e[34m║  %-20s  %s\e[0m\n" "MOTD/Console:" "$RECAP_MOTD"
    printf "\e[34m║  %-20s  %s\e[0m\n" "Nag Removal:" "$RECAP_NAG"
    printf "\e[34m║  %-20s  %s\e[0m\n" "Networking:" "$RECAP_NETWORK"
    echo -e "\e[34m╚══════════════════════════════════════════════════════════════╝\e[0m"
}

# =============================================================================
# PRE-CHECKS
# =============================================================================
[[ $EUID -eq 0 ]] || error "Must run as root"
command -v proxmox-backup-manager >/dev/null 2>&1 || error "This script is for Proxmox Backup Server only"
ping -c1 8.8.8.8 >/dev/null 2>&1 || error "No internet connection"

# Netbird pre-check
NETBIRD_CONNECTED=false
NETBIRD_IP=""
if command -v netbird >/dev/null 2>&1; then
    if netbird status 2>/dev/null | grep -q Connected; then
        NETBIRD_CONNECTED=true
        NETBIRD_IP=$(ip -4 addr show wt0 2>/dev/null | grep -oP '(?<=inet\s)100\.[0-9.]+\b' | head -1)
        success "Netbird already connected ($NETBIRD_IP)"
    else
        warn "Netbird installed but not connected"
    fi
fi

# =============================================================================
# PHASE 0 — Repository Setup
# =============================================================================
info "Phase 0: Repository setup"
rm -f /etc/apt/sources.list.d/*.bak* 2>/dev/null || true

CODENAME=$(grep -oP 'VERSION_CODENAME=\K\w+' /etc/os-release || echo bookworm)

# Disable enterprise repos
for f in /etc/apt/sources.list.d/pbs-enterprise.*; do
    [[ -f "$f" ]] || continue
    if [[ "$f" == *.list ]]; then sed -i 's/^deb /#deb /g' "$f"
    else sed -i 's/Enabled: yes/Enabled: no/g' "$f"; fi
done

# Add pbs-no-subscription if missing
if ! grep -q "pbs-no-subscription" /etc/apt/sources.list* 2>/dev/null; then
    echo "deb http://download.proxmox.com/debian/pbs $CODENAME pbs-no-subscription" >> /etc/apt/sources.list
fi

# Debian repos if missing
if ! grep -q deb.debian.org /etc/apt/sources.list* 2>/dev/null; then
    cat <<EOF >> /etc/apt/sources.list

deb http://deb.debian.org/debian $CODENAME main contrib non-free non-free-firmware
deb http://deb.debian.org/debian $CODENAME-updates main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security $CODENAME-security main contrib non-free non-free-firmware
EOF
fi

apt-get update -qq
apt-cache show htop >/dev/null 2>&1 || error "Repository verification failed"
RECAP_REPOS="✔ Configured (${CODENAME})"

# =============================================================================
# PHASE 0.5 — Network Check
# =============================================================================
info "Phase 0.5: Network check"
ip route | head -5
if ! ping -c1 1.1.1.1 >/dev/null 2>&1 || ! ping -c1 8.8.8.8 >/dev/null 2>&1; then
    warn "Ping test failed"
    read -p "Continue anyway? (y/N) " -n1 -r; echo
    [[ ! $REPLY =~ ^[Yy]$ ]] && error "Aborted by user"
fi

# =============================================================================
# SSH KEY + BASHRC
# =============================================================================
mkdir -p /root/.ssh
for key in "${SSH_KEYS[@]}"; do
    grep -qF "$key" /root/.ssh/authorized_keys 2>/dev/null || echo "$key" >> /root/.ssh/authorized_keys
done
chmod 600 /root/.ssh/authorized_keys 2>/dev/null || true
echo 'alias ll="ls -lrt"' >> /root/.bashrc 2>/dev/null || true
RECAP_SSH_KEYS="✔ ${#SSH_KEYS[@]} key(s) added"

# =============================================================================
# PHASE 1 — Hostname / Domain
# =============================================================================
info "Phase 1: Hostname & Domain"
DETECTED_HOST="" DETECTED_DOMAIN=""
while read -r line; do
    if [[ $line =~ ^[0-9] && $line == *.* && $line != 127* && $line != ::* ]]; then
        DETECTED_HOST=$(echo "$line" | awk '{print $2}' | cut -d. -f1)
        DETECTED_DOMAIN=$(echo "$line" | awk '{print $2}' | cut -d. -f2-)
        break
    fi
done < /etc/hosts

if [[ -n $DETECTED_HOST ]]; then
    read -p "Hostname [${DETECTED_HOST}]: " NEWHOST; NEWHOST=${NEWHOST:-$DETECTED_HOST}
    read -p "Domain [${DETECTED_DOMAIN}]: " USER_DOMAIN; USER_DOMAIN=${USER_DOMAIN:-$DETECTED_DOMAIN}
else
    read -p "Hostname [$(hostname)]: " NEWHOST; NEWHOST=${NEWHOST:-$(hostname)}
    read -p "Domain (e.g. ${USER_DOMAIN_DEFAULT}): " USER_DOMAIN; USER_DOMAIN=${USER_DOMAIN:-$USER_DOMAIN_DEFAULT}
fi

hostnamectl set-hostname "$NEWHOST"
echo "$NEWHOST" > /etc/hostname

mkdir -p /etc/proxmox-portable
cat > /etc/proxmox-portable/config <<EOF
HOSTNAME=$NEWHOST
DOMAIN=$USER_DOMAIN
PBS_PORT=$PBS_PORT
EOF

RECAP_HOSTNAME="✔ $NEWHOST"
RECAP_DOMAIN="✔ $USER_DOMAIN"

# =============================================================================
# PHASE 2 — Upgrade + packages
# =============================================================================
info "Phase 2: Upgrade + tools"
apt-get full-upgrade -y && apt-get autoremove -y
apt-get install -y htop curl git jq wget ufw avahi-daemon
RECAP_UPGRADE="✔ Packages upgraded"

# =============================================================================
# PHASE 3 — Netbird
# =============================================================================
info "Phase 3: Netbird"
NETBIRD_DO_SETUP=false
NETBIRD_SKIP_INSTALL=false

if $NETBIRD_CONNECTED; then
    read -p "Re-authorize Netbird? (y/N) " -n1 -r; echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then netbird down; NETBIRD_DO_SETUP=true; NETBIRD_SKIP_INSTALL=true; else RECAP_NETBIRD="✔ Already connected ($NETBIRD_IP)"; fi
elif command -v netbird >/dev/null 2>&1; then
    NETBIRD_DO_SETUP=true; NETBIRD_SKIP_INSTALL=true
else
    NETBIRD_DO_SETUP=true; NETBIRD_SKIP_INSTALL=false
fi

if $NETBIRD_DO_SETUP; then
    if ! $NETBIRD_SKIP_INSTALL; then curl -fsSL https://pkgs.netbird.io/install.sh | sh; fi
    netbird up --management-url "$NETBIRD_URL" > /tmp/netbird.log 2>&1 &
    sleep 8
    AUTH_URL=$(grep -o 'https://[^ ]*netbird[^ ]*' /tmp/netbird.log | head -1)
    [[ -n $AUTH_URL ]] && info "→ Authorize here: \e[1;33m$AUTH_URL\e[0m" || warn "Check https://$NETBIRD_URL"

    for i in {1..10}; do
        sleep 1
        if netbird status | grep -q Connected; then
            NETBIRD_CONNECTED=true
            NETBIRD_IP=$(ip -4 addr show wt0 2>/dev/null | grep -oP '(?<=inet\s)100\.[0-9.]+\b' | head -1)
            break
        fi
    done

    if ! $NETBIRD_CONNECTED; then
        while true; do
            read -p "Have you authorized in the browser? (y/n) " -n1 -r; echo
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                sleep 10
                if netbird status | grep -q Connected; then NETBIRD_CONNECTED=true; NETBIRD_IP=...; break; fi
            else RECAP_NETBIRD="⚠ Not authorized — skipping"; break; fi
        done
    fi
    [[ $NETBIRD_CONNECTED == true ]] && RECAP_NETBIRD="✔ Connected (${NETBIRD_IP})"
fi

# =============================================================================
# PHASE 4 — Cloudflared (official method)
# =============================================================================
info "Phase 4: Cloudflared"
if command -v cloudflared >/dev/null 2>&1; then
    success "Already installed — skipping"
    RECAP_CLOUDFLARED="✔ Already installed (skipped)"
else
    mkdir -p --mode=0755 /usr/share/keyrings
    curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg | tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null
    echo 'deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main' > /etc/apt/sources.list.d/cloudflared.list
    apt-get update -qq && apt-get install -y cloudflared
    RECAP_CLOUDFLARED="✔ Installed (run: cloudflared service install <your-token>)"
fi

# =============================================================================
# PHASE 5 — Firewall, MOTD, mDNS, TTY
# =============================================================================
info "Phase 5: Security + dynamic access"

# UFW
if $NETBIRD_CONNECTED; then
    ufw --force enable
    ufw allow from 100.64.0.0/10 to any port 22 comment "Netbird SSH"
    ufw allow from 100.64.0.0/10 to any port $PBS_PORT comment "Netbird PBS"
    ufw reload
    RECAP_FIREWALL="✔ UFW enabled (Netbird + LAN rules)"
else
    RECAP_FIREWALL="⚠ Skipped — Netbird not connected"
fi

# ufw-lan-refresh (sources config so PBS_PORT works)
cat > /usr/local/bin/ufw-lan-refresh <<'UFWREF'
#!/bin/bash
. /etc/proxmox-portable/config 2>/dev/null || true
: ${PBS_PORT:=8007}
LOG=/var/log/ufw-lan-refresh.log
echo "$(date) - started" >> $LOG

for i in {1..12}; do ip addr show vmbr0 | grep -q "inet " && break; sleep 5; done

SUBNETS=()
for br in vmbr{0..3}; do
    IP=$(ip -4 addr show $br 2>/dev/null | grep -oP '(?<=inet\s)[0-9.]+')
    [[ -n $IP ]] || continue
    SUBNET=$(python3 -c "
import ipaddress, sys
try: print(ipaddress.ip_network('$IP/24', strict=False))
except: print('${IP%.*}.0/24')
" 2>/dev/null)
    [[ $SUBNET != 100.64* ]] && SUBNETS+=("$SUBNET")
done

for port in 22 $PBS_PORT; do
    ufw status numbered | grep -E "$port" | grep -v Netbird | while read -r line; do
        num=$(echo "$line" | grep -oP '^\[[0-9]+\]' | tr -d '[]')
        [[ -n $num ]] && echo y | ufw delete $num >> $LOG 2>&1
    done
done

for s in "${SUBNETS[@]}"; do
    ufw allow from "$s" to any port 22 comment "LAN SSH" >> $LOG 2>&1
    ufw allow from "$s" to any port $PBS_PORT comment "LAN PBS" >> $LOG 2>&1
done
ufw reload >> $LOG 2>&1
UFWREF
chmod +x /usr/local/bin/ufw-lan-refresh

cat > /etc/systemd/system/ufw-lan-refresh.service <<EOF
[Unit]
Description=Refresh UFW LAN rules
After=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/local/bin/ufw-lan-refresh
TimeoutStartSec=90
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload && systemctl enable --now ufw-lan-refresh.service

# mDNS
apt-get install -y avahi-daemon
sed -i 's/#enable-reflector=yes/enable-reflector=yes/' /etc/avahi/avahi-daemon.conf
sed -i '/allow-interfaces/d; /deny-interfaces/d' /etc/avahi/avahi-daemon.conf 2>/dev/null || true
echo "use-ipv6=no" >> /etc/avahi/avahi-daemon.conf 2>/dev/null || true
systemctl enable --now avahi-daemon
RECAP_MDNS="✔ ${NEWHOST}.local:$PBS_PORT"

# MOTD
cat > /etc/update-motd.d/99-portable-pbs <<'MOTD'
#!/bin/bash
. /etc/proxmox-portable/config 2>/dev/null || true
: ${DOMAIN:=local} ${PBS_PORT:=8007} ${HOSTNAME:=pbs}
echo "=== Proxmox Backup Server — $HOSTNAME ==="
echo "Hostname   : https://$HOSTNAME:$PBS_PORT $(curl -sk --max-time 2 https://$HOSTNAME:$PBS_PORT >/dev/null && echo "(Active)" || echo "(Not reachable)")"
echo "DHCP IPs:"
for br in vmbr{0..3}; do
    IP=$(ip -4 addr show $br 2>/dev/null | grep -oP '(?<=inet\s)[0-9.]+')
    [[ -n $IP ]] && echo "  $br: https://$IP:$PBS_PORT $(curl -sk --max-time 2 https://$IP:$PBS_PORT >/dev/null && echo "(Active)" || echo "(Not reachable)")"
done
NB_IP=$(ip -4 addr show wt0 2>/dev/null | grep -oP '(?<=inet\s)100\.[0-9.]+' | cut -d/ -f1)
echo "Netbird    : ${NB_IP:-Disconnected} $([[ -n $NB_IP ]] && curl -sk --max-time 2 https://$NB_IP:$PBS_PORT >/dev/null && echo "(Active)" || echo "")"
echo "mDNS       : https://$HOSTNAME.local:$PBS_PORT $(curl -sk --max-time 2 https://$HOSTNAME.local:$PBS_PORT >/dev/null && echo "(Active)" || echo "(Not reachable)")"
CF_ACTIVE=false
for p in 2000 20241 2001 8080; do
    ss -tlnp 2>/dev/null | grep -q ":$p" || pgrep -f cloudflared >/dev/null && CF_ACTIVE=true && break
done
echo "Cloudflared: https://$HOSTNAME.$DOMAIN $([[ $CF_ACTIVE == true ]] && echo "(Active)" || echo "(Not active)")"
MOTD
chmod +x /etc/update-motd.d/99-portable-pbs
rm -f /etc/motd /etc/motd.tail
RECAP_MOTD="✔ SSH MOTD + TTY console configured"

# Console + TTY refresh services (same as original design)
cat > /usr/local/bin/update-console-issue <<'CONSOLE'
#!/bin/bash
. /etc/proxmox-portable/config 2>/dev/null || true
: ${DOMAIN:=local} ${PBS_PORT:=8007}
cat > /etc/issue <<EOF

Proxmox Backup Server — $HOSTNAME
Hostname : https://$HOSTNAME:$PBS_PORT
Netbird  : $(ip -4 addr show wt0 2>/dev/null | grep -oP '(?<=inet\s)100\.[0-9.]+' | cut -d/ -f1 || echo Disconnected)
mDNS     : $HOSTNAME.local:$PBS_PORT
Cloudflared: https://$HOSTNAME.$DOMAIN

EOF
CONSOLE
chmod +x /usr/local/bin/update-console-issue

mkdir -p /etc/systemd/system/getty@tty1.service.d
cat > /etc/systemd/system/getty@tty1.service.d/override.conf <<EOF
[Service]
ExecStartPre=/usr/local/bin/update-console-issue
EOF

cat > /usr/local/bin/netbird-tty-refresh <<'NBTTY'
#!/bin/bash
for i in {1..24}; do
    systemctl restart getty@tty1 2>/dev/null || true
    sleep 5
    if netbird status | grep -q Connected && pgrep cloudflared >/dev/null; then break; fi
done
NBTTY
chmod +x /usr/local/bin/netbird-tty-refresh

cat > /etc/systemd/system/netbird-tty-refresh.service <<EOF
[Unit]
Description=Refresh TTY1 until Netbird+Cloudflared ready
After=network-online.target
[Service]
Type=oneshot
ExecStart=/usr/local/bin/netbird-tty-refresh
TimeoutStartSec=240
[Install]
WantedBy=multi-user.target
EOF
systemctl daemon-reload && systemctl enable --now netbird-tty-refresh.service

# =============================================================================
# PHASE 6 — Nag Removal
# =============================================================================
info "Phase 6: Subscription nag removal"
for JS in /usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js /usr/share/javascript/proxmox-backup/proxmoxbackuplib.js; do
    [[ -f "$JS" ]] || continue
    cp "$JS" "${JS}.bak.$(date +%s)"
    sed -Ezi 's/(Ext\.Msg\.show\(\{\s+title: gettext\(.No valid sub)/void(\{ \/\/\1/g' "$JS"
    systemctl restart proxmox-backup-proxy.service 2>/dev/null || true
    RECAP_NAG="✔ Patched"
    break
done
[[ -z $RECAP_NAG ]] && RECAP_NAG="⚠ JS file not found"

# =============================================================================
# PHASE 7 — Networking
# =============================================================================
info "Phase 7: Networking"
if ip link show vmbr0 >/dev/null 2>&1 && grep -q "vmbr0 inet dhcp" /etc/network/interfaces 2>/dev/null; then
    RECAP_NETWORK="✔ Already DHCP (skipped)"
else
    warn "This will REWRITE /etc/network/interfaces with DHCP bridges (reboot required)!"
    read -p "Apply? (y/N) " -n1 -r; echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        cp /etc/network/interfaces "/etc/network/interfaces.bak.$(date +%s)"
        NICS=$(ip -o link show | awk -F': ' '{print $2}' | grep -vE '^(lo|docker|br|vmbr|veth|bond|wg|virbr|tun|tap|wl|dummy|sit|teql|ifb|ip6tnl)' | head -5)
        cat > /etc/network/interfaces <<EOF
auto lo
iface lo inet loopback

EOF
        i=0
        for nic in $NICS; do
            cat >> /etc/network/interfaces <<EOF
auto vmbr$i
iface vmbr$i inet dhcp
        bridge-ports $nic
        bridge-stp off
        bridge-fd 0
        bridge-maxwait 0

EOF
            ((i++))
        done
        RECAP_NETWORK="✔ Dual DHCP bridges written (reboot required)"
    else
        RECAP_NETWORK="⚠ Skipped by user"
    fi
fi

# =============================================================================
# PHASE 8 — Recap
# =============================================================================
print_recap_box
if ! $NETBIRD_CONNECTED; then warn "Firewall was NOT enabled (Netbird not connected)"; fi

info "Next node one-liner:"
echo "  bash -c \"\$(curl -fsSL $SETUP_SCRIPT_URL)\""

read -p "Reboot now? (y/N): " -n1 -r; echo
[[ $REPLY =~ ^[Yy]$ ]] && reboot
