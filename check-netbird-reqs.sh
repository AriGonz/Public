#!/usr/bin/env bash
# NetBird Self-Hosted Pre-Installation Requirements Checker
# Checks hardware, network, software, and recommended setup items
# Usage: bash -c "$(curl -fsSL https://raw.githubusercontent.com/AriGonz/Public/refs/heads/main/check-netbird-reqs.sh)"

set -euo pipefail

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

echo -e "\n${YELLOW}NetBird Self-Hosted Installation Requirements Check${NC}"
echo "===================================================="
echo -e "Date: $(date '+%Y-%m-%d %H:%M:%S %Z')\n"

# ────────────────────────────────────────────────────────────────
# Helper functions
# ────────────────────────────────────────────────────────────────
fail() { echo -e "${RED}✗ $1${NC}"; }
pass() { echo -e "${GREEN}✓ $1${NC}"; }
warn() { echo -e "${YELLOW}⚠ $1${NC}"; }

check_command() {
    local cmd="$1"
    local desc="$2"
    if command -v "$cmd" &>/dev/null; then
        pass "$desc is installed"
        return 0
    else
        fail "$desc is NOT installed"
        return 1
    fi
}

install_if_missing() {
    local pkg="$1"
    local cmd="$2"
    local desc="$3"

    if ! command -v "$cmd" &>/dev/null; then
        echo -e "${YELLOW}Installing $desc...${NC}"
        if sudo apt update -qq && sudo apt install -yqq "$pkg"; then
            pass "$desc installed successfully"
        else
            fail "Failed to install $desc"
        fi
    fi
}

check_port_tcp() {
    local port="$1"
    local desc="$2"
    if timeout 2 bash -c "</dev/tcp/127.0.0.1/$port" 2>/dev/null; then
        warn "Port $port/tcp is in use locally"
        return 1
    else
        pass "Port $port/tcp appears free locally"
        return 0
    fi
}

check_port_udp() {
    local port="$1"
    local desc="$2"
    if command -v ss >/dev/null && ss -uln | grep -q ":$port "; then
        warn "Port $port/udp appears to be in use locally"
        return 1
    elif command -v netstat >/dev/null && netstat -uln 2>/dev/null | grep -q ":$port "; then
        warn "Port $port/udp appears to be in use locally"
        return 1
    else
        pass "Port $port/udp appears free locally (best-effort check)"
        return 0
    fi
}

# ────────────────────────────────────────────────────────────────
# 1. OS Check (preferred)
# ────────────────────────────────────────────────────────────────
echo -e "\n${YELLOW}Operating System${NC}"
if [[ -f /etc/os-release ]]; then
    source /etc/os-release
    if [[ "${ID:-}" == "ubuntu" && "${VERSION_ID:-}" == "24.04" ]]; then
        pass "Ubuntu 24.04 LTS detected ($PRETTY_NAME)"
    else
        warn "Not Ubuntu 24.04 LTS (found: ${PRETTY_NAME:-unknown}) — continuing but results may vary"
    fi
else
    warn "Cannot determine OS (/etc/os-release not found)"
fi

# ────────────────────────────────────────────────────────────────
# 2. Hardware Requirements
# ────────────────────────────────────────────────────────────────
echo -e "\n${YELLOW}Hardware Requirements${NC}"

cores=$(nproc --all 2>/dev/null || grep -c ^processor /proc/cpuinfo 2>/dev/null || echo "0")
echo "CPU cores: $cores"
if (( cores >= 2 )); then
    pass "≥ 2 CPU cores (recommended)"
elif (( cores >= 1 )); then
    warn "Only $cores core — meets minimum (1) but below recommendation"
else
    fail "Could not detect CPU cores"
fi

ram_mb=$(free -m | awk '/^Mem:/ {print $2}' 2>/dev/null || echo "0")
echo "Memory: ${ram_mb} MB"
if (( ram_mb >= 4000 )); then
    pass "≥ 4 GB RAM (recommended)"
elif (( ram_mb >= 2000 )); then
    warn "${ram_mb} MB — meets minimum (2 GB) but below recommendation"
else
    fail "Less than 2 GB RAM"
fi

disk_free_gb=$(df -BG / | awk 'NR==2 {print $4}' | tr -d 'G' 2>/dev/null || echo "0")
echo "Free disk space on /: ${disk_free_gb} GB"
if (( disk_free_gb >= 10 )); then
    pass "≥ 10 GB free disk space"
else
    fail "Only ${disk_free_gb} GB free — need ≥ 10 GB"
fi

# ────────────────────────────────────────────────────────────────
# 3. Network Requirements
# ────────────────────────────────────────────────────────────────
echo -e "\n${YELLOW}Network Requirements${NC}"

public_ip=$(curl -s -4 ifconfig.me 2>/dev/null || curl -s -4 icanhazip.com 2>/dev/null || echo "")
if [[ -n "$public_ip" && "$public_ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    pass "Public IPv4 detected: $public_ip"
else
    warn "Could not detect public IPv4 address (check connectivity)"
fi

echo "Local port availability check:"
check_port_tcp 80   "TCP 80 (HTTP - Let's Encrypt / setup)"   || true
check_port_tcp 443  "TCP 443 (HTTPS - dashboard & API)"       || true
check_port_udp 3478 "UDP 3478 (STUN/TURN - connectivity)"     || true

echo -e "  ${YELLOW}Important:${NC} This only checks local listeners."
echo "  You must ensure ports 80/tcp, 443/tcp, 3478/udp are open in firewall / security group."

# ────────────────────────────────────────────────────────────────
# 4. Required Software
# ────────────────────────────────────────────────────────────────
echo -e "\n${YELLOW}Required Software${NC}"

install_if_missing curl curl "curl"
install_if_missing jq   jq   "jq"

# Docker
if command -v docker >/dev/null && docker --version >/dev/null 2>&1; then
    docker_ver=$(docker --version | awk '{print $3}' | tr -d ',')
    pass "Docker is installed ($docker_ver)"
else
    echo -e "${YELLOW}Installing Docker...${NC}"
    if curl -fsSL https://get.docker.com | sudo sh; then
        pass "Docker installed successfully"
        sudo usermod -aG docker "$USER" 2>/dev/null || true
    else
        fail "Failed to install Docker — install manually: https://docs.docker.com/engine/install/"
    fi
fi

# Docker Compose v2 plugin
if docker compose version >/dev/null 2>&1; then
    compose_ver=$(docker compose version --short 2>/dev/null || echo "unknown")
    pass "Docker Compose v2 plugin is installed ($compose_ver)"
else
    echo -e "${YELLOW}Installing Docker Compose v2 plugin...${NC}"
    sudo apt install -y docker-compose-plugin || {
        fail "Failed to install docker-compose-plugin"
        echo "  Try: sudo apt install docker-compose-plugin"
        echo "  or follow: https://docs.docker.com/compose/install/linux/"
    }
fi

# ────────────────────────────────────────────────────────────────
# 5. Strongly Recommended
# ────────────────────────────────────────────────────────────────
echo -e "\n${YELLOW}Strongly Recommended${NC}"

# Domain check (basic — replace netbird.arigonz.com with your domain if different)
domain="netbird.arigonz.com"
if [[ -n "$public_ip" ]]; then
    resolved=$(dig +short "$domain" 2>/dev/null || echo "")
    if [[ -n "$resolved" && "$resolved" == "$public_ip" ]]; then
        pass "Domain $domain resolves to this server's public IP ($public_ip)"
    elif [[ -n "$resolved" ]]; then
        warn "Domain $domain resolves to $resolved (does NOT match server IP $public_ip)"
    else
        warn "Domain $domain does NOT resolve (DNS A record missing?)"
    fi
fi

# Root/sudo
if [[ $EUID -eq 0 ]]; then
    pass "Running as root"
elif sudo -n true 2>/dev/null; then
    pass "Passwordless sudo access available"
else
    warn "No root / passwordless sudo detected — some steps will require manual sudo"
fi

echo -e "\n${YELLOW}Summary & Next Steps${NC}"
echo " • Fix all ${RED}✗${NC} items before proceeding"
echo " • Review ${YELLOW}⚠${NC} items — they may affect performance/stability"
echo " • Verify ports 80/443/3478 are reachable **from the internet** (firewall, security group, ufw allow ...)"
echo " • After checks pass → run the official NetBird setup script"
echo "   https://docs.netbird.io/selfhosted/selfhosted-quickstart"

echo -e "\nCheck complete!\n"
