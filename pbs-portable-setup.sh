#!/bin/bash
# =============================================================================
# Proxmox Backup Server Portable Setup Script v0.13
# Fully portable PBS node (VM-friendly): DHCP + Netbird + Cloudflared + mDNS
# Safe console/TTY — no blank screen. Idempotent — safe to re-run.
#
# Run: bash -c "$(curl -fsSL https://raw.githubusercontent.com/AriGonz/Public/refs/heads/main/pbs-portable-setup.sh)"
# =============================================================================

# FIX: pipefail so piped commands (curl | sh, curl | tee) fail visibly
set -o pipefail

SCRIPT_VERSION="v0.13"
SETUP_SCRIPT_URL="https://raw.githubusercontent.com/AriGonz/Public/refs/heads/main/pbs-portable-setup.sh"

SSH_KEYS=(
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIHgzljgx9gDLlln3EEE/vcPvr9NMz7kLiLraofNzeQoO pve-xx"
)

NETBIRD_URL="https://netbird.arigonz.com"
USER_DOMAIN_DEFAULT="arigonz.com"
PBS_PORT=8007

# RECAP TRACKING
RECAP_HOSTNAME="-" RECAP_DOMAIN="-" RECAP_REPOS="-" RECAP_UPGRADE="-"
RECAP_NETBIRD="-" RECAP_CLOUDFLARED="-" RECAP_FIREWALL="-"
RECAP_MOTD="-" RECAP_MDNS="-" RECAP_NAG="" RECAP_NETWORK="-"
RECAP_SSH_KEYS="-" RECAP_GUESTAGENT="-"

success() { echo -e "\e[32m[✔] $1\e[0m"; }
warn()    { echo -e "\e[33m[⚠] $1\e[0m"; }
error()   { echo -e "\e[31m[✖] $1\e[0m"; exit 1; }
info()    { echo -e "\e[34m[i] $1\e[0m"; }

print_recap_box() {
    echo
    echo -e "\e[34m╔══════════════════════════════════════════════════════════════╗\e[0m"
    printf  "\e[34m║               PBS PORTABLE SETUP RECAP (%-6s)               ║\e[0m\n" "$SCRIPT_VERSION"
    echo -e "\e[34m╟──────────────────────────────────────────────────────────────╢\e[0m"
    printf "\e[34m║  %-20s  %s\e[0m\n" "Hostname:"     "$RECAP_HOSTNAME"
    printf "\e[34m║  %-20s  %s\e[0m\n" "Domain:"       "$RECAP_DOMAIN"
    printf "\e[34m║  %-20s  %s\e[0m\n" "SSH Keys:"     "$RECAP_SSH_KEYS"
    printf "\e[34m║  %-20s  %s\e[0m\n" "Repos:"        "$RECAP_REPOS"
    printf "\e[34m║  %-20s  %s\e[0m\n" "Upgrade:"      "$RECAP_UPGRADE"
    printf "\e[34m║  %-20s  %s\e[0m\n" "Guest Agent:"  "$RECAP_GUESTAGENT"
    printf "\e[34m║  %-20s  %s\e[0m\n" "Netbird:"      "$RECAP_NETBIRD"
    printf "\e[34m║  %-20s  %s\e[0m\n" "Cloudflared:"  "$RECAP_CLOUDFLARED"
    printf "\e[34m║  %-20s  %s\e[0m\n" "Firewall:"     "$RECAP_FIREWALL"
    printf "\e[34m║  %-20s  %s\e[0m\n" "mDNS:"         "$RECAP_MDNS"
    printf "\e[34m║  %-20s  %s\e[0m\n" "MOTD/Console:" "$RECAP_MOTD"
    printf "\e[34m║  %-20s  %s\e[0m\n" "Nag Removal:"  "$RECAP_NAG"
    printf "\e[34m║  %-20s  %s\e[0m\n" "Networking:"   "$RECAP_NETWORK"
    echo -e "\e[34m╚══════════════════════════════════════════════════════════════╝\e[0m"
}

# =============================================================================
# BANNER
# =============================================================================
echo
echo -e "\e[34m╔══════════════════════════════════════════════════════════════╗\e[0m"
echo -e "\e[34m║         Proxmox Backup Server — Portable Setup               ║\e[0m"
printf  "\e[34m║                    %-10s                               ║\e[0m\n" "$SCRIPT_VERSION"
echo -e "\e[34m╚══════════════════════════════════════════════════════════════╝\e[0m"
echo

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
        NETBIRD_IP=$({ ip -4 addr show wt0 2>/dev/null || ip -4 addr show netbird0 2>/dev/null; } | grep -oP '(?<=inet\s)100\.[0-9.]+\b' | head -1)
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

# Disable ALL enterprise Proxmox repos (pbs-enterprise and any others)
for f in /etc/apt/sources.list.d/*enterprise* /etc/apt/sources.list.d/*proxmox*; do
    [[ -f "$f" ]] || continue
    if [[ "$f" == *.list ]]; then
        sed -i 's/^deb /#deb /g' "$f"
        info "Disabled enterprise repo (list): $f"
    elif [[ "$f" == *.sources ]]; then
        # Handle both "Enabled: yes" and "Enabled: true" and missing Enabled line
        if grep -q "^Enabled:" "$f"; then
            sed -i 's/^Enabled:.*/Enabled: no/g' "$f"
        else
            # Prepend Enabled: no if key is absent
            sed -i '1s/^/Enabled: no\n/' "$f"
        fi
        info "Disabled enterprise repo (sources): $f"
    fi
done

if ! grep -q "pbs-no-subscription" /etc/apt/sources.list* 2>/dev/null; then
    echo "deb http://download.proxmox.com/debian/pbs $CODENAME pbs-no-subscription" >> /etc/apt/sources.list
fi

# If a modern debian.sources file exists, remove any conflicting legacy deb lines
# from sources.list to prevent "configured multiple times" warnings
if ls /etc/apt/sources.list.d/*.sources 2>/dev/null | xargs grep -lqs "deb.debian.org" 2>/dev/null; then
    if grep -q "deb.debian.org" /etc/apt/sources.list 2>/dev/null; then
        info "Removing duplicate Debian repo lines from sources.list (already in .sources format)"
        sed -i '/deb.debian.org/d; /debian-security/d' /etc/apt/sources.list
    fi
# Only add Debian repos to sources.list if not present anywhere
elif ! grep -rqs "deb.debian.org" /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null; then
    cat <<EOF >> /etc/apt/sources.list

deb http://deb.debian.org/debian $CODENAME main contrib non-free non-free-firmware
deb http://deb.debian.org/debian $CODENAME-updates main contrib non-free non-free-firmware
deb http://security.debian.org/debian-security $CODENAME-security main contrib non-free non-free-firmware
EOF
    info "Debian repos added to sources.list"
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

# FIX: guard against duplicate alias on re-run
grep -qF 'alias ll=' /root/.bashrc || echo 'alias ll="ls -lrt"' >> /root/.bashrc

RECAP_SSH_KEYS="✔ ${#SSH_KEYS[@]} key(s) added"

# =============================================================================
# PHASE 1 — Hostname / Domain
# =============================================================================
info "Phase 1: Hostname & Domain"
DETECTED_HOST="" DETECTED_DOMAIN=""
while read -r line; do
    # Skip comment and blank lines
    [[ "$line" =~ ^[[:space:]]*# ]] && continue
    [[ -z "${line// }" ]] && continue
    FQDN=$(echo "$line" | awk '{print $2}')
    IP=$(echo "$line" | awk '{print $1}')
    if [[ "$IP" =~ ^[0-9] && "$IP" != 127.* && "$FQDN" == *.* ]]; then
        DETECTED_HOST=$(echo "$FQDN" | cut -d. -f1)
        DETECTED_DOMAIN=$(echo "$FQDN" | cut -d. -f2-)
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
# PHASE 2 — Upgrade + tools
# =============================================================================
info "Phase 2: Upgrade + tools"
# FIX: avahi-daemon included here only (removed duplicate install in Phase 5)
apt-get full-upgrade -y && apt-get autoremove -y
apt-get install -y htop curl git jq wget ufw avahi-daemon
RECAP_UPGRADE="✔ Packages upgraded"

# =============================================================================
# PHASE 2.5 — QEMU Guest Agent (VM-specific)
# =============================================================================
info "Phase 2.5: QEMU Guest Agent"

QEMU_PKG_OK=false
QEMU_SVC_OK=false
dpkg -l qemu-guest-agent 2>/dev/null | grep -q '^ii' && QEMU_PKG_OK=true
systemctl is-active --quiet qemu-guest-agent 2>/dev/null && QEMU_SVC_OK=true

if $QEMU_PKG_OK && $QEMU_SVC_OK; then
    success "QEMU Guest Agent already installed and running — skipping"
    RECAP_GUESTAGENT="✔ Already installed & active"
elif $QEMU_PKG_OK && ! $QEMU_SVC_OK; then
    warn "QEMU Guest Agent installed but not running — enabling now"
    systemctl enable --now qemu-guest-agent
    RECAP_GUESTAGENT="✔ Was installed, service now enabled"
else
    read -p "Install QEMU Guest Agent (recommended for VM)? (y/N) " -n1 -r; echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        apt-get install -y qemu-guest-agent
        systemctl enable --now qemu-guest-agent
        RECAP_GUESTAGENT="✔ Installed & enabled"
    else
        RECAP_GUESTAGENT="⚠ Skipped by user"
    fi
fi

# =============================================================================
# PHASE 3 — Netbird
# =============================================================================
info "Phase 3: Netbird"
NETBIRD_DO_SETUP=false
NETBIRD_SKIP_INSTALL=false

if $NETBIRD_CONNECTED; then
    read -p "Re-authorize Netbird? (y/N) " -n1 -r; echo
    if [[ $REPLY =~ ^[Yy]$ ]]; then
        netbird down
        NETBIRD_DO_SETUP=true
        NETBIRD_SKIP_INSTALL=true
    else
        RECAP_NETBIRD="✔ Already connected ($NETBIRD_IP)"
    fi
elif command -v netbird >/dev/null 2>&1; then
    NETBIRD_DO_SETUP=true; NETBIRD_SKIP_INSTALL=true
else
    NETBIRD_DO_SETUP=true; NETBIRD_SKIP_INSTALL=false
fi

if $NETBIRD_DO_SETUP; then
    if ! $NETBIRD_SKIP_INSTALL; then
        curl -fsSL https://pkgs.netbird.io/install.sh | sh
    fi

    # --- Setup Key prompt ---
    echo
    info "Netbird Setup Key (leave blank to use browser auth instead):"
    info "  → Get a setup key at: \e[1;33m${NETBIRD_URL}/peers\e[0m"
    read -p "  Setup Key: " NETBIRD_SETUP_KEY
    echo
    NETBIRD_USED_KEY="$NETBIRD_SETUP_KEY"  # preserve original value for logic below

    # Helper: launch browser auth flow and display the auth URL/code
    _netbird_browser_auth() {
        info "Starting browser auth flow..."
        rm -f /tmp/netbird.log
        netbird up --management-url "$NETBIRD_URL" > /tmp/netbird.log 2>&1 &
        # Self-hosted IDP can be slow — wait up to 15s for the auth URL to appear
        for _w in {1..15}; do
            sleep 1
            grep -qP 'https://' /tmp/netbird.log 2>/dev/null && break
        done
        # Extract any HTTPS URL from the log — show all of them if needed
        AUTH_URL=$(grep -oP 'https://\S+' /tmp/netbird.log | grep -Ev '\.(png|svg|js|css)' | grep -E 'auth|device|login|activate|verify|connect|oauth|token' | head -1)
        # Fallback: just grab the first https URL that isn't the management server itself
        [[ -z "$AUTH_URL" ]] && AUTH_URL=$(grep -oP 'https://\S+' /tmp/netbird.log | grep -v "$NETBIRD_URL" | grep -Ev '\.(png|svg|js|css)' | head -1)
        USER_CODE=$(grep -oP '(?i)code[[:space:]]*:[[:space:]]*\K[A-Z0-9]{4,}' /tmp/netbird.log | head -1)
        echo
        echo -e "  \e[1;33m┌──────────────────────────────────────────────────────────────┐\e[0m"
        echo -e "  \e[1;33m│         NETBIRD BROWSER AUTHORIZATION REQUIRED               │\e[0m"
        echo -e "  \e[1;33m├──────────────────────────────────────────────────────────────┤\e[0m"
        if [[ -n "$AUTH_URL" ]]; then
            echo -e "  \e[1;33m│  1. Open this URL in your browser:                           │\e[0m"
            echo -e "  \e[1;33m│     $AUTH_URL\e[0m"
        else
            # Could not extract URL — show full log so user can find it manually
            echo -e "  \e[1;33m│  1. Could not auto-detect auth URL. Raw log output:          │\e[0m"
            echo -e "  \e[1;33m│                                                              │\e[0m"
            while IFS= read -r logline; do
                printf "  \e[1;33m│  %-60s│\e[0m\n" "$logline"
            done < /tmp/netbird.log
            echo -e "  \e[1;33m│                                                              │\e[0m"
            echo -e "  \e[1;33m│  Copy any URL above into your browser to authorize.          │\e[0m"
        fi
        if [[ -n "$USER_CODE" ]]; then
            echo -e "  \e[1;33m│                                                              │\e[0m"
            echo -e "  \e[1;33m│  2. Enter this code when prompted:                           │\e[0m"
            echo -e "  \e[1;33m│     \e[1;97m$USER_CODE\e[1;33m                                                   │\e[0m"
        fi
        echo -e "  \e[1;33m│                                                              │\e[0m"
        echo -e "  \e[1;33m│  3. Log in and click Authorize — then return here.           │\e[0m"
        echo -e "  \e[1;33m└──────────────────────────────────────────────────────────────┘\e[0m"
        echo
    }

    if [[ -n "$NETBIRD_SETUP_KEY" ]]; then
        # Key-based auth — run in background, daemon needs time to register
        info "Using setup key to authenticate..."
        netbird up --management-url "$NETBIRD_URL" --setup-key "$NETBIRD_SETUP_KEY" > /tmp/netbird.log 2>&1 &
        # Wait up to 30s for key-based connection (longer than browser — no human delay)
        info "Waiting for setup key to connect (up to 30s)..."
        for i in {1..15}; do
            sleep 2
            if netbird status 2>/dev/null | grep -q Connected; then
                NETBIRD_CONNECTED=true
                NETBIRD_IP=$({ ip -4 addr show wt0 2>/dev/null || ip -4 addr show netbird0 2>/dev/null; } | grep -oP '(?<=inet\s)100\.[0-9.]+\b' | head -1)
                success "Netbird connected via setup key! ($NETBIRD_IP)"
                break
            fi
            echo -n "."
        done
        echo
        # If key did not connect, fall back to browser auth
        if ! $NETBIRD_CONNECTED; then
            warn "Setup key did not connect — falling back to browser auth."
            info "  → You can generate a valid key at: \e[1;33m${NETBIRD_URL}/peers\e[0m"
            netbird down 2>/dev/null || true
            sleep 3
            _netbird_browser_auth
            NETBIRD_SETUP_KEY=""  # clear so browser confirmation loop runs below
        fi
    else
        # Browser-based auth from the start
        _netbird_browser_auth
    fi

    # --- Wait for connection (browser auth path only — key path has its own loop) ---
    if ! $NETBIRD_CONNECTED; then
        info "Waiting for Netbird to connect..."
        for i in {1..15}; do
            sleep 2
            if netbird status 2>/dev/null | grep -q Connected; then
                NETBIRD_CONNECTED=true
                NETBIRD_IP=$({ ip -4 addr show wt0 2>/dev/null || ip -4 addr show netbird0 2>/dev/null; } | grep -oP '(?<=inet\s)100\.[0-9.]+\b' | head -1)
                success "Netbird connected! ($NETBIRD_IP)"
                break
            fi
            echo -n "."
        done
        echo
    fi

    # --- If still not connected, prompt user to confirm browser auth ---
    # Note: NETBIRD_USED_KEY tracks original input; NETBIRD_SETUP_KEY may be
    # cleared to "" if key auth failed and fell back to browser auth.
    if ! $NETBIRD_CONNECTED; then
        if [[ -n "$NETBIRD_USED_KEY" && -z "$NETBIRD_SETUP_KEY" ]]; then
            # Key was tried but failed and we fell back to browser — now wait for browser
            info "Key auth failed — waiting for browser authorization to complete..."
        fi
        for attempt in {1..5}; do
            read -p "Have you completed browser authorization? [attempt $attempt/5] (y/n) " -n1 -r; echo
            if [[ $REPLY =~ ^[Yy]$ ]]; then
                sleep 10
                if netbird status 2>/dev/null | grep -q Connected; then
                    NETBIRD_CONNECTED=true
                    NETBIRD_IP=$({ ip -4 addr show wt0 2>/dev/null || ip -4 addr show netbird0 2>/dev/null; } | grep -oP '(?<=inet\s)100\.[0-9.]+\b' | head -1)
                    success "Netbird connected! ($NETBIRD_IP)"
                    break
                fi
                warn "Still not connected..."
            else
                RECAP_NETBIRD="⚠ Not authorized — skipping"
                break
            fi
        done
        if ! $NETBIRD_CONNECTED && [[ "$RECAP_NETBIRD" == "-" ]]; then
            if [[ -n "$NETBIRD_USED_KEY" && -n "$NETBIRD_SETUP_KEY" ]]; then
                RECAP_NETBIRD="⚠ Setup key auth failed — check key at ${NETBIRD_URL}/peers"
            else
                RECAP_NETBIRD="⚠ Max attempts reached — skipping"
            fi
        fi
    fi

    [[ $NETBIRD_CONNECTED == true ]] && RECAP_NETBIRD="✔ Connected (${NETBIRD_IP})"

    # --- Netbird SSH support ---
    if $NETBIRD_CONNECTED; then
        echo
        read -p "Enable Netbird SSH access (allows SSH via Netbird network)? (y/N) " -n1 -r; echo
        if [[ $REPLY =~ ^[Yy]$ ]]; then
            info "Enabling Netbird SSH support..."
            netbird down 2>/dev/null || true
            sleep 2
            netbird up --management-url "$NETBIRD_URL" --allow-server-ssh --enable-ssh-root > /tmp/netbird-ssh.log 2>&1 &
            sleep 5
            if netbird status 2>/dev/null | grep -q Connected; then
                success "Netbird SSH enabled"
                RECAP_NETBIRD="✔ Connected + SSH enabled (${NETBIRD_IP})"
            else
                warn "Netbird SSH restart is still connecting — it should be active shortly"
                RECAP_NETBIRD="✔ Connected + SSH enabled (reconnecting)"
            fi
        fi
    fi
fi

# =============================================================================
# PHASE 4 — Cloudflared
# =============================================================================
info "Phase 4: Cloudflared"
if command -v cloudflared >/dev/null 2>&1; then
    success "cloudflared already installed"
    RECAP_CLOUDFLARED="✔ Already installed"
else
    mkdir -p --mode=0755 /usr/share/keyrings
    curl -fsSL https://pkg.cloudflare.com/cloudflare-main.gpg | tee /usr/share/keyrings/cloudflare-main.gpg >/dev/null
    echo 'deb [signed-by=/usr/share/keyrings/cloudflare-main.gpg] https://pkg.cloudflare.com/cloudflared any main' > /etc/apt/sources.list.d/cloudflared.list
    apt-get update -qq && apt-get install -y cloudflared
    RECAP_CLOUDFLARED="✔ Installed"
fi

# Ask for Cloudflare tunnel token — works whether freshly installed or already present
echo
info "Cloudflare Tunnel Token (leave blank to skip):"
info "  → Get your token at: \e[1;33mhttps://one.dash.cloudflare.com\e[0m"
info "  → Zero Trust → Networks → Tunnels → Create tunnel → Choose connector → Copy token"
read -p "  Cloudflare Token: " CF_TOKEN
echo
if [[ -n "$CF_TOKEN" ]]; then
    info "Installing Cloudflare tunnel service..."
    cloudflared service install "$CF_TOKEN" 2>/dev/null || \
        cloudflared service install --token "$CF_TOKEN" 2>/dev/null || true
    sleep 3
    if systemctl is-active --quiet cloudflared 2>/dev/null; then
        success "Cloudflare tunnel service active"
        RECAP_CLOUDFLARED="✔ Tunnel active"
    else
        warn "Cloudflare tunnel installed but service not yet active — check: systemctl status cloudflared"
        RECAP_CLOUDFLARED="⚠ Installed, service not active (check token)"
    fi
else
    info "No token provided — skipping tunnel setup"
    RECAP_CLOUDFLARED="${RECAP_CLOUDFLARED} (no token — run: cloudflared service install <token>)"
fi

# =============================================================================
# PHASE 5 — Firewall, MOTD, mDNS, TTY (safe version)
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

# ufw-lan-refresh
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
    SUBNET=$(python3 -c "import ipaddress; print(ipaddress.ip_network('$IP/24', strict=False))" 2>/dev/null || echo "${IP%.*}.0/24")
    [[ $SUBNET != 100.64* ]] && SUBNETS+=("$SUBNET")
done

# FIX: collect rule numbers first, then delete in reverse order to avoid
# index shifting mid-loop (deleting rule [3] makes [4] become [3], etc.)
for port in 22 $PBS_PORT; do
    mapfile -t rule_nums < <(
        ufw status numbered \
        | grep -E "^\[[0-9]+\].*$port" \
        | grep -v "Netbird" \
        | grep -oP '^\[[0-9]+\]' \
        | tr -d '[]'
    )
    for num in $(printf '%s\n' "${rule_nums[@]}" | sort -rn); do
        [[ -n $num ]] && echo y | ufw delete "$num" >> $LOG 2>&1
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
sed -i 's/#enable-reflector=yes/enable-reflector=yes/' /etc/avahi/avahi-daemon.conf
sed -i '/allow-interfaces/d; /deny-interfaces/d' /etc/avahi/avahi-daemon.conf 2>/dev/null || true
grep -q "^use-ipv6=no" /etc/avahi/avahi-daemon.conf || echo "use-ipv6=no" >> /etc/avahi/avahi-daemon.conf
# Disable systemd-resolved stub listener if present — conflicts with avahi on some systems
if systemctl is-active --quiet systemd-resolved 2>/dev/null; then
    mkdir -p /etc/systemd/resolved.conf.d
    cat > /etc/systemd/resolved.conf.d/no-mdns.conf <<EOF
[Resolve]
MulticastDNS=no
EOF
    systemctl restart systemd-resolved 2>/dev/null || true
fi
systemctl enable avahi-daemon 2>/dev/null || true
systemctl restart avahi-daemon 2>/dev/null || true
sleep 2
if systemctl is-active --quiet avahi-daemon; then
    RECAP_MDNS="✔ ${NEWHOST}.local:$PBS_PORT"
else
    warn "avahi-daemon failed to start — mDNS may not work (check: systemctl status avahi-daemon)"
    RECAP_MDNS="⚠ avahi-daemon failed to start"
fi

# MOTD — FIX: reduced curl timeouts from 2s to 1s to keep SSH login snappy
cat > /etc/update-motd.d/99-portable-pbs <<'MOTD'
#!/bin/bash
. /etc/proxmox-portable/config 2>/dev/null || true
: ${DOMAIN:=local} ${PBS_PORT:=8007} ${HOSTNAME:=pbs}
echo "=== Proxmox Backup Server — $HOSTNAME ==="
echo "Hostname   : https://$HOSTNAME:$PBS_PORT $(curl -sk --max-time 1 https://$HOSTNAME:$PBS_PORT >/dev/null && echo "(Active)" || echo "(Not reachable)")"
echo "DHCP IPs:"
for br in vmbr{0..3}; do
    IP=$(ip -4 addr show $br 2>/dev/null | grep -oP '(?<=inet\s)[0-9.]+')
    [[ -n $IP ]] && echo "  $br : https://$IP:$PBS_PORT $(curl -sk --max-time 1 https://$IP:$PBS_PORT >/dev/null && echo "(Active)" || echo "(Not reachable)")"
done
NB_IP=$({ ip -4 addr show wt0 2>/dev/null || ip -4 addr show netbird0 2>/dev/null; } | grep -oP '(?<=inet\s)100\.[0-9.]+' | cut -d/ -f1)
echo "Netbird    : ${NB_IP:-Disconnected} $([[ -n $NB_IP ]] && curl -sk --max-time 1 https://$NB_IP:$PBS_PORT >/dev/null && echo "(Active)" || echo "")"
echo "mDNS       : https://$HOSTNAME.local:$PBS_PORT $(curl -sk --max-time 1 https://$HOSTNAME.local:$PBS_PORT >/dev/null && echo "(Active)" || echo "(Not reachable)")"
CF_ACTIVE=false
if pgrep -f cloudflared >/dev/null 2>&1; then
    for p in 2000 20241 2001 8080; do
        ss -tlnp 2>/dev/null | grep -q ":$p" && CF_ACTIVE=true && break
    done
fi
echo "Cloudflared: https://$HOSTNAME.$DOMAIN $([[ $CF_ACTIVE == true ]] && echo "(Active)" || echo "(Not active)")"
MOTD
chmod +x /etc/update-motd.d/99-portable-pbs
rm -f /etc/motd /etc/motd.tail
RECAP_MOTD="✔ SSH MOTD + TTY console configured"

# Safe Console + TTY
cat > /usr/local/bin/update-console-issue <<'CONSOLE'
#!/bin/bash
. /etc/proxmox-portable/config 2>/dev/null || true
: ${DOMAIN:=local} ${PBS_PORT:=8007}
cat > /etc/issue <<EOF

═══════════════════════════════════════════════════════════════

          Proxmox Backup Server — $HOSTNAME

Hostname   : https://$HOSTNAME:$PBS_PORT
Netbird    : $({ ip -4 addr show wt0 2>/dev/null || ip -4 addr show netbird0 2>/dev/null; } | grep -oP '(?<=inet\s)100\.[0-9.]+' | cut -d/ -f1 || echo Disconnected)
mDNS       : $HOSTNAME.local:$PBS_PORT
Cloudflared: https://$HOSTNAME.$DOMAIN

═══════════════════════════════════════════════════════════════

EOF
CONSOLE
chmod +x /usr/local/bin/update-console-issue

mkdir -p /etc/systemd/system/getty@tty1.service.d
cat > /etc/systemd/system/getty@tty1.service.d/override.conf <<EOF
[Service]
ExecStartPre=-/usr/local/bin/update-console-issue
EOF

cat > /usr/local/bin/netbird-tty-refresh <<'NBTTY'
#!/bin/bash
for i in {1..12}; do
    /usr/local/bin/update-console-issue
    sleep 10
    if netbird status 2>/dev/null | grep -q Connected && pgrep -f cloudflared >/dev/null 2>&1; then
        /usr/local/bin/update-console-issue
        break
    fi
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
RECAP_NAG=""

# Write the patcher as a temp script — avoids all shell quoting/expansion issues
cat > /tmp/pbs-nag-patch.py << 'NAGPY'
import sys, re

js_path = sys.argv[1]
try:
    with open(js_path, encoding='utf-8', errors='replace') as f:
        src = f.read()
except Exception as e:
    print(f"Cannot read {js_path}: {e}", file=sys.stderr)
    sys.exit(2)

# Check if already patched
if 'void_check' in src or 'NoMoreNagging' in src:
    sys.exit(3)  # already patched

# Patch 1: subscription_check token replace (fast, no regex)
patched = src.replace('.subscription_check(', '.void_check(')

# Patch 2: Ext.Msg.show nag — bounded [^;]* so it cannot crawl the whole file
patched = re.sub(
    r"(Ext\.Msg\.show\(\{[^;]{0,300}?title:\s*gettext\('No valid sub)",
    r"void({ // \1",
    patched
)

if patched == src:
    sys.exit(1)  # pattern not found

with open(js_path, 'w', encoding='utf-8') as f:
    f.write(patched)
sys.exit(0)
NAGPY

for JS in /usr/share/javascript/proxmox-widget-toolkit/proxmoxlib.js \
          /usr/share/javascript/proxmox-backup/proxmoxbackuplib.js; do
    [[ -f "$JS" ]] || continue
    cp "$JS" "${JS}.bak.$(date +%s)"
    python3 /tmp/pbs-nag-patch.py "$JS"
    RC=$?
    case $RC in
        0) systemctl restart proxmox-backup-proxy.service 2>/dev/null || true
           RECAP_NAG="✔ Patched"
           success "Subscription nag patched" ;;
        3) RECAP_NAG="✔ Already patched (prior run)"
           success "Subscription nag already patched" ;;
        1) LATEST_BAK=$(ls -1t "${JS}.bak."* 2>/dev/null | head -1)
           [[ -n "$LATEST_BAK" ]] && cp "$LATEST_BAK" "$JS" || true
           RECAP_NAG="⚠ Pattern not matched — JS may have changed in this PBS version"
           warn "Nag patch: pattern not found" ;;
        *) RECAP_NAG="⚠ Patch script error (rc=$RC)"
           warn "Nag patch: unexpected error" ;;
    esac
    break
done
[[ -z "$RECAP_NAG" ]] && RECAP_NAG="⚠ JS file not found"
rm -f /tmp/pbs-nag-patch.py

# =============================================================================
# PHASE 7 — Networking (VM-safe)
# =============================================================================
info "Phase 7: Networking"
if systemd-detect-virt -q; then
    RECAP_NETWORK="✔ Skipped (running in VM — host handles networking)"
else
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
