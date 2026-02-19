#!/bin/bash
# =============================================================
# get-wan-ip.sh — Show current WAN, LAN and Netbird IPs
# Repo   : github.com/AriGonz/Public
# Usage  : bash /root/get-wan-ip.sh
# Version: 1.0
# =============================================================

# ── Colors ────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BOLD='\033[1m'
NC='\033[0m'

LOG_FILE="/root/wan-ip.log"
LAN_GW="192.168.1.1"
LAN_HOST="192.168.1.254"
OPNSENSE_PASS="opnsense"

# ── Get IPs ───────────────────────────────────────────────────
WAN_IP=$(sshpass -p "$OPNSENSE_PASS" ssh \
    -o StrictHostKeyChecking=no \
    -o ConnectTimeout=5 \
    root@"$LAN_GW" \
    "ifconfig vtnet0 2>/dev/null | awk '/inet /{print \$2}'" 2>/dev/null || true)

NETBIRD_IP=$(netbird status 2>/dev/null | grep -oE '100\.[0-9]+\.[0-9]+\.[0-9]+' | head -1 || true)
HOSTNAME=$(hostname)
TIMESTAMP=$(date '+%Y-%m-%d %H:%M:%S')

# ── Display ───────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${CYAN}╔══════════════════════════════════════════════════╗${NC}"
echo -e "${BOLD}${CYAN}║         Network Status — ${HOSTNAME}$(printf '%*s' $((22 - ${#HOSTNAME})) '')║${NC}"
echo -e "${BOLD}${CYAN}╚══════════════════════════════════════════════════╝${NC}"
echo -e "  ${BOLD}Timestamp :${NC} ${TIMESTAMP}"
echo ""

# WAN IP
if [[ -n "$WAN_IP" ]]; then
    echo -e "  ${BOLD}WAN IP    :${NC} ${GREEN}${WAN_IP}${NC}"
else
    echo -e "  ${BOLD}WAN IP    :${NC} ${RED}unavailable (OPNsense not reachable)${NC}"
fi

# Netbird IP
if [[ -n "$NETBIRD_IP" ]]; then
    echo -e "  ${BOLD}Netbird IP:${NC} ${GREEN}${NETBIRD_IP}${NC}"
else
    echo -e "  ${BOLD}Netbird IP:${NC} ${YELLOW}not connected${NC}"
fi

echo -e "  ${BOLD}LAN IP    :${NC} ${GREEN}${LAN_HOST}${NC}"
echo ""

# Access URLs
echo -e "  ${BOLD}── Access via WAN ──────────────────────────────${NC}"
if [[ -n "$WAN_IP" ]]; then
    echo -e "  Proxmox   → ${CYAN}https://${WAN_IP}:8006${NC}"
    echo -e "  OPNsense  → ${CYAN}https://${WAN_IP}${NC}"
else
    echo -e "  ${YELLOW}WAN access unavailable${NC}"
fi

echo ""
echo -e "  ${BOLD}── Access via Netbird ──────────────────────────${NC}"
if [[ -n "$NETBIRD_IP" ]]; then
    echo -e "  Proxmox   → ${CYAN}https://${NETBIRD_IP}:8006${NC}"
else
    echo -e "  ${YELLOW}Netbird not connected — run: netbird up${NC}"
fi

echo ""
echo -e "  ${BOLD}── Access via LAN ──────────────────────────────${NC}"
echo -e "  Proxmox   → ${CYAN}https://${LAN_HOST}:8006${NC}"
echo -e "  OPNsense  → ${CYAN}https://${LAN_GW}${NC}"
echo ""

# ── Save to log ───────────────────────────────────────────────
{
    echo "[$TIMESTAMP]"
    echo "  Hostname : $HOSTNAME"
    echo "  WAN IP   : ${WAN_IP:-unavailable}"
    echo "  Netbird  : ${NETBIRD_IP:-not connected}"
    echo "  LAN IP   : $LAN_HOST"
    echo ""
} >> "$LOG_FILE"

# ── Install systemd service on first run ──────────────────────
SYSTEMD_UNIT="/etc/systemd/system/get-wan-ip.service"
if [[ ! -f "$SYSTEMD_UNIT" ]]; then
    echo -e "  ${YELLOW}Installing boot-time service (runs 10s after reboot)...${NC}"
    cat > "$SYSTEMD_UNIT" << 'EOF'
[Unit]
Description=Get WAN IP after boot
After=network-online.target netbird.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStartPre=/bin/sleep 10
ExecStart=/bin/bash /root/get-wan-ip.sh
StandardOutput=append:/root/wan-ip.log
StandardError=append:/root/wan-ip.log
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload
    systemctl enable get-wan-ip.service &>/dev/null
    echo -e "  ${GREEN}[✓] Service installed — will run 10s after every reboot${NC}"
    echo -e "  ${GREEN}[✓] Log file: ${LOG_FILE}${NC}"
    echo ""
fi
