#!/bin/bash
# ============================================================
# Proxmox Portable — Network Recovery & Diagnostics
# Run as root when node doesn't pick up IP on a new network.
# Checks everything, applies fixes, logs all details.
#
# Usage:  bash pve-net-recover.sh
# Log:    /var/log/pve-net-recover.log
# ============================================================

set -euo pipefail

LOG=/var/log/pve-net-recover.log
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; CYAN='\033[0;36m'; NC='\033[0m'; BOLD='\033[1m'

# ── Logging helpers ──────────────────────────────────────────
log()   { echo "[$TIMESTAMP] $*" >> "$LOG"; }
logb()  { echo "" >> "$LOG"; echo "[$TIMESTAMP] ══ $* ══" >> "$LOG"; }

# Print to both screen and log
say()   { echo -e "$*"; echo "[$TIMESTAMP] $(echo -e "$*" | sed 's/\x1b\[[0-9;]*m//g')" >> "$LOG"; }
ok()    { say "${GREEN}  ✔ $*${NC}"; }
warn()  { say "${YELLOW}  ⚠ $*${NC}"; }
fail()  { say "${RED}  ✖ $*${NC}"; }
info()  { say "${CYAN}    → $*${NC}"; }
section(){ say "\n${BLUE}${BOLD}━━━ $* ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"; }

# Log a command's full output to log file, show summary on screen
logcmd() {
    local label="$1"; shift
    echo "[$TIMESTAMP] CMD: $*" >> "$LOG"
    local out
    out=$("$@" 2>&1 || true)
    echo "$out" >> "$LOG"
    echo "  [logged: $label]"
}

# ── Start ────────────────────────────────────────────────────
echo "" >> "$LOG"
logb "pve-net-recover started — $TIMESTAMP"

say "\n${BLUE}${BOLD}══════════════════════════════════════════════════════════════${NC}"
say "${BLUE}${BOLD}   Proxmox Portable — Network Recovery & Diagnostics${NC}"
say "${BLUE}${BOLD}══════════════════════════════════════════════════════════════${NC}"
say "  Log: ${CYAN}$LOG${NC}\n"

[[ $EUID -eq 0 ]] || { fail "Must run as root"; exit 1; }

FIXES_APPLIED=0
FIXES_FAILED=0

# ── SECTION 1: Physical NICs ─────────────────────────────────
section "1. Physical Network Interfaces"

logb "ip link show"
ip link show >> "$LOG" 2>&1

PHYS_NICS=$(ip -o link show | awk -F': ' '{print $2}' | awk '{print $1}' \
    | grep -E '^(en|eth|em|eno|ens|enp|enx)' \
    | grep -vE '^(lo|docker|br|vmbr|veth|bond|wg|virbr|tun|tap)' \
    | sort -u)

if [[ -z "$PHYS_NICS" ]]; then
    fail "No physical NICs detected"
    log "Fallback: checking /sys/class/net"
    PHYS_NICS=$(ls /sys/class/net/ | grep -E '^(en|eth|em|eno|ens|enp|enx)' | sort -u || true)
fi

if [[ -z "$PHYS_NICS" ]]; then
    fail "No physical NICs found even via /sys/class/net"
else
    for nic in $PHYS_NICS; do
        STATE=$(cat /sys/class/net/$nic/operstate 2>/dev/null || echo "unknown")
        CARRIER=$(cat /sys/class/net/$nic/carrier 2>/dev/null || echo "0")
        if [[ "$CARRIER" == "1" ]]; then
            ok "Physical NIC: $nic — state=$STATE carrier=UP (cable connected)"
        else
            warn "Physical NIC: $nic — state=$STATE carrier=DOWN (no cable or link)"
        fi
        log "NIC $nic: operstate=$STATE carrier=$CARRIER"
    done
fi

# ── SECTION 2: /etc/network/interfaces ──────────────────────
section "2. Network Interfaces Config"

logb "/etc/network/interfaces"
cat /etc/network/interfaces >> "$LOG" 2>&1

IFACES_FILE=/etc/network/interfaces

# Check if bridges are configured
VMBR0_EXISTS=$(grep -c '^auto vmbr0' "$IFACES_FILE" 2>/dev/null || echo 0)
VMBR1_EXISTS=$(grep -c '^auto vmbr1' "$IFACES_FILE" 2>/dev/null || echo 0)
VMBR0_TYPE=$(grep -A2 'iface vmbr0' "$IFACES_FILE" 2>/dev/null | grep 'inet' | awk '{print $3}' || echo "not found")

info "vmbr0 present: $([ "$VMBR0_EXISTS" -gt 0 ] && echo YES || echo NO), type: $VMBR0_TYPE"
info "vmbr1 present: $([ "$VMBR1_EXISTS" -gt 0 ] && echo YES || echo NO)"

if [[ "$VMBR0_TYPE" == "static" ]]; then
    STATIC_ADDR=$(grep -A5 'iface vmbr0 inet static' "$IFACES_FILE" | grep 'address' | awk '{print $2}' || true)
    fail "vmbr0 is STATIC ($STATIC_ADDR) — this is why IP doesn't change on new networks"

    read -rp "  $(echo -e "${YELLOW}Convert vmbr0 to DHCP? This will fix it permanently. (y/N): ${NC}")" CONVERT
    if [[ "${CONVERT,,}" == "y" ]]; then
        # Backup first
        cp "$IFACES_FILE" "${IFACES_FILE}.bak.$(date +%Y%m%d-%H%M%S)"
        ok "Backed up interfaces file"

        # Detect NICs bridged to vmbr0 and vmbr1
        VMBR0_NIC=$(grep -A10 'iface vmbr0' "$IFACES_FILE" | grep 'bridge-ports' | awk '{print $2}' || echo "none")
        VMBR1_NIC=$(grep -A10 'iface vmbr1' "$IFACES_FILE" | grep 'bridge-ports' | awk '{print $2}' || echo "none")

        # If no NIC found in config, detect from system
        if [[ "$VMBR0_NIC" == "none" || -z "$VMBR0_NIC" ]]; then
            NIC_ARRAY=($PHYS_NICS)
            VMBR0_NIC="${NIC_ARRAY[0]:-none}"
            [[ ${#NIC_ARRAY[@]} -gt 1 ]] && VMBR1_NIC="${NIC_ARRAY[1]}" || VMBR1_NIC=""
        fi

        # Write new DHCP config
        {
            echo "auto lo"
            echo "iface lo inet loopback"
            echo ""
            echo "auto vmbr0"
            echo "iface vmbr0 inet dhcp"
            echo "    bridge-ports $VMBR0_NIC"
            echo "    bridge-stp off"
            echo "    bridge-fd 0"
            echo "    bridge-maxwait 0"
            if [[ -n "$VMBR1_NIC" && "$VMBR1_NIC" != "none" ]]; then
                echo ""
                echo "auto vmbr1"
                echo "iface vmbr1 inet dhcp"
                echo "    bridge-ports $VMBR1_NIC"
                echo "    bridge-stp off"
                echo "    bridge-fd 0"
                echo "    bridge-maxwait 0"
            fi
        } > "$IFACES_FILE"

        ok "Converted vmbr0 to DHCP (bridge-ports: $VMBR0_NIC)"
        log "Rewrote /etc/network/interfaces to DHCP"
        FIXES_APPLIED=$((FIXES_APPLIED + 1))
        NEED_REBOOT=true
    else
        warn "Skipped — static config unchanged. Will attempt DHCP lease manually below."
    fi
elif [[ "$VMBR0_TYPE" == "dhcp" ]]; then
    ok "vmbr0 is configured as DHCP — config is correct"
elif [[ "$VMBR0_EXISTS" -eq 0 ]]; then
    fail "vmbr0 not found in interfaces file at all — Phase 7 networking was skipped during setup"
    warn "Run the setup script again and confirm the networking phase"
fi

# ── SECTION 3: Current IP state ──────────────────────────────
section "3. Current IP Addresses"

logb "ip -4 addr show"
ip -4 addr show >> "$LOG" 2>&1

for br in vmbr0 vmbr1; do
    IP=$(ip -4 addr show "$br" 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1 || true)
    if [[ -n "$IP" ]]; then
        ok "$br: $IP"
    else
        warn "$br: no IP assigned"
    fi
done

# ── SECTION 4: DHCP lease attempt ───────────────────────────
section "4. DHCP Lease Renewal"

for br in vmbr0 vmbr1; do
    # Only try if interface exists
    if ! ip link show "$br" >/dev/null 2>&1; then
        info "$br: interface doesn't exist, skipping"
        continue
    fi

    CURRENT_IP=$(ip -4 addr show "$br" 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1 || true)
    info "$br current IP: ${CURRENT_IP:-none}"

    say "  Releasing $br lease and requesting new one..."
    log "Running: dhclient -r $br then dhclient $br"

    dhclient -r "$br" 2>> "$LOG" || true
    sleep 2
    dhclient "$br" 2>> "$LOG" || true
    sleep 3

    NEW_IP=$(ip -4 addr show "$br" 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1 || true)
    if [[ -n "$NEW_IP" ]]; then
        ok "$br obtained IP: $NEW_IP"
        FIXES_APPLIED=$((FIXES_APPLIED + 1))
    else
        fail "$br: still no IP after DHCP renewal — check cable/switch/DHCP server"
        FIXES_FAILED=$((FIXES_FAILED + 1))
    fi
done

# ── SECTION 5: Routing table ─────────────────────────────────
section "5. Routing Table"

logb "ip route"
ip route >> "$LOG" 2>&1

DEFAULT_GW=$(ip route | grep '^default' | awk '{print $3}' | head -1 || true)
if [[ -n "$DEFAULT_GW" ]]; then
    ok "Default gateway: $DEFAULT_GW"
    # Ping test
    if ping -c2 -W2 "$DEFAULT_GW" >/dev/null 2>&1; then
        ok "Gateway is reachable (ping OK)"
    else
        warn "Gateway not responding to ping (may be filtered)"
    fi
else
    fail "No default gateway — DHCP may not have fully completed"
fi

# Internet check
if ping -c2 -W3 8.8.8.8 >/dev/null 2>&1; then
    ok "Internet reachable (8.8.8.8)"
else
    warn "Internet not reachable — check gateway/DNS"
fi

logb "ip route full"
ip route >> "$LOG" 2>&1

# ── SECTION 6: UFW rules ─────────────────────────────────────
section "6. UFW Firewall Rules"

logb "ufw status numbered"
ufw status numbered >> "$LOG" 2>&1

UFW_STATUS=$(ufw status 2>/dev/null | head -1)
info "UFW status: $UFW_STATUS"

if echo "$UFW_STATUS" | grep -q "active"; then
    ok "UFW is active"

    # Detect current subnet
    LOCAL_SUBNET=$(ip -4 route 2>/dev/null \
        | grep -E 'proto (kernel|dhcp)' \
        | grep -v '100\.64\.' \
        | awk '{print $1}' | grep '/' | head -1 || true)

    if [[ -z "$LOCAL_SUBNET" ]]; then
        PRIMARY_IP=$(ip -4 addr show scope global 2>/dev/null \
            | grep -oP '(?<=inet\s)\d+(\.\d+){3}/\d+' \
            | grep -v '100\.64\.' | head -1 || true)
        [[ -n "$PRIMARY_IP" ]] && LOCAL_SUBNET=$(python3 -c \
            "import ipaddress; n=ipaddress.ip_interface('${PRIMARY_IP}'); print(n.network)" \
            2>/dev/null || true)
    fi

    if [[ -n "$LOCAL_SUBNET" ]]; then
        info "Detected local subnet: $LOCAL_SUBNET"

        # Check if current subnet already has rules
        if ufw status 2>/dev/null | grep -q "$LOCAL_SUBNET"; then
            ok "UFW already has rules for $LOCAL_SUBNET"
        else
            warn "No UFW rules for current subnet $LOCAL_SUBNET — applying now"

            # Delete stale LAN rules (re-query after each delete to handle renumbering)
            for port in 22 8006; do
                while true; do
                    rule_num=$(ufw status numbered 2>/dev/null \
                        | grep -E "^\[ *[0-9]+\].*${port}" \
                        | grep -v '100\.64\.' \
                        | grep -oP '^\[\s*\K[0-9]+' \
                        | sort -rn | head -1 || true)
                    [[ -z "$rule_num" ]] && break
                    ufw --force delete "$rule_num" >> "$LOG" 2>&1 && \
                        info "Deleted old rule #$rule_num (port $port)" || break
                done
            done

            ufw allow from "$LOCAL_SUBNET" to any port 22 proto tcp comment "LAN SSH" >> "$LOG" 2>&1
            ufw allow from "$LOCAL_SUBNET" to any port 8006 proto tcp comment "LAN PVE" >> "$LOG" 2>&1
            ufw reload >> "$LOG" 2>&1
            ok "UFW rules updated for $LOCAL_SUBNET"
            FIXES_APPLIED=$((FIXES_APPLIED + 1))
        fi

        # Verify Netbird rules still present
        if ufw status 2>/dev/null | grep -q '100.64.0.0/10'; then
            ok "Netbird rules (100.64.0.0/10) present"
        else
            warn "Netbird UFW rules missing — re-adding"
            ufw allow from 100.64.0.0/10 to any port 22 proto tcp comment "Netbird SSH" >> "$LOG" 2>&1
            ufw allow from 100.64.0.0/10 to any port 8006 proto tcp comment "Netbird PVE" >> "$LOG" 2>&1
            ufw reload >> "$LOG" 2>&1
            ok "Netbird rules re-added"
            FIXES_APPLIED=$((FIXES_APPLIED + 1))
        fi
    else
        fail "Cannot detect local subnet — no IP assigned yet"
    fi

    logb "ufw status after fixes"
    ufw status numbered >> "$LOG" 2>&1
else
    warn "UFW is not active — no firewall changes needed"
fi

# ── SECTION 7: Netbird ───────────────────────────────────────
section "7. Netbird VPN"

logb "netbird status"
netbird status >> "$LOG" 2>&1 || true

if command -v netbird >/dev/null 2>&1; then
    NETBIRD_STATUS=$(netbird status 2>/dev/null || true)
    NETBIRD_IP=$(ip -4 addr show wt0 2>/dev/null \
        | grep -oP '(?<=inet\s)100\.[0-9]+\.[0-9]+\.[0-9]+' || true)

    if [[ -n "$NETBIRD_IP" ]]; then
        ok "Netbird connected: $NETBIRD_IP"
    else
        warn "Netbird not connected (wt0 has no IP)"
        info "Run: netbird up --management-url https://netbird.arigonz.com"
    fi
else
    warn "Netbird not installed"
fi

# ── SECTION 8: Cloudflared ───────────────────────────────────
section "8. Cloudflared"

if command -v cloudflared >/dev/null 2>&1; then
    CF_STATE=$(systemctl is-active cloudflared 2>/dev/null || echo "unknown")
    info "cloudflared service: $CF_STATE"
    systemctl status cloudflared --no-pager >> "$LOG" 2>&1 || true

    CF_METRICS_PORT=""
    for port in 2000 20241 2001 8080; do
        if curl -sf --max-time 2 "http://localhost:${port}/metrics" >/dev/null 2>&1; then
            CF_METRICS_PORT=$port
            break
        fi
    done

    if [[ -n "$CF_METRICS_PORT" ]]; then
        ok "Cloudflared tunnel active (metrics on port $CF_METRICS_PORT)"
    else
        warn "Cloudflared metrics not responding — tunnel may not be connected"
        [[ "$CF_STATE" != "active" ]] && info "Try: systemctl start cloudflared"
    fi
else
    warn "Cloudflared not installed"
fi

# ── SECTION 9: TTY console screen ───────────────────────────
section "9. TTY Console Screen"

if [[ -x /usr/local/bin/update-console-issue ]]; then
    say "  Refreshing /etc/issue..."
    /usr/local/bin/update-console-issue
    ok "update-console-issue ran successfully"
    say "\n  Current /etc/issue:"
    cat /etc/issue | sed 's/^/    /'
    systemctl restart getty@tty1 2>/dev/null && ok "getty@tty1 restarted — screen updated" || true
else
    warn "/usr/local/bin/update-console-issue not found"
fi

# ── SECTION 10: Service status ───────────────────────────────
section "10. Boot Services"

for svc in ufw-lan-refresh netbird-tty-refresh netbird avahi-daemon; do
    STATE=$(systemctl is-active "$svc" 2>/dev/null || echo "not-found")
    ENABLED=$(systemctl is-enabled "$svc" 2>/dev/null || echo "not-found")
    if [[ "$STATE" == "active" || "$STATE" == "inactive" ]]; then
        ok "$svc: state=$STATE enabled=$ENABLED"
    else
        warn "$svc: state=$STATE enabled=$ENABLED"
    fi
    systemctl status "$svc" --no-pager >> "$LOG" 2>&1 || true
done

# ── SECTION 11: Lease files ──────────────────────────────────
section "11. DHCP Lease Files"

logb "DHCP lease files"
for d in /var/lib/dhcp /run/systemd/netif/leases /run/network; do
    if [[ -d "$d" ]]; then
        info "Contents of $d:"
        ls -la "$d" >> "$LOG" 2>&1
        ls -la "$d" 2>/dev/null | sed 's/^/    /'
        cat "$d"/*.lease "$d"/*.leases 2>/dev/null >> "$LOG" || true
    fi
done

# ── SUMMARY ──────────────────────────────────────────────────
section "Summary"

VMBR0_FINAL=$(ip -4 addr show vmbr0 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1 || echo "none")
VMBR1_FINAL=$(ip -4 addr show vmbr1 2>/dev/null | grep -oP '(?<=inet\s)\d+(\.\d+){3}' | head -1 || echo "none")

say "  vmbr0 IP : ${VMBR0_FINAL}"
say "  vmbr1 IP : ${VMBR1_FINAL}"
say "  Fixes applied : ${FIXES_APPLIED}"
say "  Fixes failed  : ${FIXES_FAILED}"

if [[ "${NEED_REBOOT:-false}" == true ]]; then
    say "\n${YELLOW}${BOLD}  ⚠ /etc/network/interfaces was rewritten to DHCP.${NC}"
    say "${YELLOW}  A reboot is required for the change to fully take effect.${NC}"
    read -rp "  Reboot now? (y/N): " DO_REBOOT
    [[ "${DO_REBOOT,,}" == "y" ]] && reboot
fi

say "\n${GREEN}${BOLD}  Done. Full log: $LOG${NC}\n"
